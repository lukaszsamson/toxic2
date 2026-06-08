defmodule Toxic2.Lower do
  @moduledoc """
  CST → Elixir AST lowering (see `TOXIC_2.md` → Lowering; Migration Phases #6).

  This is the **one** pass that knows Elixir AST quirks (P5). The parser builds a structural
  green CST; everything Elixir-AST-specific — variable shape, alias shape, atomization, block
  wrapping, operator nodes — lives here, so a conformance failure localizes cleanly to "CST
  wrong" (parser bug) vs "lowering rule wrong" (here).

  **Totality (P5): lowering NEVER raises.** It returns `{ast, diagnostics}` and threads a
  diagnostic accumulator (the lowerer's channel in the single combined stream — used now for the
  `:existing_atoms_only` atom policy, and reserved for things like the `not in` deprecation).
  Ids continue from `start_id` so they stay unique across lexer + parser + lowerer.

  Atom policy: source-derived names are atomized here (never in the lexer — review #1). With
  `existing_atoms_only: true`, an unknown atom does not raise — it lowers to `{:__error__, ...}`
  plus a `:nonexistent_atom` lowerer diagnostic.
  """

  alias Toxic2.{CST, Diagnostics, Tokens}

  # Narrow inlining of tiny LOCAL meta builders on the hot per-node path (A/B-measured).
  @compile {:inline, tmeta: 2, op_atom: 2, op_meta: 2, span_meta: 1}

  @type ast :: Macro.t()

  @doc """
  Lower `cst` to AST. Returns `{ast, lowerer_diagnostics}` (source-ordered). `start_id` is the
  next free diagnostic id (so ids don't collide with lexer/parser diagnostics).
  """
  @spec to_ast(CST.t(), Tokens.t(), String.t(), keyword(), pos_integer()) ::
          {ast(), [Toxic2.Diagnostic.t()]}
  def to_ast(cst, view), do: to_ast(cst, view, "", [], 1)

  # Backward-compatible arities: the original public shape was `to_ast(cst, view, opts, start_id)`
  # (no source). `token_metadata: true` needs the source to scan `delimiter:`/`token:`/`newlines:`,
  # so the 5-arity form threads it; the keyword-`opts` 3/4-arities keep old callers working.
  def to_ast(cst, view, opts) when is_list(opts), do: to_ast(cst, view, "", opts, 1)

  def to_ast(cst, view, opts, start_id) when is_list(opts) and is_integer(start_id),
    do: to_ast(cst, view, "", opts, start_id)

  def to_ast(cst, view, source, opts, start_id)
      when is_binary(source) and is_list(opts) and is_integer(start_id) do
    {ast, acc, _nid} = lower(cst, view, resolve_opts(opts, source), [], start_id)
    {ast, Diagnostics.to_list(acc)}
  end

  # Resolve the (keyword) options ONCE into a compact map threaded through lowering, so per-node
  # checks are a map field read (`opts.range`) instead of a `Keyword.get` keyfind over the option
  # list on every node (tprof: that keyfind was ~4 % of all calls). `token_metadata` mode also
  # carries the source split into lines (codepoint columns) so helpers can slice `delimiter:`/`token:`.
  defp resolve_opts(opts, source) do
    tm = Keyword.get(opts, :token_metadata, false)

    %{
      existing_atoms_only: Keyword.get(opts, :existing_atoms_only, false),
      range: Keyword.get(opts, :range, false),
      literal_encoder: Keyword.get(opts, :literal_encoder),
      token_metadata: tm,
      # always available: `src_slice` is needed for the empty-paren `;` check even without tm (the
      # tm-only meta helpers that also use it are simply not called when tm is off).
      source_lines: source_lines(source)
    }
  end

  # Split into lines for codepoint-column scanning. A CRLF file leaves a trailing `\r` on each line;
  # strip it so an end-of-line scan sees the line end where the `\r\n` begins (matching Elixir, which
  # treats `\r\n` as the newline). The actual column numbers come from the lexer, not from here.
  defp source_lines(source) do
    source |> String.split("\n") |> Enum.map(&String.trim_trailing(&1, "\r")) |> List.to_tuple()
  end

  # Raw source text spanning `{sl,sc}`..`{el,ec}` (codepoint columns, end-exclusive), or `nil`.
  defp src_slice(%{source_lines: lines}, {sl, sc}, {el, ec}) when is_tuple(lines) and sl == el,
    do: String.slice(elem(lines, sl - 1), sc - 1, ec - sc)

  defp src_slice(%{source_lines: lines}, {sl, sc}, {el, ec}) when is_tuple(lines) do
    head = elem(lines, sl - 1) |> String.slice(sc - 1, String.length(elem(lines, sl - 1)))
    mids = for l <- (sl + 1)..(el - 1)//1, do: elem(lines, l - 1)
    tail = elem(lines, el - 1) |> String.slice(0, ec - 1)
    Enum.join(Enum.concat([[head], mids, [tail]]), "\n")
  end

  defp src_slice(_opts, _from, _to), do: nil

  defp tm?(%{token_metadata: tm}), do: tm

  defp src_line(%{source_lines: lines}, n)
       when is_tuple(lines) and n >= 1 and n <= tuple_size(lines),
       do: elem(lines, n - 1)

  defp src_line(_opts, _n), do: nil

  defp src_line_count(%{source_lines: lines}) when is_tuple(lines), do: tuple_size(lines)
  defp src_line_count(_opts), do: 0

  # --- end_of_expression (token_metadata) --------------------------------------------------------
  # A statement carries `end_of_expression: [newlines: n, line: l, column: c]` when it is followed by
  # an end-of-line token (a newline or `;`). `{l, c}` is that terminator's position; `newlines`
  # counts the `\n`s before the next real token, NOT counting the newline that ends a pure-comment
  # line (`# …` alone on its line), matching Elixir's tokenizer. Derived entirely from the source.
  defp attach_eoe(ast, _child, _view, %{token_metadata: false}), do: ast

  defp attach_eoe({f, meta, a} = ast, child, view, opts) do
    case eoe_meta(child, view, opts) do
      [] -> ast
      kw -> {f, Enum.concat(kw, meta), a}
    end
  end

  defp attach_eoe(ast, _child, _view, _opts), do: ast

  defp eoe_meta(child, view, opts) do
    case child_span(child, view) do
      {_sl, _sc, el, ec} -> scan_eoe(opts, el, ec, 0, false, nil)
      _ -> []
    end
  end

  defp scan_eoe(opts, line, col, nls, semi, pos) do
    case src_line(opts, line) do
      nil ->
        finalize_eoe(nls, semi, pos)

      text ->
        seg = String.slice(text, col - 1, max(String.length(text) - (col - 1), 0))
        {ws, rest} = split_leading_ws(seg)
        tok_col = col + ws

        cond do
          # End of line, or a comment: cross this line's `\n`. A comment RESETS the run (Elixir
          # counts only the newlines after the last comment), so we carry 0 across a comment line.
          rest == "" ->
            cross_newline(opts, line, nls, semi, pos || {line, tok_col})

          match?("#" <> _, rest) ->
            cross_newline(opts, line, 0, semi, pos || {line, tok_col})

          match?(";" <> _, rest) ->
            scan_eoe(opts, line, tok_col + 1, nls, true, pos || {line, tok_col})

          true ->
            finalize_eoe(nls, semi, pos)
        end
    end
  end

  # Cross the `\n` that ends `line` (+1 newline), continuing on the next line; at EOF there is none.
  defp cross_newline(opts, line, nls, semi, pos) do
    if line < src_line_count(opts) do
      scan_eoe(opts, line + 1, 1, nls + 1, semi, pos)
    else
      finalize_eoe(nls, semi, pos)
    end
  end

  defp finalize_eoe(nls, semi, {l, c}) when nls > 0 or semi,
    do: [end_of_expression: [newlines: nls, line: l, column: c]]

  defp finalize_eoe(_nls, _semi, _pos), do: []

  defp split_leading_ws(<<c, rest::binary>>) when c in [?\s, ?\t] do
    {n, tail} = split_leading_ws(rest)
    {n + 1, tail}
  end

  defp split_leading_ws(rest), do: {0, rest}

  # Count the newlines in the source from `{line, col}` up to the next real token, with the same
  # comment-reset rule as `end_of_expression` (a comment line zeroes the run). Used for the
  # standalone `newlines:` on operators / `->` / `when` / containers, so comments and blank lines
  # are counted exactly as Elixir's tokenizer does (not a naive line delta).
  defp gap_newlines(opts, line, col, nls \\ 0) do
    case src_line(opts, line) do
      nil ->
        nls

      text ->
        rest =
          text |> String.slice(col - 1, max(String.length(text) - (col - 1), 0)) |> elem_rest()

        cond do
          rest == "" -> cross_gap(opts, line, nls + 1, nls)
          match?("#" <> _, rest) -> cross_gap(opts, line, 1, nls)
          true -> nls
        end
    end
  end

  defp elem_rest(seg), do: split_leading_ws(seg) |> elem(1)

  defp cross_gap(opts, line, next_nls, eof_nls) do
    if line < src_line_count(opts), do: gap_newlines(opts, line + 1, 1, next_nls), else: eof_nls
  end

  defp lower(cst, view, opts, acc, nid) do
    case CST.tag(cst) do
      :token -> lower_token(cst, view, opts, acc, nid)
      :missing -> {error_ast(cst, view), acc, nid}
      :node -> lower_node(cst, view, opts, acc, nid)
    end
  end

  defp lower_token(cst, view, opts, acc, nid) do
    idx = CST.token_index(cst)
    val = Tokens.value(view, idx)
    # Leaf nodes are fresh (no passthrough), so the token's own span IS the range.
    meta = tmeta(view, idx) |> maybe_token_range(view, idx, opts)

    case Tokens.kind(view, idx) do
      :int -> lit(val, view, idx, opts, acc, nid, tm_token(view, idx, opts))
      :flt -> lit(val, view, idx, opts, acc, nid, tm_token(view, idx, opts))
      :char -> lit(val, view, idx, opts, acc, nid, tm_token(view, idx, opts))
      :literal -> lit(val, view, idx, opts, acc, nid)
      # `&N` (capture argument): the whole token is the capture `{:&, _, [N]}` (see Precedence).
      :capture_int -> {{:&, meta, [val]}, acc, nid}
      :atom -> lower_atom_literal(cst, view, idx, opts, val, acc, nid)
      :identifier -> atomize(cst, view, opts, acc, nid, val, &{&1, meta, nil})
      :alias -> atomize(cst, view, opts, acc, nid, val, &{:__aliases__, meta, [&1]})
      _ -> {error_ast(cst, view), acc, nid}
    end
  end

  defp lower_atom_literal(cst, view, idx, opts, val, acc, nid) do
    case to_atom(val, opts) do
      {:ok, atom} -> lit(atom, view, idx, opts, acc, nid)
      :error -> nonexistent_atom(cst, view, val, acc, nid)
    end
  end

  # --- literal encoder (opt-in via `literal_encoder: fn val, meta -> {:ok, ast} | {:error, _} end`)
  # Elixir-compatible: called for each literal (int/float/atom/string/charlist/true/false/nil and
  # list / 2-tuple containers) with positional meta — `line:`/`column:` plus `range:` when ranges
  # are on. Lets bare literals (which otherwise have no metadata slot in the AST) carry source info.

  # A scalar leaf literal: `lit/6` only touches the token span when an encoder is installed, so the
  # default (no-encoder) path stays a bare value with zero extra work.
  defp lit(value, view, idx, opts, acc, nid, extra \\ []) do
    case opts.literal_encoder do
      nil ->
        {value, acc, nid}

      enc ->
        span = Tokens.span(view, idx)
        run_encoder_meta(enc, value, Enum.concat(extra, literal_meta(span, opts)), span, acc, nid)
    end
  end

  defp run_encoder_meta(enc, value, meta, span, acc, nid) do
    case enc.(value, meta) do
      {:ok, encoded} ->
        {encoded, acc, nid}

      {:error, reason} ->
        sp = if is_tuple(span), do: span, else: {1, 1, 1, 1}

        {id, acc, nid} =
          Diagnostics.emit(acc, nid, :lowerer, :error, :literal_encoder, sp, %{reason: reason})

        {{:__error__, [], %{diag_ids: [id]}}, acc, nid}
    end
  end

  defp literal_meta({sl, sc, _el, _ec} = span, opts),
    do: with_range([line: sl, column: sc], span, opts)

  defp literal_meta(_other, _opts), do: []

  # --- source ranges (opt-in via `range: true`) --------------------------------------------------
  # Each AST node that corresponds to source carries `range: {{start_line, start_col}, {end_line,
  # end_col}}` (end exclusive — one past the last char), separate from the `line:`/`column:` anchor
  # (which Elixir places on the operator for infix ops, not the expression start). The extent comes
  # straight from the green CST node's span, so a parent's range provably contains every child's.

  defp range_enabled?(opts), do: opts.range

  defp with_range(meta, span, opts) do
    case range_enabled?(opts) and span do
      {sl, sc, el, ec} -> [{:range, {{sl, sc}, {el, ec}}} | meta]
      _ -> meta
    end
  end

  # Token spans are only materialized when ranges are on (keeps the default lowering allocation-lean).
  defp maybe_token_range(meta, view, idx, opts) do
    if range_enabled?(opts), do: with_range(meta, Tokens.span(view, idx), opts), else: meta
  end

  # Node kinds that lower to a bare LITERAL value (not a `{form, meta, args}` node) when they hold
  # no interpolation / are 2-element: these feed the literal encoder. Interpolated strings/charlists
  # and 3+ tuples lower to real nodes (3-tuples) instead and take the range path.
  @literal_node_kinds [:list, :tuple, :string, :charlist, :quoted_atom]

  # One trivial clause per node kind (keeps each clause's cyclomatic complexity at 1).
  defp lower_node(cst, view, opts, acc, nid) do
    kind = CST.node_kind(cst)
    {ast, acc, nid} = lower_kind(kind, CST.children(cst), cst, view, opts, acc, nid)
    finalize_node(kind, ast, cst, view, opts, acc, nid)
  end

  # A real node result → attach its source range + token_metadata keys. A bare literal result from a
  # literal-bearing kind → run the literal encoder (keys flow into the encoder meta). Anything else
  # (e.g. a synthetic `nil`) passes through untouched.
  defp finalize_node(kind, {_form, meta, _args} = ast, cst, view, opts, acc, nid)
       when is_list(meta) do
    # Default fast path: with neither range nor token_metadata, put_node_range/tm_node_keys/tm_anchor
    # all no-op (range off → unchanged, tm off → [] keys, anchor → meta unchanged), so the whole
    # decoration reduces to the node itself. Skip the four helper calls + empty-list concat per node.
    if opts.range or opts.token_metadata do
      {form, ranged_meta, args} = put_node_range(ast, cst, opts)

      meta =
        tm_anchor(form, Enum.concat(tm_node_keys(kind, cst, view, opts), ranged_meta), cst, opts)

      {{form, meta, args}, acc, nid}
    else
      {ast, acc, nid}
    end
  end

  defp finalize_node(kind, ast, cst, view, opts, acc, nid) when kind in @literal_node_kinds do
    encode_node_literal(kind, ast, cst, view, opts, acc, nid)
  end

  # A parenthesised stab `(a -> b)` (e.g. a function type in a spec) lowers to a clause LIST, which
  # Elixir treats as a list literal — so the encoder wraps it. Single-expr / multi-stmt parens lower
  # to a node or an already-encoded child instead, so only the bare-list (stab) case lands here.
  defp finalize_node(:paren, ast, cst, view, opts, acc, nid) when is_list(ast),
    do: encode_node_literal(:list, ast, cst, view, opts, acc, nid)

  defp finalize_node(_kind, ast, _cst, _view, _opts, acc, nid), do: {ast, acc, nid}

  defp encode_node_literal(kind, ast, cst, view, opts, acc, nid) do
    case opts.literal_encoder do
      nil ->
        {ast, acc, nid}

      enc ->
        span = CST.span(cst)
        meta = Enum.concat(tm_node_keys(kind, cst, view, opts), literal_meta(span, opts))
        run_encoder_meta(enc, ast, meta, span, acc, nid)
    end
  end

  # --- token_metadata (Elixir-compatible meta, opt-in via `token_metadata: true`) ----------------
  # Structural keys derivable from the green CST: `closing:` (close-delimiter position = node-span
  # end minus the close length), and `do:`/`end:` (the do-block span start = the `do` keyword,
  # span end minus 3 = the `end` keyword). No source / view needed.

  # `ambiguous_op: nil` — a no-parens local call whose SOLE argument is a space-separated unary
  # `+`/`-` (`foo -1`, `@all_info -1`). The parser only yields an `:np_call` here in the genuinely
  # ambiguous case (`foo - 1` parses as a binary op instead), so the shape itself is the trigger.
  defp ambiguous_op_meta({fun, meta, args} = ast, [_callee, arg], view, opts) when is_atom(fun) do
    if tm?(opts) and leading_unary_pm?(arg, view),
      do: {fun, [{:ambiguous_op, nil} | meta], args},
      else: ast
  end

  defp ambiguous_op_meta(ast, _ch, _view, _opts), do: ast

  # The argument BEGINS with a space-separated unary `+`/`-` — either directly (`foo -1`) or as the
  # leftmost operand of a wider expression (`@spec -float :: float`, where the arg is `… :: …`).
  defp leading_unary_pm?({:node, :unary_op, _sp, [op_leaf | _], _f, _d}, view),
    do: CST.tag(op_leaf) == :token and Tokens.value(view, CST.token_index(op_leaf)) in [:+, :-]

  defp leading_unary_pm?({:node, :binary_op, _sp, [left | _], _f, _d}, view),
    do: leading_unary_pm?(left, view)

  defp leading_unary_pm?(_arg, _view), do: false

  defp tm_node_keys(kind, cst, view, opts) do
    if tm?(opts) do
      Enum.concat([
        open_newlines(kind, cst, view, opts),
        doend_keys(cst, opts),
        closing_keys(kind, cst, view, opts),
        delimiter_keys(kind, cst, opts)
      ])
    else
      []
    end
  end

  # `newlines:` for a container / call / `fn`: the (comment-aware) newline count between the open
  # delimiter and the first inner element. `foo(\n a)` / `{\n a}` / `%{\n a: 1}` / `fn\n x -> …` → 1;
  # a newline only *between* later elements does not count. A struct carries it on its inner map.
  defp open_newlines(kind, cst, view, opts)
       when kind in [
              :call,
              :remote_call,
              :anon_call,
              :dot_tuple,
              :tuple,
              :map,
              :map_update,
              :bitstring,
              :list,
              :fn
            ] do
    case open_scan_pos(kind, cst, view, opts) do
      {line, col} ->
        case gap_newlines(opts, line, col) do
          n when n > 0 -> [newlines: n]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp open_newlines(_kind, _cst, _view, _opts), do: []

  # Where to start scanning for the post-open-delimiter newlines: just past `(`/`{`/`[`/`<<`/`%{`/`fn`.
  # For a (local) call the `(` follows the callee (child 0); for a remote call it follows the member
  # name (child 1) — but only when parens are actually present (`a.b`/`a.b c` have none); otherwise
  # the delimiter sits at the node-span start.
  defp open_scan_pos(:call, cst, view, opts), do: after_open_paren(cst, 0, view, opts)
  defp open_scan_pos(:remote_call, cst, view, opts), do: after_open_paren(cst, 1, view, opts)

  # `foo.(…)` / `Foo.{…}` — the open delimiter follows the base AND the `.`, so it sits one column
  # further than a plain call's `(`.
  defp open_scan_pos(:anon_call, cst, view, opts), do: after_dot_delim(cst, "(", view, opts)
  defp open_scan_pos(:dot_tuple, cst, view, opts), do: after_dot_delim(cst, "{", view, opts)

  # A map opens with `%{` (2) when written `%{…}`, but only `{` (1) as a struct's inner map
  # (`%Foo{…}`, where the `%` sits on the struct node), so measure the leading `%` from the source.
  defp open_scan_pos(kind, cst, _view, opts) when kind in [:map, :map_update] do
    case CST.span(cst) do
      {sl, sc, _el, _ec} ->
        len = if src_slice(opts, {sl, sc}, {sl, sc + 1}) == "%", do: 2, else: 1
        {sl, sc + len}

      _ ->
        nil
    end
  end

  defp open_scan_pos(kind, cst, _view, _opts) do
    case CST.span(cst) do
      {sl, sc, _el, _ec} -> {sl, sc + open_delim_len(kind)}
      _ -> nil
    end
  end

  defp open_delim_len(kind) when kind in [:list, :tuple], do: 1
  defp open_delim_len(_two_char), do: 2

  # The position just past the `(` following child `idx` (the callee / member name) — or `nil` when
  # the next char is not `(` (a paren-less call, which has no open-delimiter newlines).
  defp after_open_paren(cst, idx, view, opts) do
    with child when not is_nil(child) <- CST.children(cst) |> Enum.at(idx),
         {_, _, el, ec} <- child_span(child, view),
         "(" <- src_slice(opts, {el, ec}, {el, ec + 1}) do
      {el, ec + 1}
    else
      _ -> nil
    end
  end

  # `foo.(…)` / `Foo.{…}` — the open delimiter is the char one past the base's `.` (two past the base
  # end). Returns the position just inside it, or `nil` if the expected delimiter isn't there.
  defp after_dot_delim(cst, delim, view, opts) do
    with child when not is_nil(child) <- CST.children(cst) |> Enum.at(0),
         {_, _, el, ec} <- child_span(child, view),
         ^delim <- src_slice(opts, {el, ec + 1}, {el, ec + 2}) do
      {el, ec + 2}
    else
      _ -> nil
    end
  end

  # Container / operator nodes that lowering built with empty meta still need a `line:`/`column:`
  # anchor (the node-span start) under `token_metadata: true`, matching Elixir. The implicit
  # `:__block__` grouping is the one node Elixir leaves anchorless, so it is excluded.
  defp tm_anchor(:__block__, meta, _cst, _opts), do: meta

  defp tm_anchor(_form, meta, cst, opts) do
    if tm?(opts) and not Keyword.has_key?(meta, :line) do
      case CST.span(cst) do
        {sl, sc, _el, _ec} -> Enum.concat(meta, line: sl, column: sc)
        _ -> meta
      end
    else
      meta
    end
  end

  # A stab clause anchors at its `->` operator (not the clause start), matching Elixir, and records
  # `newlines:` when its body starts on a later line than the `->`.
  # Scan for `->` starting AFTER the clause head (the args' span end), never from the clause start —
  # otherwise a pattern that contains the literal text `->` (e.g. `fn "->" -> x end`) would match
  # inside the pattern instead of the real arrow.
  defp stab_arrow_meta(args_node, body_node, view, opts) do
    if tm?(opts) do
      case arrow_scan_start(args_node, view) do
        {line, col} ->
          last = with({bsl, _, _, _} <- child_span(body_node, view), do: bsl, else: (_ -> line))
          arrow = scan_op(opts, line, col, "->", last)
          nls = stab_newlines({line, col}, arrow, opts)
          Enum.concat([stab_parens_meta(args_node, view, opts), nls, arrow])

        _ ->
          []
      end
    else
      []
    end
  end

  # A parenthesised clause head (`fn (a, b) -> …`, `fn () -> …`, and the guarded `fn () when g -> …`)
  # records `parens: [line, column, closing: …]` on the `->` (the `(`…`)` span). The patterns are the
  # head children — unwrapped from a `stab_when` (which appends the guard) when a guard is present.
  defp stab_parens_meta(args_node, view, opts) do
    args_node |> stab_head_patterns() |> patterns_parens_meta(view, opts)
  end

  defp stab_head_patterns(args_node) do
    case CST.children(args_node) do
      [{:node, :stab_when, _sp, when_ch, _f, _d}] -> Enum.drop(when_ch, -1)
      children -> children
    end
  end

  # An empty `()` head is a single empty `:paren` node; a non-empty parenthesised head is the bare
  # patterns with a `(` just before the first and a `)` just after the last.
  defp patterns_parens_meta([{:node, :paren, {sl, sc, el, ec}, [], _f, _d}], _view, _opts),
    do: [parens: [closing: [line: el, column: ec - 1], line: sl, column: sc]]

  defp patterns_parens_meta([first | _] = pats, view, opts) do
    with {asl, asc, _, _} when asc > 1 <- child_span(first, view),
         {_, _, ael, aec} <- child_span(List.last(pats), view),
         "(" <- src_slice(opts, {asl, asc - 1}, {asl, asc}),
         ")" <- src_slice(opts, {ael, aec}, {ael, aec + 1}) do
      [parens: [closing: [line: ael, column: aec], line: asl, column: asc - 1]]
    else
      _ -> []
    end
  end

  defp patterns_parens_meta(_pats, _view, _opts), do: []

  # Where to begin scanning for the clause `->`: after the last pattern (so its text can't contain a
  # false `->`); for an empty head (`fn -> …`) there is no pattern, so start at the head's span start.
  defp arrow_scan_start(args_node, view) do
    case CST.children(args_node) do
      [] ->
        with({sl, sc, _, _} <- child_span(args_node, view), do: {sl, sc}, else: (_ -> nil))

      children ->
        with(
          {_, _, el, ec} <- child_span(List.last(children), view),
          do: {el, ec},
          else: (_ -> nil)
        )
    end
  end

  # newlines AFTER the `->` (comment-aware), scanning from just past the arrow.
  # newlines adjacent to the `->`: the count AFTER it (arrow at line end) if any, else BEFORE it
  # (arrow at line start, e.g. a guard then `\n  -> body`). Comment-aware via `gap_newlines`.
  defp stab_newlines({hl, hc}, [line: al, column: ac], opts) do
    after_n = gap_newlines(opts, al, ac + 2)
    n = if after_n > 0, do: after_n, else: gap_newlines(opts, hl, hc)
    if n > 0, do: [newlines: n], else: []
  end

  defp stab_newlines(_start, _arrow, _opts), do: []

  # Find `needle` in the source starting at (line, col), up to and including `last_line`. Returns
  # `[line: l, column: c]` (codepoint column) or `[]`. Used for operator anchors (`->`, `|`).
  defp scan_op(opts, line, col, needle, last_line) when line <= last_line do
    case src_line(opts, line) do
      nil ->
        []

      text ->
        seg = String.slice(text, col - 1, max(String.length(text) - (col - 1), 0))

        case String.split(seg, needle, parts: 2) do
          [before, _] -> [line: line, column: col + String.length(before)]
          _ -> scan_op(opts, line + 1, 1, needle, last_line)
        end
    end
  end

  defp scan_op(_opts, _line, _col, _needle, _last_line), do: []

  # `delimiter:` — the opening string/charlist/sigil delimiter, read from the source: at the node
  # span start for strings/charlists, after the leading `:` for quoted atoms, and after `~` + the
  # sigil name for sigils. A heredoc opens with the quote tripled (`"""` / `'''`).
  defp delimiter_keys(kind, cst, opts) when kind in [:string, :charlist, :quoted_atom, :sigil] do
    case CST.span(cst) do
      {sl, sc, _el, ec} ->
        head = src_slice(opts, {sl, sc}, {sl, sc + 40})

        case head && opening_delimiter(kind, head) do
          d when is_binary(d) -> [{:delimiter, d} | heredoc_indent(kind, d, ec)]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp delimiter_keys(_kind, _cst, _opts), do: []

  # A string/charlist heredoc carries `indentation:` = the closing delimiter's column − 1 (= the
  # node-span end col − 4, since the `"""`/`'''` close is 3 chars and the span end is exclusive).
  # Sigil heredocs put `indentation:` on their inner `<<>>` instead (see `build_sigil`).
  defp heredoc_indent(kind, d, ec) when kind in [:string, :charlist] and byte_size(d) == 3,
    do: [indentation: ec - 4]

  defp heredoc_indent(_kind, _d, _ec), do: []

  defp opening_delimiter(:string, head), do: delim_at(head)
  defp opening_delimiter(:charlist, head), do: delim_at(head)
  defp opening_delimiter(:quoted_atom, ":" <> rest), do: delim_at(rest)
  defp opening_delimiter(:quoted_atom, _), do: nil
  defp opening_delimiter(:sigil, "~" <> rest), do: delim_at(skip_sigil_name(rest))
  defp opening_delimiter(:sigil, _), do: nil

  # Skip the sigil name to reach the opening delimiter. Names are letters AND digits (an uppercase
  # sigil may carry digits, e.g. `~A1(…)`), so a digit must not be mistaken for the delimiter.
  defp skip_sigil_name(<<c, rest::binary>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9,
    do: skip_sigil_name(rest)

  defp skip_sigil_name(rest), do: rest

  defp delim_at(~S(""") <> _), do: ~S(""")
  defp delim_at("'''" <> _), do: "'''"
  defp delim_at(<<c::utf8, _::binary>>), do: <<c::utf8>>
  defp delim_at(_), do: nil

  # `token:` — the raw source text of a numeric / char literal (preserves `0x1F`, `1_000`, `?a`).
  defp tm_token(view, idx, opts) do
    if tm?(opts) do
      {sl, sc, el, ec} = Tokens.span(view, idx)

      case src_slice(opts, {sl, sc}, {el, ec}) do
        t when is_binary(t) -> [token: t]
        _ -> []
      end
    else
      []
    end
  end

  # Kinds with an UNCONDITIONAL close delimiter: list `]`, tuple/map/map-update `}` (1 char);
  # bitstring `>>` (2); `fn … end` (3). A struct (`%Foo{…}`) carries no `closing:` itself — the inner
  # `%{}` map / map-update node does. Calls have OPTIONAL parens (`foo(a)` vs `try do … end`, both
  # `:call`; `Mod.fun(x)` vs `a.b`, both `:remote_call`), so confirm the span ends at `)` against the
  # source — a paren-less remote call instead gets `no_parens: true`.
  defp closing_keys(kind, cst, view, opts) do
    case {kind, CST.span(cst)} do
      {k, {_sl, _sc, el, ec}} when k in [:list, :tuple, :map, :map_update, :dot_tuple] ->
        [closing: [line: el, column: ec - 1]]

      {:bitstring, {_sl, _sc, el, ec}} ->
        [closing: [line: el, column: ec - 2]]

      {:fn, {_sl, _sc, el, ec}} ->
        [closing: [line: el, column: ec - 3]]

      {k, {_sl, _sc, el, ec}} when k in [:call, :remote_call] ->
        call_closing(k, cst, el, ec, view, opts)

      _ ->
        []
    end
  end

  # A call carries `closing:` only when it has actual parens — detected by a `(` immediately after
  # the callee/member (NOT by the span ending in `)`, which `IO.puts foo(x)` would falsely satisfy).
  # When the parenthesised args are followed by a do-block (`quote(x) do … end`), the `)` sits before
  # the block, so locate it; otherwise it is the span's last char. A bare zero-arity remote call
  # (`a.b`) instead gets `no_parens: true`.
  defp call_closing(k, cst, el, ec, view, opts) do
    cond do
      after_open_paren(cst, callee_idx(k), view, opts) == nil ->
        if k == :remote_call and remote_zero_arity?(cst), do: [no_parens: true], else: []

      src_slice(opts, {el, ec - 1}, {el, ec}) == ")" ->
        [closing: [line: el, column: ec - 1]]

      true ->
        close_paren_before_do(cst, opts)
    end
  end

  defp callee_idx(:call), do: 0
  defp callee_idx(:remote_call), do: 1

  # The `)` closing a paren call's args when a do-block follows (`quote(x) do … end`): the last `)`
  # in the source from the call start up to the do-block's `do`.
  defp close_paren_before_do(cst, opts) do
    with {:node, :do_block, {dsl, dsc, _, _}, _, _, _} <-
           Enum.find(CST.children(cst), &match?({:node, :do_block, _, _, _, _}, &1)),
         {sl, sc, _el, _ec} <- CST.span(cst) do
      last_paren(opts, sl, sc, dsl, dsc)
    else
      _ -> []
    end
  end

  defp last_paren(opts, sl, sc, dsl, dsc) do
    Enum.reduce(sl..dsl, [], fn line, acc ->
      text = src_line(opts, line) || ""
      from = if line == sl, do: sc, else: 1
      upto = if line == dsl, do: dsc - 1, else: String.length(text)
      seg = String.slice(text, from - 1, max(upto - from + 1, 0))

      case last_index_of(seg, ")") do
        nil -> acc
        i -> [closing: [line: line, column: from + i]]
      end
    end)
  end

  defp last_index_of(s, ch) do
    case String.split(s, ch) do
      [_] -> nil
      parts -> String.length(s) - String.length(List.last(parts)) - 1
    end
  end

  # `do:` / `end:` come from the do-block span (start = `do`, end − 3 = `end`). On TOLERANT/invalid
  # input the block may be unterminated (recovered missing `end`), which would yield an impossible
  # position (e.g. column 0); emit each key only when the source actually has the keyword there.
  # A remote call with exactly `[base, member]` children — no argument and no do-block, i.e. `a.b`.
  defp remote_zero_arity?(cst), do: match?([_base, _member], CST.children(cst))

  defp doend_keys(cst, opts) do
    case Enum.find(CST.children(cst), &match?({:node, :do_block, _, _, _, _}, &1)) do
      {:node, :do_block, {sl, sc, el, ec}, _ch, _f, _d} ->
        Enum.concat(kw_at(opts, sl, sc, "do", :do), kw_at(opts, el, ec - 3, "end", :end))

      _ ->
        []
    end
  end

  defp kw_at(opts, line, col, word, key) do
    if col >= 1 and src_slice(opts, {line, col}, {line, col + String.length(word)}) == word,
      do: [{key, [line: line, column: col]}],
      else: []
  end

  # Attach this CST node's span as the range — UNLESS the lowered result already carries one, which
  # means `lower_kind` passed a child through transparently (single-statement block/paren); the
  # child's own (tighter) range must win.
  defp put_node_range({form, meta, args}, cst, opts) when is_list(meta) do
    if range_enabled?(opts) and not Keyword.has_key?(meta, :range) do
      {form, with_range(meta, CST.span(cst), opts), args}
    else
      {form, meta, args}
    end
  end

  defp put_node_range(ast, _cst, _opts), do: ast

  # Atomize a source-derived name via `build`, or — under `existing_atoms_only` for a missing
  # atom — emit a lowerer diagnostic and an error node (never raise).
  defp atomize(cst, view, opts, acc, nid, val, build) do
    case to_atom(val, opts) do
      {:ok, atom} -> {build.(atom), acc, nid}
      :error -> nonexistent_atom(cst, view, val, acc, nid)
    end
  end

  defp nonexistent_atom(cst, view, val, acc, nid) do
    {id, acc, nid} =
      Diagnostics.emit(acc, nid, :lowerer, :error, :nonexistent_atom, name_span(cst, view), %{
        name: val
      })

    {{:__error__, error_meta(cst, view), %{diag_ids: [id]}}, acc, nid}
  end

  # One trivial clause per node kind (keeps each clause's cyclomatic complexity at 1).
  # An empty top-level program is the grammar's `$empty`/`eoe` rule: since Elixir 1.20 its
  # `__block__` is anchored at `[line: 1, column: 1]` (token-metadata only; normalized away otherwise).
  defp lower_kind(:expr_list, [], _cst, _view, opts, acc, nid),
    do: {{:__block__, if(tm?(opts), do: [line: 1, column: 1], else: []), []}, acc, nid}

  defp lower_kind(:expr_list, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(:paren, ch, cst, view, opts, acc, nid),
    do: lower_paren(ch, cst, view, opts, acc, nid)

  # A leading `;` empty statement in a stab body (`-> ;t` => `__block__([nil, t])`) lowers to `nil`.
  defp lower_kind(:empty_stmt, _ch, _cst, _view, _opts, acc, nid), do: {nil, acc, nid}

  defp lower_kind(:binary_op, ch, _cst, view, opts, acc, nid),
    do: lower_binary(ch, view, opts, acc, nid)

  defp lower_kind(:unary_op, ch, _cst, view, opts, acc, nid),
    do: lower_unary(ch, view, opts, acc, nid)

  # An operator function reference (`+/2` => `{:/, [], [{:+, [], nil}, 2]}`): the bare operator
  # lowers to `{:op_atom, meta, nil}`, the variable-like form the reference's `/arity` divides.
  defp lower_kind(:op_ref, [op_leaf], _cst, view, _opts, acc, nid),
    do: {{op_atom(op_leaf, view), op_meta(op_leaf, view), nil}, acc, nid}

  defp lower_kind(:list, ch, _cst, view, opts, acc, nid), do: lower_list(ch, view, opts, acc, nid)

  # A synthesized keyword list (bare `when a: t` guard) — lowers like a list but is NOT a list
  # literal, so `finalize_node` leaves it un-encoded (matches the oracle).
  defp lower_kind(:kw_list, ch, _cst, view, opts, acc, nid),
    do: lower_each(ch, view, opts, acc, nid)

  defp lower_kind(:tuple, ch, _cst, view, opts, acc, nid),
    do: lower_tuple(ch, view, opts, acc, nid)

  defp lower_kind(:call, ch, _cst, view, opts, acc, nid), do: lower_call(ch, view, opts, acc, nid)

  # A no-parens call lowers identically to a paren call (`f a` and `f(a)` produce the same AST).
  defp lower_kind(:np_call, ch, _cst, view, opts, acc, nid) do
    {ast, acc, nid} = lower_call(ch, view, opts, acc, nid)
    {ambiguous_op_meta(ast, ch, view, opts), acc, nid}
  end

  defp lower_kind(:alias, ch, _cst, view, opts, acc, nid),
    do: lower_alias(ch, view, opts, acc, nid)

  defp lower_kind(:remote_call, ch, _cst, view, opts, acc, nid),
    do: lower_remote_call(ch, view, opts, acc, nid)

  # `Foo.{A, B}` => `{{:., _, [base, :{}]}, _, [elems]}` (multi-alias / `alias Foo.{...}`). The dot
  # and the call both anchor at the `.` (between base and `{`); `closing:` (the `}`) is added by
  # `closing_keys`/`finalize_node`.
  defp lower_kind(:dot_tuple, [base | elems], _cst, view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {elem_asts, acc, nid} = lower_args(elems, view, opts, acc, nid)
    dm = remote_dot_meta(base, view, opts) || []
    {{{:., dm, [base_ast, :{}]}, dm, elem_asts}, acc, nid}
  end

  defp lower_kind(:anon_call, ch, cst, view, opts, acc, nid),
    do: lower_anon_call(ch, cst, view, opts, acc, nid)

  defp lower_kind(:kw_pair, ch, _cst, view, opts, acc, nid),
    do: lower_kw_pair(ch, view, opts, acc, nid)

  defp lower_kind(:bitstring, ch, _cst, view, opts, acc, nid),
    do: lower_bitstring(ch, view, opts, acc, nid)

  defp lower_kind(:access, ch, cst, view, opts, acc, nid),
    do: lower_access(ch, cst, view, opts, acc, nid)

  defp lower_kind(:map, ch, _cst, view, opts, acc, nid), do: lower_map(ch, view, opts, acc, nid)

  defp lower_kind(:map_update, ch, _cst, view, opts, acc, nid),
    do: lower_map_update(ch, view, opts, acc, nid)

  defp lower_kind(:struct, ch, _cst, view, opts, acc, nid),
    do: lower_struct(ch, view, opts, acc, nid)

  defp lower_kind(:assoc, ch, _cst, view, opts, acc, nid),
    do: lower_assoc(ch, view, opts, acc, nid)

  defp lower_kind(:not_in_op, ch, _cst, view, opts, acc, nid),
    do: lower_not_in(ch, view, opts, acc, nid)

  defp lower_kind(:fn, ch, _cst, view, opts, acc, nid) do
    {clauses, acc, nid} = lower_each(ch, view, opts, acc, nid)
    {{:fn, [], clauses}, acc, nid}
  end

  defp lower_kind(:stab, [args_node, body_node], _cst, view, opts, acc, nid) do
    {args, acc, nid} = lower_stab_args(args_node, view, opts, acc, nid)
    {body, acc, nid} = lower_stab_body(body_node, view, opts, acc, nid)
    {{:->, stab_arrow_meta(args_node, body_node, view, opts), [args, body]}, acc, nid}
  end

  defp lower_kind(:string, ch, _cst, view, opts, acc, nid),
    do: lower_string(ch, view, opts, acc, nid)

  defp lower_kind(:charlist, ch, cst, view, opts, acc, nid),
    do: lower_charlist(ch, cst, view, opts, acc, nid)

  defp lower_kind(:sigil, ch, cst, view, opts, acc, nid),
    do: lower_sigil(ch, cst, view, opts, acc, nid)

  # `:"..."` / `:'...'` — no interpolation lowers to the atom (atom policy); with interpolation to
  # `:erlang.binary_to_atom(<<...>>, :utf8)`.
  defp lower_kind(:quoted_atom, [inner], cst, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(CST.children(inner), view, opts, acc, nid)
    build_quoted_atom(parts, inner, cst, false, view, opts, acc, nid)
  end

  # An interpolation's inner is a block (`#{a; b}` → `{:__block__, ...}`, `#{a}` → `a`).
  defp lower_kind(:interp, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(_other, _ch, cst, view, _opts, acc, nid), do: {error_ast(cst, view), acc, nid}

  # A string lowers to a bare binary with no interpolation, else the `<<>>` form Elixir uses:
  # fragments stay binaries; each interpolation becomes a `Kernel.to_string/1` ::-binary segment.
  defp lower_string(children, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(children, view, opts, acc, nid)
    build_string(parts, opts, acc, nid)
  end

  # A charlist lowers to a literal codepoint list with no interpolation, else to
  # `List.to_charlist([...])` where interpolations are bare `Kernel.to_string/1` (no ::-binary).
  defp lower_charlist(children, cst, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(children, view, opts, acc, nid)
    build_charlist(parts, cst, view, opts, acc, nid)
  end

  # Collect a quoted literal's parts as `{:frag, binary}` / `{:interp, ast}`, in source order.
  # Error leaves (unterminated marker) are skipped — their diagnostic is already emitted.
  defp quoted_parts_ast(children, view, opts, acc, nid) do
    {rev_parts, acc, nid} =
      Enum.reduce(children, {[], acc, nid}, fn child, {parts, a, n} ->
        lower_quoted_part(child, view, opts, parts, a, n)
      end)

    {:lists.reverse(rev_parts), acc, nid}
  end

  defp lower_quoted_part(child, view, opts, parts, acc, nid) do
    case CST.tag(child) do
      :token -> lower_fragment_part(child, view, parts, acc, nid)
      :node -> lower_interp_part(child, view, opts, parts, acc, nid)
      _ -> {parts, acc, nid}
    end
  end

  defp lower_fragment_part(child, view, parts, acc, nid) do
    if Tokens.kind(view, CST.token_index(child)) in [:string_fragment, :charlist_fragment] do
      {[{:frag, Tokens.value(view, CST.token_index(child))} | parts], acc, nid}
    else
      {parts, acc, nid}
    end
  end

  defp lower_interp_part(child, view, opts, parts, acc, nid) do
    if CST.node_kind(child) == :interp do
      {ast, acc, nid} = lower_block(CST.children(child), view, opts, acc, nid)
      {[{:interp, ast, CST.span(child)} | parts], acc, nid}
    else
      {parts, acc, nid}
    end
  end

  defp build_string(parts, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      {{:<<>>, [], Enum.map(parts, &string_segment(&1, opts))}, acc, nid}
    else
      {parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary(), acc, nid}
    end
  end

  defp build_charlist(parts, cst, view, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      {{{:., [], [List, :to_charlist]}, [], [Enum.map(parts, &charlist_segment(&1, opts))]}, acc,
       nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()
      # A charlist's content is decoded as UTF-8 codepoints, so a non-UTF-8 byte (e.g. `'\xFF'`,
      # which yields the raw byte rather than codepoint U+00FF) is an error — unlike a string, where
      # `<<255>>` is a valid binary. The tolerant `[255]` charlist is still produced.
      {acc, nid} =
        if String.valid?(bin),
          do: {acc, nid},
          else: invalid_charlist_encoding(cst, view, acc, nid)

      {safe_to_charlist(bin), acc, nid}
    end
  end

  defp invalid_charlist_encoding(cst, view, acc, nid) do
    {_id, acc, nid} =
      Diagnostics.emit(
        acc,
        nid,
        :lowerer,
        :error,
        :invalid_charlist_encoding,
        child_span(cst, view),
        %{}
      )

    {acc, nid}
  end

  defp build_quoted_atom(parts, inner, anchor, kw?, view, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      segs = Enum.map(parts, &string_segment(&1, opts))
      pos = qatom_pos(anchor, view, opts)
      head = qatom_head(anchor, kw?, view, opts)

      {{{:., pos, [:erlang, :binary_to_atom]}, Enum.concat(head, pos),
        [{:<<>>, pos, segs}, :utf8]}, acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()
      atomize_quoted(bin, inner, opts, view, acc, nid)
    end
  end

  # token_metadata for an INTERPOLATED quoted atom / keyword key (`:"a#{b}"`, `"k#{i}": v`), which
  # lowers to an `:erlang.binary_to_atom` construction. `pos` anchors at the atom/key start; the
  # call also carries the opening `delimiter:` and, for a keyword key, `format: :keyword`.
  defp qatom_pos(anchor, view, opts) do
    if tm?(opts) do
      case child_span(anchor, view) do
        {sl, sc, _el, _ec} -> [line: sl, column: sc]
        _ -> []
      end
    else
      []
    end
  end

  # Only a keyword key needs the head built here: it is lowered inline (no `finalize_node`), so its
  # `delimiter:` + `format: :keyword` must be added now. A bare `:"a#{b}"` atom literal IS finalized,
  # which supplies `delimiter:` — adding it here too would duplicate it.
  defp qatom_head(anchor, true = _kw?, view, opts) do
    if tm?(opts) do
      delim =
        case child_span(anchor, view) do
          {sl, sc, _el, _ec} ->
            head = src_slice(opts, {sl, sc}, {sl, sc + 40}) || ""

            case head do
              ":" <> rest -> delim_at(rest)
              _ -> delim_at(head)
            end

          _ ->
            nil
        end

      d = if is_binary(delim), do: [delimiter: delim], else: []
      Enum.concat(d, format: :keyword)
    else
      []
    end
  end

  defp qatom_head(_anchor, false = _kw?, _view, _opts), do: []

  defp atomize_quoted(bin, inner, opts, view, acc, nid) do
    case to_atom(bin, opts) do
      {:ok, atom} ->
        {atom, acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :nonexistent_atom,
            atom_span(inner, view),
            %{
              name: bin
            }
          )

        {{:__error__, [], %{diag_ids: [id]}}, acc, nid}
    end
  end

  defp atom_span(inner, _view), do: CST.span(inner) || {1, 1, 1, 1}

  defp string_segment({:frag, bin}, _opts), do: bin

  defp string_segment({:interp, ast, span}, opts) do
    pos = interp_pos(span, opts)
    {:"::", pos, [interp_to_string(ast, span, opts), {:binary, pos, nil}]}
  end

  defp charlist_segment({:frag, bin}, _opts), do: bin
  defp charlist_segment({:interp, ast, span}, opts), do: interp_to_string(ast, span, opts)

  # The `Kernel.to_string/1` call wrapping an interpolation `#{…}`. Under `token_metadata: true` it
  # carries `from_interpolation: true` + `closing:` (the `}` = interp span end − 1), all anchored at
  # the interpolation start (the `#`). Otherwise the synthetic meta stays empty.
  defp interp_to_string(ast, span, opts) do
    pos = interp_pos(span, opts)
    callmeta = interp_call_meta(span, opts)
    {{:., pos, [Kernel, :to_string]}, callmeta, [ast]}
  end

  defp interp_pos(_span, %{token_metadata: false}), do: []
  defp interp_pos({sl, sc, _el, _ec}, _opts), do: [line: sl, column: sc]
  defp interp_pos(_other, _opts), do: []

  defp interp_call_meta(_span, %{token_metadata: false}), do: []

  defp interp_call_meta({sl, sc, el, ec}, _opts),
    do: [from_interpolation: true, closing: [line: el, column: ec - 1], line: sl, column: sc]

  defp interp_call_meta(_other, _opts), do: []

  # A sigil → `{:"sigil_<name>", [], [{:<<>>, [], segs}, modifier_charlist]}`. Content segments are
  # like a string's (the sigil macro does any further unescaping at expansion); the name atom
  # respects the atom policy. children = [start_leaf | parts... | end_leaf].
  defp lower_sigil([start_leaf | rest], cst, view, opts, acc, nid) do
    name = Tokens.value(view, CST.token_index(start_leaf))
    {part_children, mods} = sigil_split(rest, view)
    {parts, acc, nid} = quoted_parts_ast(part_children, view, opts, acc, nid)

    build_sigil(
      name,
      parts,
      mods,
      start_leaf,
      sigil_inner_meta(cst, mods, opts),
      view,
      opts,
      acc,
      nid
    )
  end

  # The inner `<<>>` of a sigil anchors at the sigil start; a heredoc sigil (`~s\"\"\"…\"\"\"`) also
  # carries `indentation:` there (the closing-delimiter column − 1 = span end − 4).
  defp sigil_inner_meta(cst, mods, opts) do
    if tm?(opts) do
      case CST.span(cst) do
        {sl, sc, _el, ec} ->
          head = src_slice(opts, {sl, sc}, {sl, sc + 40})

          case head && opening_delimiter(:sigil, head) do
            # Heredoc sigil: `indentation:` = the closing `"""`/`'''` column − 1. The span end also
            # spans any trailing modifiers (`~r'''…'''x`), so discount their length too.
            d when is_binary(d) and byte_size(d) == 3 ->
              [indentation: ec - String.length(mods) - 4, line: sl, column: sc]

            _ ->
              [line: sl, column: sc]
          end

        _ ->
          []
      end
    else
      []
    end
  end

  # The modifiers live on the trailing `:sigil_end` leaf (last child), if the run closed.
  defp sigil_split([], _view), do: {[], ""}

  defp sigil_split(children, view) do
    [last | rev] = :lists.reverse(children)

    case last do
      {:token, idx, _f, _d} ->
        if Tokens.kind(view, idx) == :sigil_end,
          do: {:lists.reverse(rev), Tokens.value(view, idx) || ""},
          else: {children, ""}

      _ ->
        {children, ""}
    end
  end

  defp build_sigil(name, parts, mods, start_leaf, inner_meta, view, opts, acc, nid) do
    case to_atom("sigil_" <> name, opts) do
      {:ok, atom} ->
        {{atom, [], [{:<<>>, inner_meta, sigil_segments(parts, opts)}, safe_to_charlist(mods)]},
         acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :nonexistent_atom,
            name_span(start_leaf, view),
            %{
              name: "sigil_" <> name
            }
          )

        {{:__error__, error_meta(start_leaf, view), %{diag_ids: [id]}}, acc, nid}
    end
  end

  # A sigil's `<<>>` always has at least one (possibly empty) binary segment (`~s()` → [""]).
  defp sigil_segments([], _opts), do: [""]
  defp sigil_segments(parts, opts), do: Enum.map(parts, &string_segment(&1, opts))

  defp lower_block([], _view, _opts, acc, nid), do: {{:__block__, [], []}, acc, nid}

  defp lower_block([only], view, opts, acc, nid) do
    {ast, acc, nid} = lower(only, view, opts, acc, nid)
    {wrap_splice(attach_eoe(ast, only, view, opts)), acc, nid}
  end

  defp lower_block(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_stmts(children, view, opts, acc, nid)
    {{:__block__, [], asts}, acc, nid}
  end

  # Like `lower_each`, but attaches `end_of_expression` to each statement (token_metadata).
  defp lower_stmts(children, view, opts, acc, nid) do
    {rev, acc, nid} =
      Enum.reduce(children, {[], acc, nid}, fn child, {asts, a, n} ->
        {ast, a, n} = lower(child, view, opts, a, n)
        {[attach_eoe(ast, child, view, opts) | asts], a, n}
      end)

    {:lists.reverse(rev), acc, nid}
  end

  # Parentheses are transparent in the AST (they only carry metadata upstream).
  # A paren is a statement block: empty => empty block, one => the expr (transparent), many =>
  # `__block__`. A trailing recovered `:missing` (no `)`) is skipped — its diagnostic is emitted.
  defp lower_paren(children, cst, view, opts, acc, nid) do
    children = Enum.reject(children, &(CST.tag(&1) == :missing))

    # A paren of stab clauses (`(a -> b; c -> d)`) lowers to the bare clause LIST `[{:->, …}, …]`,
    # not a statement block.
    if Enum.any?(children, &stab_node?/1) do
      lower_each(children, view, opts, acc, nid)
    else
      {ast, acc, nid} = lower_block(children, view, opts, acc, nid)
      {acc, nid} = maybe_empty_paren_warn(ast, cst, opts, acc, nid)
      {add_parens_meta(wrap_paren_negation(ast), children, cst, opts), acc, nid}
    end
  end

  # `()` (also `( )`, `(\n)`) is an empty parenthesised expression — Elixir warns it's invalid; pass
  # a value like `nil` instead. But `(;)` is a `;`-block (a different grammar production) and does
  # NOT warn, so check the source between the delimiters for a `;`. Scoped to paren EXPRESSIONS:
  # stab-clause-head `()` (`fn () -> …`) is lowered elsewhere, not through here.
  defp maybe_empty_paren_warn({:__block__, _meta, []}, cst, opts, acc, nid) do
    {sl, sc, el, ec} = CST.span(cst)

    if String.contains?(src_slice(opts, {sl, sc + 1}, {el, ec}) || "", ";") do
      {acc, nid}
    else
      {_id, acc, nid} =
        Diagnostics.emit(acc, nid, :parser, :warning, :empty_paren, CST.span(cst), %{})

      {acc, nid}
    end
  end

  defp maybe_empty_paren_warn(_ast, _cst, _opts, acc, nid), do: {acc, nid}

  # Empty parens. `()` is Elixir's `empty_paren` → `{:__block__, [parens: …], []}`; `(;)` is the
  # `open_paren ';' close_paren` rule → `{:__block__, [closing: …, line, column], []}`. Both lower to
  # an empty block here, so the `;` is detected from the source (only meaningful under token_metadata,
  # where `source_lines` is available; otherwise the empty block stays bare, matching `()` no-tm).
  defp add_parens_meta({:__block__, _meta, []}, [], cst, opts) do
    with true <- tm?(opts),
         {sl, sc, el, ec} <- CST.span(cst) do
      closing = [line: el, column: ec - 1]

      if String.contains?(src_slice(opts, {sl, sc + 1}, {el, ec - 1}) || "", ";"),
        do: {:__block__, [closing: closing, line: sl, column: sc], []},
        else: {:__block__, [parens: [closing: closing, line: sl, column: sc]], []}
    else
      _ -> {:__block__, [], []}
    end
  end

  # A single-expression parenthesised group (`(a + b)`) records the parens on the inner node's meta
  # as `parens: [line, column, closing: …]` (the `(`…`)` span), matching Elixir. Each nesting layer
  # prepends another entry (`((a))` → two), outermost first. Multi-statement parens are a block and
  # carry `closing:` instead (handled as a node), so only the single-child case attaches `parens:`.
  # A MULTI-statement parenthesised group lowers to a `__block__` that corresponds to real `(`…`)`
  # delimiters; unlike the implicit top-level block it carries `closing:` (the `)`) and a
  # `line:`/`column:` anchor at the `(`. (A single-expression `__block__` here is the synthetic
  # `(not x)` negation wrapper — Elixir leaves that one anchorless, so it must NOT match.)
  defp add_parens_meta({:__block__, meta, stmts}, [_, _ | _], cst, opts) do
    parens_block(meta, stmts, cst, opts)
  end

  # `(unquote_splicing(x))` is a single-child paren that `wrap_splice` turns into a `__block__`; it is
  # still a real `(`…`)` group (unlike the `(not x)` negation wrapper), so it gets the block anchor.
  defp add_parens_meta(
         {:__block__, meta, [{:unquote_splicing, _, _}] = stmts},
         [_single],
         cst,
         opts
       ),
       do: parens_block(meta, stmts, cst, opts)

  # `(not x)` / `(! x)` is `wrap_paren_negation`'s synthetic `__block__` (empty meta, a single unary
  # node) — Elixir leaves it anchorless, so it gets NO `parens:` entry.
  defp add_parens_meta({:__block__, [], [{op, _, [_]}]} = ast, [_single], _cst, _opts)
       when op in [:not, :!],
       do: ast

  # Any other single-expression parenthesised group records `parens: [line, column, closing: …]` on
  # the inner node's meta (each nesting layer prepends one; `((a))` → two, outermost first). This
  # includes encoder-wrapped literals (`({a, b})`) and a paren around a multi-statement block.
  defp add_parens_meta({f, meta, a}, [_single], cst, opts) do
    if tm?(opts) do
      case CST.span(cst) do
        {sl, sc, el, ec} ->
          {f, [{:parens, [closing: [line: el, column: ec - 1], line: sl, column: sc]} | meta], a}

        _ ->
          {f, meta, a}
      end
    else
      {f, meta, a}
    end
  end

  defp add_parens_meta(ast, _children, _cst, _opts), do: ast

  defp parens_block(meta, stmts, cst, opts) do
    case tm?(opts) && CST.span(cst) do
      {sl, sc, el, ec} ->
        anchor = [closing: [line: el, column: ec - 1], line: sl, column: sc]
        {:__block__, Enum.concat(anchor, meta), stmts}

      _ ->
        {:__block__, meta, stmts}
    end
  end

  defp stab_node?(cst), do: CST.tag(cst) == :node and CST.node_kind(cst) == :stab

  # A parenthesised boolean negation is wrapped in a `__block__` — `(not x)` => `{:__block__, [],
  # [{:not, [], [x]}]}`, likewise `(! x)` — preserving the parenthesisation the `not in`
  # deprecation relies on. (`-`/`+` and binary ops are NOT wrapped.)
  defp wrap_paren_negation({op, _, [_]} = ast) when op in [:not, :!], do: {:__block__, [], [ast]}
  defp wrap_paren_negation(ast), do: ast

  # A sole empty `()` head means zero patterns (`fn () when g`/`fn () ->`); anything else is kept.
  defp strip_empty_paren_head([{:node, :paren, _sp, [], _f, _d}]), do: []
  defp strip_empty_paren_head(pats), do: pats

  defp lower_binary([lhs, op_leaf, rhs], view, opts, acc, nid) do
    cond do
      op_atom(op_leaf, view) == :in and negation_unary?(lhs, view) ->
        lower_deprecated_not_in(lhs, op_leaf, rhs, view, opts, acc, nid)

      op_atom(op_leaf, view) == :"//" ->
        lower_slash_slash(lhs, op_leaf, rhs, view, opts, acc, nid)

      true ->
        {l, acc, nid} = lower(lhs, view, opts, acc, nid)
        {r, acc, nid} = lower(rhs, view, opts, acc, nid)
        meta = Enum.concat(op_newlines(lhs, op_leaf, rhs, view, opts), op_meta(op_leaf, view))
        {{op_atom(op_leaf, view), meta, [l, r]}, acc, nid}
    end
  end

  # A binary operator records `newlines:` when a line break is adjacent to it — the count after the
  # operator (operator at line end) if any, else the count before it (operator at line start). The
  # count is the line delta between the operand and the operator (blank lines included).
  # `newlines:` on a binary operator: the count AFTER the operator (operator at line end) if any,
  # else the count BEFORE it (operator at line start). `gap_newlines` stops at the next token, so
  # scanning from the operator end yields the after-count and from the lhs end the before-count.
  defp op_newlines(lhs, op_leaf, _rhs, view, opts) do
    if tm?(opts) do
      {_l1, _c1, lel, lec} = child_span(lhs, view)
      {_osl, _osc, oel, oec} = child_span(op_leaf, view)
      after_n = gap_newlines(opts, oel, oec)
      n = if after_n > 0, do: after_n, else: gap_newlines(opts, lel, lec)
      if n > 0, do: [newlines: n], else: []
    else
      []
    end
  end

  # `a..b//c` is the ternary step range `{:..//, _, [a, b, c]}` — i.e. a `//` whose left side is a
  # range. We test the LOWERED lhs (so a parenthesised range works too: `(a..b)//c`).
  defp lower_slash_slash(lhs, op_leaf, rhs, view, opts, acc, nid) do
    {l, acc, nid} = lower(lhs, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)

    case l do
      # Valid only as the range step: `a..b//c` (lhs a 2-element range, incl. through parens). The
      # `..//` anchors where the range's `..` does (Elixir reuses that position) — take only the
      # line/column anchor, not the lhs `range:`, so `..//` still gets its own (wider) range.
      {:.., m, [a, b]} ->
        {{:..//, Keyword.take(m, [:line, :column]), [a, b, r]}, acc, nid}

      # `//` is NOT a general binary operator — Elixir rejects `a // b`, `a..b//c//d`,
      # `a..(b // c)`. Toxic2 is tolerant: emit an error and keep a best-effort `//` node (P1/P5).
      _ ->
        {_id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :misplaced_step_op,
            name_span(op_leaf, view),
            %{}
          )

        {{:"//", op_meta(op_leaf, view), [l, r]}, acc, nid}
    end
  end

  # `not a in b` (an `in` whose LHS is a bare unary `not`) is the deprecated spelling of
  # `not(a in b)`. Rewrite it here (P5) and emit a deprecation `:warning`. `(not a) in b`
  # (parenthesized) is a `:paren` lhs, so it is not matched and keeps its literal meaning.
  defp lower_deprecated_not_in(
         {:node, :unary_op, _sp, [neg_leaf, operand], _f, _d},
         op_leaf,
         rhs,
         view,
         opts,
         acc,
         nid
       ) do
    neg = Tokens.value(view, CST.token_index(neg_leaf))
    {o, acc, nid} = lower(operand, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)
    span = Tokens.span(view, CST.token_index(op_leaf)) || {1, 1, 1, 1}

    {_id, acc, nid} =
      Diagnostics.emit(acc, nid, :lowerer, :warning, :deprecated_not_in, span, %{})

    # `not x in y` (deprecated): since Elixir 1.20 the outer `not`/`!` keeps its OWN meta (the
    # `not`/`!` token), while the inner `in` is anchored at the `in` operator.
    not_m = if tm?(opts), do: op_meta(neg_leaf, view), else: []
    in_m = if tm?(opts), do: op_meta(op_leaf, view), else: []
    {{neg, not_m, [{:in, in_m, [o, r]}]}, acc, nid}
  end

  # `not a in b` / `!a in b` — a bare `not`/`!` left of `in` is the membership-negation form
  # `not(a in b)` / `!(a in b)` (`not` binds looser than `in` here). Parenthesising the operand
  # (`(not a) in b`) gives a `:paren` lhs, which is not matched, so it keeps its literal meaning.
  defp negation_unary?({:node, :unary_op, _sp, [op_leaf, _operand], _f, _d}, view),
    do: Tokens.value(view, CST.token_index(op_leaf)) in [:not, :!]

  defp negation_unary?(_lhs, _view), do: false

  defp lower_unary([op_leaf, operand], view, opts, acc, nid) do
    {o, acc, nid} = lower(operand, view, opts, acc, nid)
    {{op_atom(op_leaf, view), op_meta(op_leaf, view), [o]}, acc, nid}
  end

  # Nullary `..` / `...` (no operand): `{:.., [], []}` / `{:..., [], []}`.
  defp lower_unary([op_leaf], view, _opts, acc, nid),
    do: {{op_atom(op_leaf, view), op_meta(op_leaf, view), []}, acc, nid}

  # A list literal lowers to the Elixir list of its lowered elements.
  defp lower_list(children, view, opts, acc, nid), do: lower_each(children, view, opts, acc, nid)

  # 2-tuples are literal `{a, b}`; all other arities use `{:{}, [], elems}`. Trailing keyword
  # pairs collapse into a single keyword-list element (`{1, a: 1}` => `{1, [a: 1]}`), like calls.
  defp lower_tuple(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_args(children, view, opts, acc, nid)

    case asts do
      [a, b] -> {{a, b}, acc, nid}
      _ -> {{:{}, [], asts}, acc, nid}
    end
  end

  # `f(args)` => `{fun_atom, meta, lowered_args}`. The callee name respects the atom policy.
  defp lower_call([callee | arg_children], view, opts, acc, nid) do
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    lower_callee(CST.tag(callee), callee, args, view, opts, acc, nid)
  end

  # A bare identifier callee is a named call `{name, meta, args}` (atom via the atom policy).
  defp lower_callee(:token, callee, args, view, opts, acc, nid) do
    idx = CST.token_index(callee)
    name = Tokens.value(view, idx)

    case to_atom(name, opts) do
      {:ok, fun} ->
        {{fun, tmeta(view, idx), args}, acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :nonexistent_atom,
            name_span(callee, view),
            %{
              name: name
            }
          )

        {{:__error__, tmeta(view, idx), %{diag_ids: [id]}}, acc, nid}
    end
  end

  # A node callee is the "double parens" call `f(a)(b)` => `{f(a), [], [b]}`: lower the callee
  # expression and wrap it.
  defp lower_callee(_tag, callee, args, view, opts, acc, nid) do
    {callee_ast, acc, nid} = lower(callee, view, opts, acc, nid)
    {{callee_ast, callee_anchor(callee_ast, opts), args}, acc, nid}
  end

  # A call whose callee is itself an expression (`a.unquote(b)(c)`, `(expr)(c)`) anchors where its
  # callee does — Elixir reuses the callee's `line:`/`column:`, not the whole call's span start.
  defp callee_anchor(_callee, %{token_metadata: false}), do: []

  defp callee_anchor({_f, meta, _a}, _opts) when is_list(meta),
    do: Keyword.take(meta, [:line, :column])

  defp callee_anchor(_callee, _opts), do: []

  # Alias chain: `{:__aliases__, meta, segments}`. A leading alias segment contributes its atom;
  # a leading non-alias base (e.g. `foo.Bar`) contributes its lowered AST as the first segment.
  # Alias segment atoms ARE gated by `existing_atoms_only` — the oracle rejects a fresh module name
  # too — so a segment that would mint a new atom yields an error node + `:nonexistent_atom`.
  defp lower_alias([first | rest], view, opts, acc, nid) do
    meta = error_meta(first, view)

    if CST.tag(first) == :token and Tokens.kind(view, CST.token_index(first)) == :alias do
      build_alias([first | rest], meta, view, opts, acc, nid)
    else
      {base_ast, acc, nid} = lower(first, view, opts, acc, nid)
      meta = alias_base_meta(first, meta, view, opts)
      {acc, nid} = maybe_atom_dot_alias(base_ast, rest, view, acc, nid)

      case seg_atoms(rest, view, opts) do
        {:ok, atoms} ->
          {{:__aliases__, with_alias_last(meta, List.last(rest), view, opts), [base_ast | atoms]},
           acc, nid}

        {:error, leaf} ->
          alias_seg_error(leaf, view, acc, nid)
      end
    end
  end

  # An alias with a NON-alias base (`__MODULE__.Any`, `unquote(x).Foo`) anchors at the base's span
  # end (the `.` before the first alias segment), not the base start — matching Elixir.
  defp alias_base_meta(_first, meta, _view, %{token_metadata: false}), do: meta

  defp alias_base_meta(first, meta, view, _opts) do
    case child_span(first, view) do
      {_sl, _sc, el, ec} -> [line: el, column: ec]
      _ -> meta
    end
  end

  defp build_alias(leaves, meta, view, opts, acc, nid) do
    case seg_atoms(leaves, view, opts) do
      {:ok, atoms} ->
        {{:__aliases__, with_alias_last(meta, List.last(leaves), view, opts), atoms}, acc, nid}

      {:error, leaf} ->
        alias_seg_error(leaf, view, acc, nid)
    end
  end

  # `last:` — the position of the alias's final segment (`Foo.Bar.Baz` → `Baz`; single `Foo` → `Foo`).
  defp with_alias_last(meta, _last_leaf, _view, %{token_metadata: false}), do: meta

  defp with_alias_last(meta, {:token, idx, _f, _d}, view, _opts) do
    {sl, sc, _el, _ec} = Tokens.span(view, idx)
    [{:last, [line: sl, column: sc]} | meta]
  end

  defp with_alias_last(meta, _last_leaf, _view, _opts), do: meta

  # Atomize every alias segment through the gated policy; the first that fails (a fresh atom under
  # `existing_atoms_only`, or invalid UTF-8) short-circuits to `{:error, that_leaf}`.
  defp seg_atoms(leaves, view, opts) do
    Enum.reduce_while(leaves, {:ok, []}, fn leaf, {:ok, atoms} ->
      case to_atom(Tokens.value(view, CST.token_index(leaf)), opts) do
        {:ok, atom} -> {:cont, {:ok, [atom | atoms]}}
        :error -> {:halt, {:error, leaf}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, :lists.reverse(rev)}
      err -> err
    end
  end

  defp alias_seg_error(leaf, view, acc, nid),
    do: nonexistent_atom(leaf, view, Tokens.value(view, CST.token_index(leaf)), acc, nid)

  # `:foo.Bar` / `nil.Bar` — a bare ATOM literal cannot be followed by an alias (Elixir rejects it;
  # to keep the atom in its name, it must be quoted). Non-atom bases (`__MODULE__.X`, `x.X`, `@x.X`)
  # are fine. Mirrors elixir_parser's `build_dot_alias` `is_atom(Atom)` guard. We keep the
  # `__aliases__` tree (tolerant) but record the error so strict mode rejects it.
  defp maybe_atom_dot_alias(base, [seg | _], view, acc, nid) when is_atom(base) do
    {_id, acc, nid} =
      Diagnostics.emit(acc, nid, :lowerer, :error, :atom_dot_alias, name_span(seg, view), %{})

    {acc, nid}
  end

  defp maybe_atom_dot_alias(_base, _rest, _view, acc, nid), do: {acc, nid}

  # `a.b` / `a.b(args)` => `{{:., m, [base, name]}, m, args}` (zero-arg form is just `args = []`).
  defp lower_remote_call([base, name_leaf | arg_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    dotmeta = remote_dot_meta(base, view, opts)
    remote_name(CST.tag(name_leaf), name_leaf, base_ast, args, dotmeta, view, opts, acc, nid)
  end

  # Under `token_metadata: true` the `.` operator anchors at the dot itself (between the base and the
  # member name), not at the name — matching Elixir. Off, the dot reuses the name meta (unchanged).
  defp remote_dot_meta(_base, _view, %{token_metadata: false}), do: nil

  defp remote_dot_meta(base, view, opts) do
    case child_span(base, view) do
      {_sl, _sc, bel, bec} ->
        case src_slice(opts, {bel, bec}, {bel, bec + 20}) do
          s when is_binary(s) ->
            case :binary.match(s, ".") do
              {off, _} -> [line: bel, column: bec + off]
              :nomatch -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp remote_name(:token, name_leaf, base_ast, args, dotmeta, view, opts, acc, nid) do
    idx = CST.token_index(name_leaf)
    meta = tmeta(view, idx)

    case member_atom(Tokens.kind(view, idx), Tokens.value(view, idx), opts) do
      {:ok, name} -> {{{:., dotmeta || meta, [base_ast, name]}, meta, args}, acc, nid}
      :error -> name_error(name_leaf, view, acc, nid)
    end
  end

  # A recovered missing name (`foo.` with nothing after) — its diagnostic was already emitted by
  # the parser; lower to an error node (P5: total, never raises).
  defp remote_name(:missing, name_leaf, _base_ast, _args, _dotmeta, view, _opts, acc, nid),
    do: name_error(name_leaf, view, acc, nid)

  # `a."foo"` — the function name is a quoted literal. No interpolation allowed (Elixir rejects
  # `a."f#{x}"`): atomize the concatenated fragments; on interpolation, error + best-effort.
  defp remote_name(:node, name_node, base_ast, args, dotmeta, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(CST.children(name_node), view, opts, acc, nid)

    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      {id, acc, nid} =
        Diagnostics.emit(
          acc,
          nid,
          :lowerer,
          :error,
          :interpolated_remote_name,
          atom_span(name_node, view),
          %{}
        )

      {{:__error__, [], %{diag_ids: [id]}}, acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()

      case to_atom(bin, opts) do
        {:ok, name} ->
          dm = dotmeta || []
          {{{:., dm, [base_ast, name]}, quoted_name_meta(name_node, view, opts), args}, acc, nid}

        :error ->
          name_error(name_node, view, acc, nid)
      end
    end
  end

  # A quoted remote-call member (`foo."bar"(x)`): the call meta anchors at the quoted name and
  # carries its opening `delimiter:` (the `closing:` for the `)` is added later by `closing_keys`).
  defp quoted_name_meta(name_node, view, opts) do
    case tm?(opts) && child_span(name_node, view) do
      {sl, sc, _el, _ec} = span ->
        Enum.concat(quoted_key_delimiter(span, opts), line: sl, column: sc)

      _ ->
        []
    end
  end

  # The atom for a remote-call member. Identifiers carry a binary name (atom policy applies);
  # reserved-word members (`a.true`, `a.when`, `a.do`) carry the atom in the token itself — the
  # value for word operators / `:literal` / block labels, or the kind for `do`/`end`/`fn`.
  defp member_atom(:identifier, value, opts), do: to_atom(value, opts)
  defp member_atom(:literal, value, _opts), do: {:ok, value}
  defp member_atom(kind, nil, _opts) when kind in [:do, :end, :fn], do: {:ok, kind}
  defp member_atom(_kind, value, _opts) when is_atom(value), do: {:ok, value}

  # `a.(args)` => `{{:., m, [base]}, m, args}`.
  defp lower_anon_call([base | arg_children], cst, view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)

    # `lower_call_args` (not `lower_args`) so a trailing do-block becomes `[do: …]` — `f.() do … end`.
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    {dotmeta, callmeta} = anon_call_metas(base, cst, error_meta(base, view), view, opts)
    {{{:., dotmeta, [base_ast]}, callmeta, args}, acc, nid}
  end

  # `f.(…)` — under `token_metadata: true` the dot anchors at the `.` (between base and `(`) and the
  # call meta carries `closing:` (the `)` = node-span end − 1). Off, both reuse the base meta.
  defp anon_call_metas(_base, _cst, base_meta, _view, %{token_metadata: false}),
    do: {base_meta, base_meta}

  defp anon_call_metas(base, cst, base_meta, view, opts) do
    dot = remote_dot_meta(base, view, opts) || base_meta

    closing =
      case CST.span(cst) do
        {_sl, _sc, el, ec} -> [closing: [line: el, column: ec - 1]]
        _ -> []
      end

    {dot, Enum.concat(closing, dot)}
  end

  defp name_error(name_leaf, view, acc, nid) do
    idx = CST.token_index(name_leaf)

    {id, acc, nid} =
      Diagnostics.emit(
        acc,
        nid,
        :lowerer,
        :error,
        :nonexistent_atom,
        name_span(name_leaf, view),
        %{
          name: Tokens.value(view, idx)
        }
      )

    {{:__error__, tmeta(view, idx), %{diag_ids: [id]}}, acc, nid}
  end

  # A keyword pair `k: v` => `{key_atom, lowered_value}`. (Keyword key atoms are not gated.)
  defp lower_kw_pair([key, val], view, opts, acc, nid) do
    {acc, nid} = maybe_nested_no_parens_warn(val, view, acc, nid)
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    kw_key(CST.tag(key), key, v, view, opts, acc, nid)
  end

  # `foo a: bar b` / `f(a: bar b)` — a keyword whose VALUE is a no-parens call is ambiguous (do the
  # following commas belong to the inner or outer call?); Elixir warns to add parentheses. The
  # CST still carries the `:no_parens` category here (the AST erases it).
  defp maybe_nested_no_parens_warn(val, view, acc, nid) do
    if no_parens_call_cst?(val) do
      {_id, acc, nid} =
        Diagnostics.emit(
          acc,
          nid,
          :parser,
          :warning,
          :nested_no_parens_keyword,
          child_span(val, view),
          %{}
        )

      {acc, nid}
    else
      {acc, nid}
    end
  end

  # Mirrors the parser's `no_parens_expr?`: a no-parens call with ≥2 POSITIONAL arg groups (`bar b,
  # c`), or whose single positional arg is itself such a call. A trailing run of keyword pairs is
  # ONE argument, so a kw-only call (`defstruct a: 1, b: 2`, the value of `do: …`) is NOT multi-arg
  # — and a plain single-arg call (`bar b`) is fine.
  defp no_parens_call_cst?(node) do
    kind = CST.tag(node) == :node and CST.node_kind(node)

    if kind in [:np_call, :remote_call] and CST.category(node) == :no_parens do
      args = np_call_args_cst(kind, CST.children(node))
      {kws, positional} = Enum.split_with(args, &kw_pair_cst?/1)
      groups = length(positional) + if kws == [], do: 0, else: 1

      cond do
        positional != [] and groups >= 2 -> true
        match?([_], positional) and kws == [] -> no_parens_call_cst?(hd(positional))
        true -> false
      end
    else
      false
    end
  end

  defp np_call_args_cst(:np_call, [_callee | args]), do: args
  defp np_call_args_cst(:remote_call, [_base, _name | args]), do: args
  defp np_call_args_cst(_kind, _children), do: []

  defp kw_pair_cst?(node), do: CST.tag(node) == :node and CST.node_kind(node) == :kw_pair

  defp kw_key(:token, key_leaf, v, view, opts, acc, nid) do
    idx = CST.token_index(key_leaf)

    case to_atom(Tokens.value(view, idx), opts) do
      :error ->
        {err, acc, nid} = nonexistent_atom(key_leaf, view, Tokens.value(view, idx), acc, nid)
        {{err, v}, acc, nid}

      {:ok, atom} ->
        case opts.literal_encoder do
          nil ->
            {{atom, v}, acc, nid}

          enc ->
            # A keyword key is a literal atom; Elixir tags its meta `format: :keyword` and the
            # encoded key turns the `k: v` shorthand into an explicit `{encoded_key, v}` pair.
            span = Tokens.span(view, idx)
            meta = [{:format, :keyword} | literal_meta(span, opts)]
            {key_ast, acc, nid} = run_encoder_meta(enc, atom, meta, span, acc, nid)
            {{key_ast, v}, acc, nid}
        end
    end
  end

  # A quoted kw key (`"foo": v`) atomizes like a quoted atom: no interpolation => the atom; with
  # interpolation => the `binary_to_atom` construction (so the pair is `{key_expr, v}`).
  defp kw_key(:node, key_node, v, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(CST.children(key_node), view, opts, acc, nid)
    {key_ast, acc, nid} = build_quoted_atom(parts, key_node, key_node, true, view, opts, acc, nid)
    {key_ast, acc, nid} = encode_quoted_kw_key(key_ast, key_node, opts, acc, nid)
    {{key_ast, v}, acc, nid}
  end

  # A static quoted kw key (`"foo": v`) lowers to a bare atom — encode it like a plain kw key. An
  # interpolated key (`"#{x}": v`) is a `binary_to_atom` construction (not an atom), left as-is.
  defp encode_quoted_kw_key(atom, key_node, opts, acc, nid) when is_atom(atom) do
    case opts.literal_encoder do
      nil ->
        {atom, acc, nid}

      enc ->
        span = CST.span(key_node)
        meta = [{:format, :keyword} | literal_meta(span, opts)]

        run_encoder_meta(
          enc,
          atom,
          Enum.concat(quoted_key_delimiter(span, opts), meta),
          span,
          acc,
          nid
        )
    end
  end

  defp encode_quoted_kw_key(other, _key_node, _opts, acc, nid), do: {other, acc, nid}

  # A quoted keyword key (`"foo": v`) carries the opening `delimiter:` under token_metadata, read at
  # the key's span start (the `"` / `'`), before `format: :keyword`.
  defp quoted_key_delimiter({sl, sc, _el, _ec}, %{token_metadata: true} = opts) do
    case src_slice(opts, {sl, sc}, {sl, sc + 4}) do
      h when is_binary(h) -> if d = delim_at(h), do: [delimiter: d], else: []
      _ -> []
    end
  end

  defp quoted_key_delimiter(_span, _opts), do: []

  # Call arguments: a trailing run of keyword pairs is collected into one keyword-list arg
  # (`f(1, a: 2)` => `[1, [a: 2]]`); regular args lower normally.
  defp lower_args(children, view, opts, acc, nid) do
    {kw_rev, regular_rev} = Enum.split_while(:lists.reverse(children), &kw_pair?/1)
    {reg, acc, nid} = lower_each(:lists.reverse(regular_rev), view, opts, acc, nid)

    case :lists.reverse(kw_rev) do
      [] ->
        {reg, acc, nid}

      kw ->
        {kw_list, acc, nid} = lower_each(kw, view, opts, acc, nid)
        {Enum.concat(reg, [kw_list]), acc, nid}
    end
  end

  defp kw_pair?(cst), do: CST.tag(cst) == :node and CST.node_kind(cst) == :kw_pair

  # Call args, where a trailing `:do_block` child becomes the final `[do: ..., else: ...]` arg.
  defp lower_call_args(children, view, opts, acc, nid) do
    {plain, do_block} = pop_do_block(children)
    {args, acc, nid} = lower_args(plain, view, opts, acc, nid)

    case do_block do
      nil ->
        {args, acc, nid}

      db ->
        {kw, acc, nid} = lower_do_block(db, view, opts, acc, nid)
        {Enum.concat(args, [kw]), acc, nid}
    end
  end

  defp pop_do_block(children) do
    case :lists.reverse(children) do
      [{:node, :do_block, _sp, _ch, _f, _d} = db | rev] -> {:lists.reverse(rev), db}
      _ -> {children, nil}
    end
  end

  # `do ... else ... end` => keyword list `[do: body, else: body, ...]`. A trailing `:missing`
  # (recovered missing `end`) is skipped — its diagnostic was already emitted by the parser.
  defp lower_do_block(db, view, opts, acc, nid) do
    {pairs, acc, nid} =
      Enum.reduce(CST.children(db), {[], acc, nid}, fn
        {:node, :do_section, _sp, _ch, _f, _d} = section, {ps, a, n} ->
          {pair, a, n} = lower_section(section, view, opts, a, n)
          {[pair | ps], a, n}

        _other, accum ->
          accum
      end)

    {:lists.reverse(pairs), acc, nid}
  end

  defp lower_section({:node, :do_section, _sp, [label_leaf, body], _f, _d}, view, opts, acc, nid) do
    {b, acc, nid} =
      lower_section_body(body, section_block_meta(label_leaf, view, opts), view, opts, acc, nid)

    {key, acc, nid} = section_label(label_leaf, view, opts, acc, nid)
    {{key, b}, acc, nid}
  end

  # Since Elixir 1.20 the `do` section's body block is anchored at the `do` token
  # (`build_stab(.., meta_from_token(do))`): a multi-statement / empty body's `__block__` carries
  # `[line, column]` of `do`, and a single-expression body carries `parens: [line, column]`. Other
  # sections (`else`/`catch`/…) pass `[]`. Token-metadata only; non-tm meta is normalized away.
  defp section_block_meta(label_leaf, view, opts) do
    idx = CST.token_index(label_leaf)

    if tm?(opts) and Tokens.kind(view, idx) == :do do
      {l, c, _, _} = Tokens.span(view, idx)
      [line: l, column: c]
    else
      []
    end
  end

  # The `do:`/`else:`/`rescue:`/… key of a do-block. It is a literal atom too, so under a literal
  # encoder it gets encoded (plain `line:`/`column:` meta — Elixir does NOT tag these `:keyword`).
  defp section_label(label_leaf, view, opts, acc, nid) do
    idx = CST.token_index(label_leaf)
    atom = if Tokens.kind(view, idx) == :do, do: :do, else: Tokens.value(view, idx)

    case opts.literal_encoder do
      nil ->
        {atom, acc, nid}

      enc ->
        span = Tokens.span(view, idx)
        run_encoder_meta(enc, atom, literal_meta(span, opts), span, acc, nid)
    end
  end

  # A `:do_body` lowers like a block (nil / expr / __block__); `:do_clauses` lowers to a list of
  # `{:->, ...}` clauses. `block_meta` is the `do`-token anchor (see `section_block_meta/3`).
  defp lower_section_body(
         {:node, :do_clauses, _sp, clauses, _f, _d},
         _block_meta,
         view,
         opts,
         acc,
         nid
       ),
       do: lower_each(clauses, view, opts, acc, nid)

  defp lower_section_body({:node, :do_body, _sp, stmts, _f, _d}, block_meta, view, opts, acc, nid) do
    case stmts do
      # An empty section body is `{:__block__, block_meta, []}` (`foo do end`), NOT nil — Elixir
      # distinguishes an empty block from a missing one.
      [] ->
        {{:__block__, block_meta, []}, acc, nid}

      [one] ->
        {ast, acc, nid} = lower(one, view, opts, acc, nid)
        {section_parens(wrap_splice(attach_eoe(ast, one, view, opts)), block_meta), acc, nid}

      many ->
        {{:__block__, _m, asts}, acc, nid} = wrap_block(lower_stmts(many, view, opts, acc, nid))
        {{:__block__, block_meta, asts}, acc, nid}
    end
  end

  # A single-expression `do` body carries `parens: <do-token meta>` (Elixir 1.20). Only an expr that
  # already has a metadata list (a `{op, meta, args}` 3-tuple) takes it — a bare literal does not.
  defp section_parens(ast, []), do: ast

  defp section_parens({op, meta, args}, block_meta) when is_list(meta),
    do: {op, [{:parens, block_meta} | meta], args}

  defp section_parens(ast, _block_meta), do: ast

  # `<<...>>` => `{:<<>>, [], elems}` (segments incl. `::` are ordinary expressions).
  # Trailing keyword pairs collapse into one keyword-list element (`<<a, k: 1>>` => `[a, [k: 1]]`).
  defp lower_bitstring(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_args(children, view, opts, acc, nid)
    {{:<<>>, [], asts}, acc, nid}
  end

  # `a[b]` => `{{:., m, [Access, :get]}, m, [base, index]}`.
  defp lower_access([base, idx | _missing], cst, view, opts, acc, nid) do
    {b, acc, nid} = lower(base, view, opts, acc, nid)
    {k, acc, nid} = lower(idx, view, opts, acc, nid)
    dm = access_dot_meta(base, cst, view, opts)
    {{{:., dm, [Access, :get]}, dm, [b, k]}, acc, nid}
  end

  # The span of a CST child, whether a node (`CST.span/1`) or a bare token leaf (via the view).
  defp child_span({:token, idx, _f, _d}, view), do: Tokens.span(view, idx)
  defp child_span(child, _view), do: CST.span(child)

  # `foo[bar]` => `{{:., dotmeta, [Access, :get]}, [], [foo, bar]}`. Under `token_metadata: true` the
  # dot meta carries `from_brackets: true` + `closing:` (the `]` = node-span end − 1) and anchors at
  # the opening `[` (= the base's span end).
  defp access_dot_meta(_base, _cst, _view, %{token_metadata: false}), do: []

  defp access_dot_meta(base, cst, view, _opts) do
    with {_, _, bel, bec} <- child_span(base, view),
         {_, _, el, ec} <- CST.span(cst) do
      [from_brackets: true, closing: [line: el, column: ec - 1], line: bel, column: bec]
    else
      _ -> []
    end
  end

  # `%{...}` => `{:%{}, [], entries}`; entries lower to `{key, value}` 2-tuples.
  defp lower_map(children, view, opts, acc, nid) do
    {entries, acc, nid} = lower_each(children, view, opts, acc, nid)
    {{:%{}, [], entries}, acc, nid}
  end

  # `%{base | ...}` => `{:%{}, [], [{:|, [], [base, update_entries]}]}`.
  defp lower_map_update([base | entry_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {entries, acc, nid} = lower_each(entry_children, view, opts, acc, nid)
    {{:%{}, [], [{:|, cons_meta(base, view, opts), [base_ast, entries]}]}, acc, nid}
  end

  # The `|` of a map update (`%{m | …}`) anchors at the bar, found just past the base in the source.
  defp cons_meta(base, view, opts) do
    if tm?(opts) do
      with {_sl, _sc, el, ec} <- child_span(base, view),
           [line: bl, column: bc] = pos <- scan_op(opts, el, ec, "|", el + 3) do
        after_n = gap_newlines(opts, bl, bc + 1)
        n = if after_n > 0, do: after_n, else: gap_newlines(opts, el, ec)
        if n > 0, do: [{:newlines, n} | pos], else: pos
      else
        _ -> []
      end
    else
      []
    end
  end

  # `%Name{...}` => `{:%, [], [name, map]}`.
  defp lower_struct([name, map_node], view, opts, acc, nid) do
    {name_ast, acc, nid} = lower(name, view, opts, acc, nid)
    {map_ast, acc, nid} = lower(map_node, view, opts, acc, nid)
    {{:%, [], [name_ast, map_ast]}, acc, nid}
  end

  # Stab clause head -> the arg list. A `when` guard wraps the patterns: `[{:when, [], [pats, g]}]`.
  # A trailing keyword run in the patterns is grouped into one keyword-list arg (`fn x, a: 1 -> …`
  # => `[x, [a: 1]]`), matching call/list args; the guard (always last) stays a separate element.
  # A clause-head `when` guard anchors at the `when` keyword (between the last pattern and the guard).
  defp when_meta(pats, guard, view, opts) do
    with true <- tm?(opts),
         {_, _, pel, pec} <- pats |> List.last() |> then(&(&1 && child_span(&1, view))),
         {gsl, _, _, _} <- child_span(guard, view) do
      case scan_op(opts, pel, pec, "when", gsl) do
        [line: wl, column: wc] = w ->
          after_n = gap_newlines(opts, wl, wc + 4)
          n = if after_n > 0, do: after_n, else: gap_newlines(opts, pel, pec)
          if n > 0, do: [{:newlines, n} | w], else: w

        w ->
          w
      end
    else
      _ -> []
    end
  end

  defp lower_stab_args(args_node, view, opts, acc, nid) do
    case CST.children(args_node) do
      [{:node, :stab_when, _sp, when_ch, _f, _d}] ->
        {pats, [guard]} = Enum.split(when_ch, length(when_ch) - 1)

        # `fn () when g -> …`: an empty parenthesised head is ZERO patterns, so `when` wraps just
        # the guard (`{:when, [], [g]}`), mirroring the bare `fn () -> …` => `[]` case below.
        {pat_asts, acc, nid} = lower_args(strip_empty_paren_head(pats), view, opts, acc, nid)
        {guard_ast, acc, nid} = lower(guard, view, opts, acc, nid)

        {[{:when, when_meta(pats, guard, view, opts), Enum.concat(pat_asts, [guard_ast])}], acc,
         nid}

      # `fn () -> ... end`: an empty parenthesised head is ZERO args (`[]`), not one block arg.
      [{:node, :paren, _sp, [], _f, _d}] ->
        {[], acc, nid}

      children ->
        lower_args(children, view, opts, acc, nid)
    end
  end

  # Stab clause body -> nil (empty), the expression (one), or a `__block__` (many).
  defp lower_stab_body(body_node, view, opts, acc, nid) do
    case CST.children(body_node) do
      [] ->
        {nil, acc, nid}

      [one] ->
        {ast, acc, nid} = lower(one, view, opts, acc, nid)
        {wrap_splice(attach_eoe(ast, one, view, opts)), acc, nid}

      many ->
        wrap_block(lower_stmts(many, view, opts, acc, nid))
    end
  end

  defp wrap_block({asts, acc, nid}), do: {{:__block__, [], asts}, acc, nid}

  # `unquote_splicing(x)` as the SOLE statement of a block / paren / clause body is wrapped in a
  # `__block__` (it is only valid in a list/block context) — `(unquote_splicing(x))` => `{:__block__,
  # [], [it]}`. As a list element (`[unquote_splicing(x)]`) it is NOT wrapped (a different path).
  defp wrap_splice({:unquote_splicing, _, _} = ast), do: {:__block__, [], [ast]}
  defp wrap_splice(ast), do: ast

  # `a not in b` => `{:not, [], [{:in, [], [a, b]}]}` (the canonical Elixir shape; the rewrite
  # lives here, not in the parser — P5).
  defp lower_not_in([lhs, rhs], view, opts, acc, nid) do
    {l, acc, nid} = lower(lhs, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)
    {not_m, in_m} = not_in_meta(lhs, view, opts)
    {{:not, not_m, [{:in, in_m, [l, r]}]}, acc, nid}
  end

  # `x not in y`: `not` and `in` are separate keywords after the lhs (`x not in …`); anchor each at
  # its keyword position, found by scanning the source just past the lhs.
  defp not_in_meta(_lhs, _view, %{token_metadata: false}), do: {[], []}

  defp not_in_meta(lhs, view, opts) do
    with {_, _, lel, lec} <- child_span(lhs, view),
         [line: nl, column: nc] = not_m <- scan_op(opts, lel, lec, "not", lel + 1) do
      {not_m, scan_op(opts, nl, nc + 3, "in", nl + 1)}
    else
      _ -> {[], []}
    end
  end

  # `key => value` map entry => `{key, value}` 2-tuple.
  defp lower_assoc([key, val], view, opts, acc, nid) do
    {k, acc, nid} = lower(key, view, opts, acc, nid)
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    {{put_assoc(k, key, view, opts), v}, acc, nid}
  end

  # `assoc:` — for a `key => value` pair, the key's meta records the `=>` operator position (found in
  # the source just past the key). Only carried under `token_metadata: true`, and only when the key
  # lowered to a node with a metadata slot (a bare un-encoded literal has nowhere to put it).
  defp put_assoc(k, _key, _view, %{token_metadata: false}), do: k

  defp put_assoc({f, meta, a}, key, view, opts) do
    case assoc_pos(key, view, opts) do
      nil -> {f, meta, a}
      pos -> {f, [{:assoc, pos} | meta], a}
    end
  end

  defp put_assoc(k, _key, _view, _opts), do: k

  defp assoc_pos(key, view, opts) do
    with {_sl, _sc, kel, kec} <- child_span(key, view),
         head when is_binary(head) <- src_slice(opts, {kel, kec}, {kel, kec + 40}),
         {off, _} <- :binary.match(head, "=>") do
      [line: kel, column: kec + off]
    else
      _ -> nil
    end
  end

  # Thread the accumulator while lowering a list of children. Direct recursion rather than an
  # Enum.reduce closure (no per-element apply / closure frame) — this is the central child-list
  # walker, called from lists, tuples, maps, clauses, args, blocks, …
  defp lower_each(children, view, opts, acc, nid),
    do: lower_each(children, view, opts, acc, nid, [])

  defp lower_each([child | rest], view, opts, acc, nid, asts) do
    {ast, acc, nid} = lower(child, view, opts, acc, nid)
    lower_each(rest, view, opts, acc, nid, [ast | asts])
  end

  defp lower_each([], _view, _opts, acc, nid, asts), do: {:lists.reverse(asts), acc, nid}

  # --- error nodes (invalid CST; never raises) ---------------------------

  defp error_ast(cst, view),
    do: {:__error__, error_meta(cst, view), %{diag_ids: CST.diag_ids(cst)}}

  defp error_meta(cst, view) do
    case CST.tag(cst) do
      :node -> span_meta(CST.span(cst))
      :token -> tmeta(view, CST.token_index(cst))
      :missing -> tmeta(view, CST.anchor_index(cst))
    end
  end

  # --- helpers -----------------------------------------------------------

  defp op_atom(op_leaf, view), do: Tokens.value(view, CST.token_index(op_leaf))
  defp op_meta(op_leaf, view), do: tmeta(view, CST.token_index(op_leaf))

  defp name_span(cst, view), do: Tokens.span(view, CST.token_index(cst)) || {1, 1, 1, 1}

  # Read the start line/col straight off the token tuple. Going through `Tokens.span/2` allocated a
  # throwaway `{sl,sc,el,ec}` per node just to drop `el,ec` — tprof flagged it as ~quarter of all
  # `Token.span` calls in lowering.
  defp tmeta(view, idx) do
    case Tokens.token(view, idx) do
      {_kind, sl, sc, _el, _ec, _v} -> [line: sl, column: sc]
      :eof -> []
    end
  end

  defp span_meta({sl, sc, _el, _ec}), do: [line: sl, column: sc]
  defp span_meta(_), do: []

  defp to_atom(bin, opts) do
    if opts.existing_atoms_only do
      {:ok, String.to_existing_atom(bin)}
    else
      {:ok, String.to_atom(bin)}
    end
  rescue
    ArgumentError -> :error
  end

  # Totality helper (P5): `String.to_charlist` RAISES on invalid UTF-8, but a tolerant lexer/parser
  # may carry truncated bytes (`'<bad utf8>'`). Charlists don't touch the atom table, so a
  # non-raising best-effort (raw byte list) is fine; atom names instead route through the gated
  # `to_atom/2` (which returns `:error` rather than minting on bad input).
  defp safe_to_charlist(bin) when is_binary(bin) do
    if String.valid?(bin), do: String.to_charlist(bin), else: :erlang.binary_to_list(bin)
  end
end
