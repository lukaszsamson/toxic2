defmodule Toxic2.Parser do
  @moduledoc """
  Parser core (see `TOXIC_2.md` → Parser; Migration Phases #5–#7).

  Covers a top-level **expression list** of literals, identifiers/aliases, atoms, prefix/infix
  **operators**, parentheses, **lists `[...]`** (incl. keyword pairs), **tuples `{...}`**, **paren
  calls `f(...)`**, **dot/remote/anon calls** (`a.b`, `Foo.bar(...)`, `a.(...)`), **alias chains**
  (`Foo.Bar`), **maps/structs** (`%{...}`, `%Name{...}`, incl. `|` update), **bitstrings**
  (`<<...>>`), and **access** (`a[b]`). It builds a **green CST only** (`Toxic2.CST`) — never the
  Elixir AST, and no AST quirks (those belong to lowering, phase 6).

  Design (per the spec):

  - **Pratt for operators only** (P8). Precedences come from `Toxic2.Precedence` (pinned to
    `elixir_parser.yrl`). Left-assoc parses its RHS at `prec + 1`, right-assoc at `prec`.
  - **Cursor = integer index** over `Toxic2.Tokens` (P6). All state — `i`, the diagnostics
    accumulator, `next_id`, and a `fuel` backstop — is threaded as plain scalars/lists (P7).
    Returns are the fixed tuple `{cst, i, diags, next_id, fuel}`.
  - **Tolerant-only** (P1): every path produces a node. An unexpected token becomes an error
    leaf (consumed for forward progress) or a `:missing` node, plus one diagnostic — never a
    raise, never a second diagnostic for the same lexer `:error` token (sole transport, P3).
  - **No speculation yet**: phase 5 is single-pass; a checkpoint would be just a saved `i`.

  Newlines: a newline is allowed *after* a binary operator (RHS may be on the next line), but is
  **not** skipped when looking for the next infix operator — a newline there ends the expression
  (matching Elixir). EOE (`:eol` / `:";"`) separates top-level expressions.

  Not yet handled (later phases): no-parens calls, stabs/blocks, strings/sigils, `&` capture,
  multi-statement parens. Encountering those yields error/leaf nodes rather than crashing.
  """

  alias Toxic2.{CST, Diagnostics, LexError, Precedence, Tokens}

  @fuel_base 1_000

  @atomic_kinds [:int, :flt, :char, :atom, :literal, :identifier]

  # A map key / update base is parsed stopping before `|` (pipe_op 70) so the update separator
  # isn't swallowed as a binary operator.
  @map_key_bp 71

  # A struct name is a primary (alias chain / var); parse it above all operator precedences so
  # only nud + dot postfixes apply, never a trailing binary op or the `{`.
  @struct_name_bp 1_000

  @type result :: {CST.t(), [Toxic2.Diagnostic.t()]}

  @doc """
  Tokenize `source` and parse it. Returns `{cst, diagnostics}` where `diagnostics` is the single
  combined stream (lexer warnings + parser diagnostics), ordered by source position. The lowerer
  contributes its diagnostics in phase 6.
  """
  @spec parse(binary(), keyword()) :: result()
  def parse(source, opts \\ []) when is_binary(source) do
    {view, lexer_warnings} = Tokens.from_source(source, opts)
    {cst, parser_diags} = parse_tokens(view)
    {cst, Diagnostics.merge_sorted([lexer_warnings, parser_diags])}
  end

  @doc "Parse a prepared `Toxic2.Tokens` view into `{cst, diagnostics}`."
  @spec parse_tokens(Tokens.t()) :: result()
  def parse_tokens(view) do
    {diags, nid} = Diagnostics.new()
    fuel = Tokens.size(view) * 4 + @fuel_base
    {cst, _i, diags, _nid, _fuel} = parse_expr_list(view, 0, diags, nid, fuel)
    {cst, Diagnostics.to_list(diags)}
  end

  # --- expression list (top level) ---------------------------------------

  defp parse_expr_list(t, i, diags, nid, fuel) do
    i = skip_eoe(t, i)
    {exprs, i, diags, nid, fuel} = collect(t, i, [], diags, nid, fuel)
    {CST.node(:expr_list, list_span(t, exprs), exprs, nil, nil), i, diags, nid, fuel}
  end

  defp collect(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      Tokens.at_eof?(t, i) -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> collect_one(t, i, acc, diags, nid, fuel)
    end
  end

  defp collect_one(t, i, acc, diags, nid, fuel) do
    {expr, i2, diags, nid, fuel} = parse_expr(t, i, 0, :matched, diags, nid, fuel - 1)
    # Forward-progress guard: parse_expr always advances on real input, but never loop.
    i2 = if i2 > i, do: i2, else: i + 1
    collect(t, skip_eoe(t, i2), [expr | acc], diags, nid, fuel)
  end

  # --- Pratt ------------------------------------------------------------

  defp parse_expr(t, i, min_bp, ctx, diags, nid, fuel) do
    {lhs, i, diags, nid, fuel} = parse_prefix(t, i, ctx, diags, nid, fuel)
    {lhs, i, diags, nid, fuel} = postfix(t, i, lhs, ctx, diags, nid, fuel)
    led(t, i, lhs, min_bp, ctx, diags, nid, fuel)
  end

  # Postfix operations bind tightest (yecc 310): a paren call `f(...)` (adjacent `(`), and dot
  # forms `a.b` / `a.b(...)` / `a.(...)` / `Foo.Bar` (alias chain).
  defp postfix(t, i, lhs, ctx, diags, nid, fuel) do
    cond do
      paren_call?(t, lhs, i) ->
        {args, j, diags, nid, fuel} = parse_seq(t, i + 1, :")", diags, nid, fuel)

        call =
          CST.node(
            :call,
            merge(cst_span(t, lhs), tok_span(t, j - 1)),
            [lhs | args],
            :matched,
            nil
          )

        postfix(t, j, call, ctx, diags, nid, fuel)

      Tokens.kind(t, i) == :dot ->
        dot(t, i, lhs, ctx, diags, nid, fuel)

      access?(t, lhs, i) ->
        access(t, i, lhs, ctx, diags, nid, fuel)

      true ->
        {lhs, i, diags, nid, fuel}
    end
  end

  # `a[b]` access when `[` is adjacent to the primary (spaced `a [b]` is a no-parens call, phase 8).
  defp access?(t, lhs, i) do
    Tokens.kind(t, i) == :"[" and adjacent_after?(cst_span(t, lhs), Tokens.span(t, i))
  end

  defp adjacent_after?({_, _, el, ec}, {sl, sc, _, _}), do: el == sl and ec == sc
  defp adjacent_after?(_, _), do: false

  defp access(t, open, lhs, ctx, diags, nid, fuel) do
    {idx, j, diags, nid, fuel} = parse_expr(t, open + 1, 0, :matched, diags, nid, fuel - 1)
    jj = skip_eols(t, j)

    if Tokens.kind(t, jj) == :"]" do
      node =
        CST.node(:access, merge(cst_span(t, lhs), tok_span(t, jj)), [lhs, idx], :matched, nil)

      postfix(t, jj + 1, node, ctx, diags, nid, fuel)
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_rbracket, tok_span(t, jj), %{})

      node =
        CST.node(
          :access,
          merge(cst_span(t, lhs), tok_span(t, jj)),
          [lhs, idx, CST.missing(:"]", jj, diag: id)],
          :matched,
          nil
        )

      {node, jj, diags, nid, fuel}
    end
  end

  defp paren_call?(t, lhs, i) do
    CST.tag(lhs) == :token and Tokens.kind(t, CST.token_index(lhs)) == :identifier and
      Tokens.kind(t, i) == :"(" and Tokens.adjacent?(t, CST.token_index(lhs), i)
  end

  # `.` after a primary: alias-chain extension (`.Alias`), remote call (`.name` / `.name(...)`),
  # or anonymous call (`.(...)`). A newline is allowed after the dot.
  defp dot(t, dot_i, lhs, ctx, diags, nid, fuel) do
    j = skip_eols(t, dot_i + 1)

    case Tokens.kind(t, j) do
      :alias ->
        segs = if alias_node?(lhs), do: CST.children(lhs), else: [lhs]

        node =
          CST.node(
            :alias,
            merge(cst_span(t, lhs), tok_span(t, j)),
            Enum.concat(segs, [CST.token(j)]),
            :matched,
            nil
          )

        postfix(t, j + 1, node, ctx, diags, nid, fuel)

      :identifier ->
        remote_call(t, j, lhs, ctx, diags, nid, fuel)

      :"(" ->
        {args, k, diags, nid, fuel} = parse_seq(t, j + 1, :")", diags, nid, fuel)

        node =
          CST.node(
            :anon_call,
            merge(cst_span(t, lhs), tok_span(t, k - 1)),
            [lhs | args],
            :matched,
            nil
          )

        postfix(t, k, node, ctx, diags, nid, fuel)

      _ ->
        {id, diags, nid} =
          Diagnostics.emit(
            diags,
            nid,
            :parser,
            :error,
            :unexpected_after_dot,
            tok_span(t, j),
            %{}
          )

        node =
          CST.node(
            :remote_call,
            merge(cst_span(t, lhs), tok_span(t, dot_i)),
            [lhs, CST.missing(:identifier, j, diag: id)],
            :matched,
            nil
          )

        {node, j, diags, nid, fuel}
    end
  end

  defp remote_call(t, name_i, lhs, ctx, diags, nid, fuel) do
    name = CST.token(name_i)

    if Tokens.kind(t, name_i + 1) == :"(" and Tokens.adjacent?(t, name_i, name_i + 1) do
      {args, k, diags, nid, fuel} = parse_seq(t, name_i + 2, :")", diags, nid, fuel)

      node =
        CST.node(
          :remote_call,
          merge(cst_span(t, lhs), tok_span(t, k - 1)),
          [lhs, name | args],
          :matched,
          nil
        )

      postfix(t, k, node, ctx, diags, nid, fuel)
    else
      node =
        CST.node(
          :remote_call,
          merge(cst_span(t, lhs), tok_span(t, name_i)),
          [lhs, name],
          :matched,
          nil
        )

      postfix(t, name_i + 1, node, ctx, diags, nid, fuel)
    end
  end

  defp alias_node?(cst), do: CST.tag(cst) == :node and CST.node_kind(cst) == :alias

  defp led(_t, i, lhs, _min_bp, _ctx, diags, nid, fuel) when fuel <= 0,
    do: {lhs, i, diags, nid, fuel}

  defp led(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    case Precedence.infix(Tokens.kind(t, i)) do
      {prec, assoc} when prec >= min_bp ->
        op_leaf = CST.token(i)
        next_min = if assoc == :left, do: prec + 1, else: prec
        rhs_start = skip_eols(t, i + 1)
        {rhs, k, diags, nid, fuel} = parse_expr(t, rhs_start, next_min, ctx, diags, nid, fuel - 1)

        node =
          CST.node(
            :binary_op,
            merge(cst_span(t, lhs), cst_span(t, rhs)),
            [lhs, op_leaf, rhs],
            :matched,
            nil
          )

        led(t, k, node, min_bp, ctx, diags, nid, fuel)

      _ ->
        {lhs, i, diags, nid, fuel}
    end
  end

  defp parse_prefix(t, i, ctx, diags, nid, fuel) do
    kind = Tokens.kind(t, i)
    prefix_bp = Precedence.prefix(kind)

    cond do
      kind in @atomic_kinds ->
        {CST.token(i), i + 1, diags, nid, fuel}

      # An alias is a 1-segment alias node; `.Alias` postfixes extend its segments.
      kind == :alias ->
        {CST.node(:alias, tok_span(t, i), [CST.token(i)], :matched, nil), i + 1, diags, nid, fuel}

      kind == :error ->
        {id, diags, nid} = emit_lex_error(t, i, diags, nid)
        {CST.token(i, error: true, diag: id), i + 1, diags, nid, fuel}

      prefix_bp != nil ->
        parse_unary(t, i, prefix_bp, ctx, diags, nid, fuel)

      kind == :"(" ->
        parse_paren(t, i, ctx, diags, nid, fuel)

      kind == :"[" ->
        parse_container(t, i, :"]", :list, diags, nid, fuel)

      kind == :"{" ->
        parse_container(t, i, :"}", :tuple, diags, nid, fuel)

      kind == :"<<" ->
        parse_container(t, i, :">>", :bitstring, diags, nid, fuel)

      kind == :percent ->
        parse_percent(t, i, diags, nid, fuel)

      true ->
        parse_unexpected(t, i, diags, nid, fuel)
    end
  end

  # `%{...}` map or `%Name{...}` struct.
  defp parse_percent(t, i, diags, nid, fuel) do
    j = i + 1

    cond do
      Tokens.kind(t, j) == :"{" ->
        parse_map_body(t, j, i, diags, nid, fuel)

      Tokens.kind(t, j) in [:alias, :identifier] ->
        parse_struct(t, i, diags, nid, fuel)

      true ->
        {id, diags, nid} =
          Diagnostics.emit(
            diags,
            nid,
            :parser,
            :error,
            :expected_map_or_struct,
            tok_span(t, j),
            %{}
          )

        {CST.token(i, error: true, diag: id), i + 1, diags, nid, fuel}
    end
  end

  defp parse_struct(t, pct, diags, nid, fuel) do
    {name, j, diags, nid, fuel} =
      parse_expr(t, pct + 1, @struct_name_bp, :matched, diags, nid, fuel - 1)

    if Tokens.kind(t, j) == :"{" do
      {map, k, diags, nid, fuel} = parse_map_body(t, j, j, diags, nid, fuel)

      {CST.node(:struct, merge(tok_span(t, pct), cst_span(t, map)), [name, map], :matched, nil),
       k, diags, nid, fuel}
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_struct_body, tok_span(t, j), %{})

      {CST.node(
         :struct,
         merge(tok_span(t, pct), cst_span(t, name)),
         [name, CST.missing(:"{", j, diag: id)],
         :matched,
         nil
       ), j, diags, nid, fuel}
    end
  end

  # Map body after `{`. Detects `%{base | ...}` update; otherwise a comma-separated list of
  # `key => value` assoc entries and `key: value` keyword pairs.
  defp parse_map_body(t, brace, span_start, diags, nid, fuel) do
    i = skip_eols(t, brace + 1)

    cond do
      Tokens.kind(t, i) == :"}" ->
        {CST.node(:map, merge(tok_span(t, span_start), tok_span(t, i)), [], :matched, nil), i + 1,
         diags, nid, fuel}

      Tokens.kind(t, i) == :kw_identifier ->
        {entries, j, diags, nid, fuel} = map_entries(t, i, [], diags, nid, fuel)

        {CST.node(
           :map,
           merge(tok_span(t, span_start), tok_span(t, j - 1)),
           entries,
           :matched,
           nil
         ), j, diags, nid, fuel}

      true ->
        map_lead(t, i, span_start, diags, nid, fuel)
    end
  end

  # First non-keyword segment: an update base (`base | ...`) or the first `=>` assoc entry.
  defp map_lead(t, i, span_start, diags, nid, fuel) do
    {key, j, diags, nid, fuel} = parse_expr(t, i, @map_key_bp, :matched, diags, nid, fuel - 1)
    jj = skip_eols(t, j)

    cond do
      Tokens.kind(t, jj) == :pipe_op ->
        {entries, k, diags, nid, fuel} =
          map_entries(t, skip_eols(t, jj + 1), [], diags, nid, fuel)

        {CST.node(
           :map_update,
           merge(tok_span(t, span_start), tok_span(t, k - 1)),
           [key | entries],
           :matched,
           nil
         ), k, diags, nid, fuel}

      Tokens.kind(t, jj) == :assoc_op ->
        {val, k, diags, nid, fuel} =
          parse_expr(t, skip_eols(t, jj + 1), 0, :matched, diags, nid, fuel - 1)

        first =
          CST.node(:assoc, merge(cst_span(t, key), cst_span(t, val)), [key, val], :matched, nil)

        {entries, m, diags, nid, fuel} = map_rest(t, k, [first], diags, nid, fuel)

        {CST.node(
           :map,
           merge(tok_span(t, span_start), tok_span(t, m - 1)),
           entries,
           :matched,
           nil
         ), m, diags, nid, fuel}

      true ->
        {id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :expected_assoc, tok_span(t, jj), %{})

        {CST.node(
           :map,
           merge(tok_span(t, span_start), tok_span(t, jj)),
           [key, CST.missing(:"=>", jj, diag: id)],
           :matched,
           nil
         ), jj, diags, nid, fuel}
    end
  end

  # After the first assoc entry: continue at `,` or finish at `}`.
  defp map_rest(t, i, acc, diags, nid, fuel) do
    i2 = skip_eols(t, i)

    cond do
      Tokens.kind(t, i2) == :"}" -> {:lists.reverse(acc), i2 + 1, diags, nid, fuel}
      Tokens.kind(t, i2) == :"," -> map_entries(t, skip_eols(t, i2 + 1), acc, diags, nid, fuel)
      true -> map_unterminated(t, i2, acc, diags, nid, fuel)
    end
  end

  # Comma-separated map entries (assoc or keyword pair) until `}`.
  defp map_entries(t, i, acc, diags, nid, fuel) do
    i = skip_eols(t, i)

    if Tokens.kind(t, i) == :"}" do
      {:lists.reverse(acc), i + 1, diags, nid, fuel}
    else
      {entry, j, diags, nid, fuel} = parse_map_entry(t, i, diags, nid, fuel)
      map_rest(t, j, [entry | acc], diags, nid, fuel)
    end
  end

  defp parse_map_entry(t, i, diags, nid, fuel) do
    if Tokens.kind(t, i) == :kw_identifier do
      key = CST.token(i)
      {val, j, diags, nid, fuel} = parse_expr(t, i + 1, 0, :matched, diags, nid, fuel - 1)

      {CST.node(:kw_pair, merge(tok_span(t, i), cst_span(t, val)), [key, val], :matched, nil), j,
       diags, nid, fuel}
    else
      {key, j, diags, nid, fuel} = parse_expr(t, i, @map_key_bp, :matched, diags, nid, fuel - 1)
      jj = skip_eols(t, j)

      if Tokens.kind(t, jj) == :assoc_op do
        {val, k, diags, nid, fuel} =
          parse_expr(t, skip_eols(t, jj + 1), 0, :matched, diags, nid, fuel - 1)

        {CST.node(:assoc, merge(cst_span(t, key), cst_span(t, val)), [key, val], :matched, nil),
         k, diags, nid, fuel}
      else
        {id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :expected_assoc, tok_span(t, jj), %{})

        {CST.node(
           :assoc,
           merge(cst_span(t, key), tok_span(t, jj)),
           [key, CST.missing(:"=>", jj, diag: id)],
           :matched,
           nil
         ), jj, diags, nid, fuel}
      end
    end
  end

  defp map_unterminated(t, i, acc, diags, nid, fuel) do
    {id, diags, nid} =
      Diagnostics.emit(diags, nid, :parser, :error, :expected_comma_or_close, tok_span(t, i), %{
        close: :"}"
      })

    {:lists.reverse([CST.missing(:"}", i, diag: id) | acc]), i, diags, nid, fuel}
  end

  # `[ ... ]` / `{ ... }`: a comma-separated sequence of expressions. `|` (cons) and keyword
  # pairs are ordinary expression content handled by the Pratt loop / lowering.
  defp parse_container(t, open, close, kind, diags, nid, fuel) do
    {elems, j, diags, nid, fuel} = parse_seq(t, open + 1, close, diags, nid, fuel)

    {CST.node(kind, merge(tok_span(t, open), tok_span(t, j - 1)), elems, :matched, nil), j, diags,
     nid, fuel}
  end

  # Comma-separated expressions up to `close` (shared by lists, tuples, and call args). Returns
  # `{elements, index_after_close, ...}`. Tolerant: a missing closer yields a `:missing` element
  # and one diagnostic.
  defp parse_seq(t, i, close, diags, nid, fuel) do
    i = skip_eols(t, i)

    if Tokens.kind(t, i) == close do
      {[], i + 1, diags, nid, fuel}
    else
      seq_elems(t, i, [], close, diags, nid, fuel)
    end
  end

  # A sequence element is a `key: value` keyword pair when it starts with `:kw_identifier`,
  # otherwise an ordinary expression. Keyword collection (list-inline vs call-arg list) is a
  # lowering concern.
  defp parse_element(t, i, diags, nid, fuel) do
    if Tokens.kind(t, i) == :kw_identifier do
      key = CST.token(i)
      {val, j, diags, nid, fuel} = parse_expr(t, i + 1, 0, :matched, diags, nid, fuel - 1)

      {CST.node(:kw_pair, merge(tok_span(t, i), cst_span(t, val)), [key, val], :matched, nil), j,
       diags, nid, fuel}
    else
      parse_expr(t, i, 0, :matched, diags, nid, fuel)
    end
  end

  defp seq_elems(t, i, acc, close, diags, nid, fuel) do
    {el, i, diags, nid, fuel} = parse_element(t, i, diags, nid, fuel)
    i2 = skip_eols(t, i)

    cond do
      Tokens.kind(t, i2) == close ->
        {:lists.reverse([el | acc]), i2 + 1, diags, nid, fuel}

      Tokens.kind(t, i2) == :"," ->
        seq_elems(t, skip_eols(t, i2 + 1), [el | acc], close, diags, nid, fuel)

      true ->
        {id, diags, nid} =
          Diagnostics.emit(
            diags,
            nid,
            :parser,
            :error,
            :expected_comma_or_close,
            tok_span(t, i2),
            %{close: close}
          )

        {:lists.reverse([CST.missing(close, i2, diag: id), el | acc]), i2, diags, nid, fuel}
    end
  end

  defp parse_unary(t, i, prefix_bp, ctx, diags, nid, fuel) do
    op_leaf = CST.token(i)
    operand_start = skip_eols(t, i + 1)

    {operand, k, diags, nid, fuel} =
      parse_expr(t, operand_start, prefix_bp, ctx, diags, nid, fuel - 1)

    node =
      CST.node(
        :unary_op,
        merge(cst_span(t, op_leaf), cst_span(t, operand)),
        [op_leaf, operand],
        :matched,
        nil
      )

    {node, k, diags, nid, fuel}
  end

  # A single parenthesised expression. Multi-statement parens `(a; b)` are deferred; here a `;`
  # before `)` is reported as a missing `)` and recovered by the expr-list loop.
  # A paren resets to a fresh `:matched` context, so the caller's `ctx` is not threaded inside.
  defp parse_paren(t, open, _ctx, diags, nid, fuel) do
    inner_start = skip_eols(t, open + 1)

    if Tokens.kind(t, inner_start) == :")" do
      span = merge(tok_span(t, open), tok_span(t, inner_start))
      {CST.node(:paren, span, [], :matched, nil), inner_start + 1, diags, nid, fuel}
    else
      {inner, k, diags, nid, fuel} = parse_expr(t, inner_start, 0, :matched, diags, nid, fuel - 1)
      close = skip_eols(t, k)
      close_paren(t, open, inner, close, diags, nid, fuel)
    end
  end

  defp close_paren(t, open, inner, close, diags, nid, fuel) do
    if Tokens.kind(t, close) == :")" do
      span = merge(tok_span(t, open), tok_span(t, close))
      {CST.node(:paren, span, [inner], :matched, nil), close + 1, diags, nid, fuel}
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_rparen, tok_span(t, close))

      miss = CST.missing(:")", close, diag: id)
      span = merge(tok_span(t, open), cst_span(t, inner))
      {CST.node(:paren, span, [inner, miss], :matched, nil), close, diags, nid, fuel}
    end
  end

  defp parse_unexpected(t, i, diags, nid, fuel) do
    if Tokens.at_eof?(t, i) do
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_expression, eof_span(t))

      {CST.missing(:expression, i, diag: id), i, diags, nid, fuel}
    else
      details = %{kind: Tokens.kind(t, i)}

      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), details)

      {CST.token(i, error: true, diag: id), i + 1, diags, nid, fuel}
    end
  end

  # --- diagnostics for lexer error tokens (sole transport, P3) -----------

  defp emit_lex_error(t, i, diags, nid) do
    %LexError{code: code} = Tokens.value(t, i)
    Diagnostics.emit(diags, nid, :lexer, :error, code, tok_span(t, i))
  end

  # --- cursor helpers ----------------------------------------------------

  defp skip_eoe(t, i) do
    case Tokens.kind(t, i) do
      :eol -> skip_eoe(t, i + 1)
      :";" -> skip_eoe(t, i + 1)
      _ -> i
    end
  end

  defp skip_eols(t, i) do
    case Tokens.kind(t, i) do
      :eol -> skip_eols(t, i + 1)
      _ -> i
    end
  end

  # --- span resolution ---------------------------------------------------

  defp cst_span(t, cst) do
    case CST.tag(cst) do
      :node -> CST.span(cst)
      :token -> Tokens.span(t, CST.token_index(cst))
      :missing -> anchor_span(t, CST.anchor_index(cst))
    end
  end

  defp anchor_span(t, ai) do
    case Tokens.span(t, ai) do
      nil -> eof_span(t)
      {sl, sc, _el, _ec} -> {sl, sc, sl, sc}
    end
  end

  defp list_span(_t, []), do: {1, 1, 1, 1}

  defp list_span(t, exprs),
    do: merge(cst_span(t, List.first(exprs)), cst_span(t, List.last(exprs)))

  defp merge(nil, b), do: b
  defp merge(a, nil), do: a
  defp merge({sl, sc, _, _}, {_, _, el, ec}), do: {sl, sc, el, ec}

  defp tok_span(t, i), do: Tokens.span(t, i) || eof_span(t)

  defp eof_span(t) do
    case Tokens.size(t) do
      0 ->
        {1, 1, 1, 1}

      n ->
        {_, _, el, ec} = Tokens.span(t, n - 1)
        {el, ec, el, ec}
    end
  end
end
