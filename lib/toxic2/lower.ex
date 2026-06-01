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
  @spec to_ast(CST.t(), Tokens.t(), keyword(), pos_integer()) :: {ast(), [Toxic2.Diagnostic.t()]}
  def to_ast(cst, view, opts \\ [], start_id \\ 1) do
    {ast, acc, _nid} = lower(cst, view, resolve_opts(opts), [], start_id)
    {ast, Diagnostics.to_list(acc)}
  end

  # Resolve the (keyword) options ONCE into a compact map threaded through lowering, so per-node
  # checks are a map field read (`opts.range`) instead of a `Keyword.get` keyfind over the option
  # list on every node (tprof: that keyfind was ~4 % of all calls).
  defp resolve_opts(opts) do
    %{
      existing_atoms_only: Keyword.get(opts, :existing_atoms_only, false),
      range: Keyword.get(opts, :range, false),
      literal_encoder: Keyword.get(opts, :literal_encoder)
    }
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
      :int -> lit(val, view, idx, opts, acc, nid)
      :flt -> lit(val, view, idx, opts, acc, nid)
      :char -> lit(val, view, idx, opts, acc, nid)
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
  defp lit(value, view, idx, opts, acc, nid) do
    case opts.literal_encoder do
      nil -> {value, acc, nid}
      enc -> run_encoder(enc, value, Tokens.span(view, idx), opts, acc, nid)
    end
  end

  defp run_encoder(enc, value, span, opts, acc, nid),
    do: run_encoder_meta(enc, value, literal_meta(span, opts), span, acc, nid)

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
    finalize_node(kind, ast, cst, opts, acc, nid)
  end

  # A real node result → attach its source range. A bare literal result from a literal-bearing kind
  # → run the literal encoder. Anything else (e.g. a synthetic `nil`) passes through untouched.
  defp finalize_node(_kind, {form, meta, args}, cst, opts, acc, nid) when is_list(meta),
    do: {put_node_range({form, meta, args}, cst, opts), acc, nid}

  defp finalize_node(kind, ast, cst, opts, acc, nid) when kind in @literal_node_kinds do
    encode_node_literal(ast, cst, opts, acc, nid)
  end

  # A parenthesised stab `(a -> b)` (e.g. a function type in a spec) lowers to a clause LIST, which
  # Elixir treats as a list literal — so the encoder wraps it. Single-expr / multi-stmt parens lower
  # to a node or an already-encoded child instead, so only the bare-list (stab) case lands here.
  defp finalize_node(:paren, ast, cst, opts, acc, nid) when is_list(ast),
    do: encode_node_literal(ast, cst, opts, acc, nid)

  defp finalize_node(_kind, ast, _cst, _opts, acc, nid), do: {ast, acc, nid}

  defp encode_node_literal(ast, cst, opts, acc, nid) do
    case opts.literal_encoder do
      nil -> {ast, acc, nid}
      enc -> run_encoder(enc, ast, CST.span(cst), opts, acc, nid)
    end
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
  defp lower_kind(:expr_list, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(:paren, ch, _cst, view, opts, acc, nid),
    do: lower_paren(ch, view, opts, acc, nid)

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
  defp lower_kind(:np_call, ch, _cst, view, opts, acc, nid),
    do: lower_call(ch, view, opts, acc, nid)

  defp lower_kind(:alias, ch, _cst, view, opts, acc, nid),
    do: lower_alias(ch, view, opts, acc, nid)

  defp lower_kind(:remote_call, ch, _cst, view, opts, acc, nid),
    do: lower_remote_call(ch, view, opts, acc, nid)

  # `Foo.{A, B}` => `{{:., _, [base, :{}]}, _, [elems]}` (multi-alias / `alias Foo.{...}`).
  defp lower_kind(:dot_tuple, [base | elems], _cst, view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {elem_asts, acc, nid} = lower_args(elems, view, opts, acc, nid)
    {{{:., [], [base_ast, :{}]}, [], elem_asts}, acc, nid}
  end

  defp lower_kind(:anon_call, ch, _cst, view, opts, acc, nid),
    do: lower_anon_call(ch, view, opts, acc, nid)

  defp lower_kind(:kw_pair, ch, _cst, view, opts, acc, nid),
    do: lower_kw_pair(ch, view, opts, acc, nid)

  defp lower_kind(:bitstring, ch, _cst, view, opts, acc, nid),
    do: lower_bitstring(ch, view, opts, acc, nid)

  defp lower_kind(:access, ch, _cst, view, opts, acc, nid),
    do: lower_access(ch, view, opts, acc, nid)

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
    {{:->, [], [args, body]}, acc, nid}
  end

  defp lower_kind(:string, ch, _cst, view, opts, acc, nid),
    do: lower_string(ch, view, opts, acc, nid)

  defp lower_kind(:charlist, ch, _cst, view, opts, acc, nid),
    do: lower_charlist(ch, view, opts, acc, nid)

  defp lower_kind(:sigil, ch, _cst, view, opts, acc, nid),
    do: lower_sigil(ch, view, opts, acc, nid)

  # `:"..."` / `:'...'` — no interpolation lowers to the atom (atom policy); with interpolation to
  # `:erlang.binary_to_atom(<<...>>, :utf8)`.
  defp lower_kind(:quoted_atom, [inner], _cst, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(CST.children(inner), view, opts, acc, nid)
    build_quoted_atom(parts, inner, view, opts, acc, nid)
  end

  # An interpolation's inner is a block (`#{a; b}` → `{:__block__, ...}`, `#{a}` → `a`).
  defp lower_kind(:interp, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(_other, _ch, cst, view, _opts, acc, nid), do: {error_ast(cst, view), acc, nid}

  # A string lowers to a bare binary with no interpolation, else the `<<>>` form Elixir uses:
  # fragments stay binaries; each interpolation becomes a `Kernel.to_string/1` ::-binary segment.
  defp lower_string(children, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(children, view, opts, acc, nid)
    build_string(parts, acc, nid)
  end

  # A charlist lowers to a literal codepoint list with no interpolation, else to
  # `List.to_charlist([...])` where interpolations are bare `Kernel.to_string/1` (no ::-binary).
  defp lower_charlist(children, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(children, view, opts, acc, nid)
    build_charlist(parts, acc, nid)
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
      {[{:interp, ast} | parts], acc, nid}
    else
      {parts, acc, nid}
    end
  end

  defp build_string(parts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _}, &1)) do
      {{:<<>>, [], Enum.map(parts, &string_segment/1)}, acc, nid}
    else
      {parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary(), acc, nid}
    end
  end

  defp build_charlist(parts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _}, &1)) do
      {{{:., [], [List, :to_charlist]}, [], [Enum.map(parts, &charlist_segment/1)]}, acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()
      {safe_to_charlist(bin), acc, nid}
    end
  end

  defp build_quoted_atom(parts, inner, view, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _}, &1)) do
      segs = Enum.map(parts, &string_segment/1)
      {{{:., [], [:erlang, :binary_to_atom]}, [], [{:<<>>, [], segs}, :utf8]}, acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()
      atomize_quoted(bin, inner, opts, view, acc, nid)
    end
  end

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

  defp string_segment({:frag, bin}), do: bin

  defp string_segment({:interp, ast}),
    do: {:"::", [], [{{:., [], [Kernel, :to_string]}, [], [ast]}, {:binary, [], nil}]}

  defp charlist_segment({:frag, bin}), do: bin
  defp charlist_segment({:interp, ast}), do: {{:., [], [Kernel, :to_string]}, [], [ast]}

  # A sigil → `{:"sigil_<name>", [], [{:<<>>, [], segs}, modifier_charlist]}`. Content segments are
  # like a string's (the sigil macro does any further unescaping at expansion); the name atom
  # respects the atom policy. children = [start_leaf | parts... | end_leaf].
  defp lower_sigil([start_leaf | rest], view, opts, acc, nid) do
    name = Tokens.value(view, CST.token_index(start_leaf))
    {part_children, mods} = sigil_split(rest, view)
    {parts, acc, nid} = quoted_parts_ast(part_children, view, opts, acc, nid)
    build_sigil(name, parts, mods, start_leaf, view, opts, acc, nid)
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

  defp build_sigil(name, parts, mods, start_leaf, view, opts, acc, nid) do
    case to_atom("sigil_" <> name, opts) do
      {:ok, atom} ->
        {{atom, [], [{:<<>>, [], sigil_segments(parts)}, safe_to_charlist(mods)]}, acc, nid}

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
  defp sigil_segments([]), do: [""]
  defp sigil_segments(parts), do: Enum.map(parts, &string_segment/1)

  defp lower_block([], _view, _opts, acc, nid), do: {{:__block__, [], []}, acc, nid}

  defp lower_block([only], view, opts, acc, nid) do
    {ast, acc, nid} = lower(only, view, opts, acc, nid)
    {wrap_splice(ast), acc, nid}
  end

  defp lower_block(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_each(children, view, opts, acc, nid)
    {{:__block__, [], asts}, acc, nid}
  end

  # Parentheses are transparent in the AST (they only carry metadata upstream).
  # A paren is a statement block: empty => empty block, one => the expr (transparent), many =>
  # `__block__`. A trailing recovered `:missing` (no `)`) is skipped — its diagnostic is emitted.
  defp lower_paren(children, view, opts, acc, nid) do
    children = Enum.reject(children, &(CST.tag(&1) == :missing))

    # A paren of stab clauses (`(a -> b; c -> d)`) lowers to the bare clause LIST `[{:->, …}, …]`,
    # not a statement block.
    if Enum.any?(children, &stab_node?/1) do
      lower_each(children, view, opts, acc, nid)
    else
      {ast, acc, nid} = lower_block(children, view, opts, acc, nid)
      {wrap_paren_negation(ast), acc, nid}
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
        {{op_atom(op_leaf, view), op_meta(op_leaf, view), [l, r]}, acc, nid}
    end
  end

  # `a..b//c` is the ternary step range `{:..//, _, [a, b, c]}` — i.e. a `//` whose left side is a
  # range. We test the LOWERED lhs (so a parenthesised range works too: `(a..b)//c`).
  defp lower_slash_slash(lhs, op_leaf, rhs, view, opts, acc, nid) do
    {l, acc, nid} = lower(lhs, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)

    case l do
      # Valid only as the range step: `a..b//c` (lhs a 2-element range, incl. through parens).
      {:.., _m, [a, b]} ->
        {{:..//, [], [a, b, r]}, acc, nid}

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

    {{neg, [], [{:in, [], [o, r]}]}, acc, nid}
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
    {{callee_ast, [], args}, acc, nid}
  end

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

      case seg_atoms(rest, view, opts) do
        {:ok, atoms} -> {{:__aliases__, meta, [base_ast | atoms]}, acc, nid}
        {:error, leaf} -> alias_seg_error(leaf, view, acc, nid)
      end
    end
  end

  defp build_alias(leaves, meta, view, opts, acc, nid) do
    case seg_atoms(leaves, view, opts) do
      {:ok, atoms} -> {{:__aliases__, meta, atoms}, acc, nid}
      {:error, leaf} -> alias_seg_error(leaf, view, acc, nid)
    end
  end

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

  # `a.b` / `a.b(args)` => `{{:., m, [base, name]}, m, args}` (zero-arg form is just `args = []`).
  defp lower_remote_call([base, name_leaf | arg_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    remote_name(CST.tag(name_leaf), name_leaf, base_ast, args, view, opts, acc, nid)
  end

  defp remote_name(:token, name_leaf, base_ast, args, view, opts, acc, nid) do
    idx = CST.token_index(name_leaf)
    meta = tmeta(view, idx)

    case member_atom(Tokens.kind(view, idx), Tokens.value(view, idx), opts) do
      {:ok, name} -> {{{:., meta, [base_ast, name]}, meta, args}, acc, nid}
      :error -> name_error(name_leaf, view, acc, nid)
    end
  end

  # A recovered missing name (`foo.` with nothing after) — its diagnostic was already emitted by
  # the parser; lower to an error node (P5: total, never raises).
  defp remote_name(:missing, name_leaf, _base_ast, _args, view, _opts, acc, nid),
    do: name_error(name_leaf, view, acc, nid)

  # `a."foo"` — the function name is a quoted literal. No interpolation allowed (Elixir rejects
  # `a."f#{x}"`): atomize the concatenated fragments; on interpolation, error + best-effort.
  defp remote_name(:node, name_node, base_ast, args, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(CST.children(name_node), view, opts, acc, nid)

    if Enum.any?(parts, &match?({:interp, _}, &1)) do
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
        {:ok, name} -> {{{:., [], [base_ast, name]}, [], args}, acc, nid}
        :error -> name_error(name_node, view, acc, nid)
      end
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
  defp lower_anon_call([base | arg_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)

    # `lower_call_args` (not `lower_args`) so a trailing do-block becomes `[do: …]` — `f.() do … end`.
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    meta = error_meta(base, view)
    {{{:., meta, [base_ast]}, meta, args}, acc, nid}
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
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    kw_key(CST.tag(key), key, v, view, opts, acc, nid)
  end

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
    {key_ast, acc, nid} = build_quoted_atom(parts, key_node, view, opts, acc, nid)
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

        run_encoder_meta(
          enc,
          atom,
          [{:format, :keyword} | literal_meta(span, opts)],
          span,
          acc,
          nid
        )
    end
  end

  defp encode_quoted_kw_key(other, _key_node, _opts, acc, nid), do: {other, acc, nid}

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
    {b, acc, nid} = lower_section_body(body, view, opts, acc, nid)
    {key, acc, nid} = section_label(label_leaf, view, opts, acc, nid)
    {{key, b}, acc, nid}
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
  # `{:->, ...}` clauses.
  defp lower_section_body({:node, :do_clauses, _sp, clauses, _f, _d}, view, opts, acc, nid),
    do: lower_each(clauses, view, opts, acc, nid)

  defp lower_section_body({:node, :do_body, _sp, stmts, _f, _d}, view, opts, acc, nid) do
    case stmts do
      # An empty section body is `{:__block__, [], []}` (`foo do end` => `[do: {:__block__,[],[]}]`),
      # NOT nil — Elixir distinguishes an empty block from a missing one.
      [] ->
        {{:__block__, [], []}, acc, nid}

      [one] ->
        {ast, acc, nid} = lower(one, view, opts, acc, nid)
        {wrap_splice(ast), acc, nid}

      many ->
        wrap_block(lower_each(many, view, opts, acc, nid))
    end
  end

  # `<<...>>` => `{:<<>>, [], elems}` (segments incl. `::` are ordinary expressions).
  # Trailing keyword pairs collapse into one keyword-list element (`<<a, k: 1>>` => `[a, [k: 1]]`).
  defp lower_bitstring(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_args(children, view, opts, acc, nid)
    {{:<<>>, [], asts}, acc, nid}
  end

  # `a[b]` => `{{:., m, [Access, :get]}, m, [base, index]}`.
  defp lower_access([base, idx | _missing], view, opts, acc, nid) do
    {b, acc, nid} = lower(base, view, opts, acc, nid)
    {k, acc, nid} = lower(idx, view, opts, acc, nid)
    {{{:., [], [Access, :get]}, [], [b, k]}, acc, nid}
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
    {{:%{}, [], [{:|, [], [base_ast, entries]}]}, acc, nid}
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
  defp lower_stab_args(args_node, view, opts, acc, nid) do
    case CST.children(args_node) do
      [{:node, :stab_when, _sp, when_ch, _f, _d}] ->
        {pats, [guard]} = Enum.split(when_ch, length(when_ch) - 1)

        # `fn () when g -> …`: an empty parenthesised head is ZERO patterns, so `when` wraps just
        # the guard (`{:when, [], [g]}`), mirroring the bare `fn () -> …` => `[]` case below.
        {pat_asts, acc, nid} = lower_args(strip_empty_paren_head(pats), view, opts, acc, nid)
        {guard_ast, acc, nid} = lower(guard, view, opts, acc, nid)
        {[{:when, [], Enum.concat(pat_asts, [guard_ast])}], acc, nid}

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
        {wrap_splice(ast), acc, nid}

      many ->
        wrap_block(lower_each(many, view, opts, acc, nid))
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
    {{:not, [], [{:in, [], [l, r]}]}, acc, nid}
  end

  # `key => value` map entry => `{key, value}` 2-tuple.
  defp lower_assoc([key, val], view, opts, acc, nid) do
    {k, acc, nid} = lower(key, view, opts, acc, nid)
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    {{k, v}, acc, nid}
  end

  # Thread the accumulator while lowering a list of children.
  defp lower_each(children, view, opts, acc, nid) do
    {rev, acc, nid} =
      Enum.reduce(children, {[], acc, nid}, fn child, {asts, a, n} ->
        {ast, a, n} = lower(child, view, opts, a, n)
        {[ast | asts], a, n}
      end)

    {:lists.reverse(rev), acc, nid}
  end

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
