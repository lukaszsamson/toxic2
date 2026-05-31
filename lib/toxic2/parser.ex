defmodule Toxic2.Parser do
  @moduledoc """
  Parser core (see `TOXIC_2.md` → Parser; Migration Phases #5–#8).

  Covers a top-level **expression list** of literals, identifiers/aliases, atoms, prefix/infix
  **operators**, parentheses, **lists `[...]`** (incl. keyword pairs), **tuples `{...}`**, **paren
  calls `f(...)`**, **dot/remote/anon calls** (`a.b`, `Foo.bar(...)`, `a.(...)`), **alias chains**
  (`Foo.Bar`), **maps/structs** (`%{...}`, `%Name{...}`, incl. `|` update), **bitstrings**
  (`<<...>>`), **access** (`a[b]`), and **no-parens calls** (`f a, b`, `f g a, b` → `f(g(a,b))`,
  `f -1` vs `f - 1`). It builds a **green CST only** (`Toxic2.CST`) — never the Elixir AST, and no
  AST quirks (those belong to lowering, phase 6).

  Expression-class context (`ctx`) is load-bearing for no-parens calls: `:no_parens` (statement /
  paren-call arg) permits many comma-separated args; `:matched` (operator operands, container
  elements) permits a single arg.

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

  Also covers anonymous functions **`fn ... -> ... end`** and **`do`/`end` blocks** (`if`, `case`,
  `cond`, `receive`, `try`, `with`, `foo do ... end`) — multi-clause, `when` guards, block labels
  (`else`/`catch`/`rescue`/`after`), and statement-or-stab-clause bodies. The do-block attaches to
  the outer call (`foo bar do end` => `foo(bar, do: ...)`).

  Also: **`&` capture** — `&N` (the atomic `:capture_int` leaf → `{:&, _, [N]}`) and `&<expr>`
  (a low-precedence unary, family `capture_op` at 90 → `{:&, _, [operand]}`), so `&foo/1`,
  `&Mod.fun/2`, `&(&1 + &2)` work.

  Chained/double-parens calls `f(a)(b)` / `a.b()()` are handled with Elixir's "at most two paren
  groups per base" rule (a third, or a call on an alias/access/container, is an error).

  Not yet handled (later islands): multi-statement parens, the `Foo.{A, B}` dot-tuple.
  Encountering those yields error/leaf nodes rather than crashing.
  """

  alias Toxic2.{CST, Diagnostics, LexError, Precedence, Tokens}

  @fuel_base 1_000

  @atomic_kinds [:int, :flt, :char, :atom, :literal, :identifier, :capture_int]

  # A map key / update base is parsed stopping before `|` (pipe_op 70) so the update separator
  # isn't swallowed as a binary operator.
  @map_key_bp 71

  # A struct name is a primary (alias chain / var); parse it above all operator precedences so
  # only nud + dot postfixes apply, never a trailing binary op or the `{`.
  @struct_name_bp 1_000

  # A clause pattern is parsed stopping before `when` (when_op 50), so the guard isn't swallowed.
  @clause_pattern_bp 51

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
    # Statement position is a `:no_parens` context: `f a, b` is a multi-arg no-parens call.
    {expr, i2, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens, diags, nid, fuel - 1)
    # Forward-progress guard: parse_expr always advances on real input, but never loop.
    i2 = if i2 > i, do: i2, else: i + 1
    {i3, diags, nid} = end_statement(t, i2, diags, nid)
    collect(t, i3, [expr | acc], diags, nid, fuel)
  end

  # A statement must end at EOE / EOF. Anything else is a leftover token on the same line that
  # no grammar routine consumed (`1 2`, `Foo bar`) — an error; skip to the next boundary.
  defp end_statement(t, i, diags, nid) do
    case Tokens.kind(t, i) do
      k when k in [:eol, :";"] ->
        {skip_eoe(t, i), diags, nid}

      :eof ->
        {i, diags, nid}

      # A leftover lexer error token: report the lexer error (sole transport, P3), don't restate.
      :error ->
        {_id, diags, nid} = emit_lex_error(t, i, diags, nid)
        {skip_to_eoe(t, i + 1), diags, nid}

      k ->
        {_id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), %{
            kind: k
          })

        {skip_to_eoe(t, i + 1), diags, nid}
    end
  end

  defp skip_to_eoe(t, i) do
    case Tokens.kind(t, i) do
      k when k in [:eol, :";"] -> skip_eoe(t, i)
      :eof -> i
      _ -> skip_to_eoe(t, i + 1)
    end
  end

  # --- Pratt ------------------------------------------------------------

  defp parse_expr(t, i, min_bp, ctx, diags, nid, fuel) do
    {lhs, i, diags, nid, fuel} = parse_prefix(t, i, ctx, diags, nid, fuel)
    {lhs, i, diags, nid, fuel} = postfix(t, i, lhs, ctx, diags, nid, fuel)
    {lhs, i, diags, nid, fuel} = maybe_no_parens(t, i, lhs, ctx, diags, nid, fuel)
    {lhs, i, diags, nid, fuel} = maybe_do_block(t, i, lhs, ctx, diags, nid, fuel)
    led(t, i, lhs, min_bp, ctx, diags, nid, fuel)
  end

  # `<call> do ... end`: the do-block attaches to the call as a trailing `[do: ..., else: ...]`
  # keyword list. Suppressed in `:no_parens_arg` so the do attaches to the OUTER call:
  # `foo bar do end` => `foo(bar, do: ...)`, not `foo(bar(do: ...))`.
  defp maybe_do_block(t, i, lhs, ctx, diags, nid, fuel) do
    if ctx != :no_parens_arg and Tokens.kind(t, i) == :do and do_attachable?(lhs, t) do
      {db, j, diags, nid, fuel} = parse_do_block(t, i, diags, nid, fuel)
      {attach_do(t, lhs, db, j), j, diags, nid, fuel}
    else
      {lhs, i, diags, nid, fuel}
    end
  end

  defp do_attachable?({:token, idx, _f, _d}, t), do: Tokens.kind(t, idx) == :identifier
  defp do_attachable?({:node, k, _sp, _ch, _f, _d}, _t), do: k in [:call, :np_call, :remote_call]
  defp do_attachable?(_lhs, _t), do: false

  defp attach_do(t, lhs, db, end_i) do
    span = merge(cst_span(t, lhs), tok_span(t, end_i - 1))

    case lhs do
      {:token, _idx, _f, _d} ->
        CST.node(:call, span, [lhs, db], :matched, nil)

      {:node, k, _sp, children, _f, _d} ->
        CST.node(k, span, Enum.concat(children, [db]), :matched, nil)
    end
  end

  # No-parens call: a bare identifier callee followed (with a space, same line) by an argument.
  # In a `:no_parens` context (statement / paren-call arg) it takes many comma-separated args;
  # elsewhere (`:matched`: operator operands, container elements) it takes a single arg. Args are
  # themselves parsed in `:no_parens`, so `f g a, b` makes the inner call absorb the commas
  # (`f(g(a, b))`, outer arity 1).
  defp maybe_no_parens(t, i, lhs, ctx, diags, nid, fuel) do
    if np_callee?(lhs, t) and np_arg_start?(t, lhs, i) do
      {arg, j, is_kw, diags, nid, fuel} = parse_np_arg(t, i, diags, nid, fuel)

      {args, k, diags, nid, fuel} =
        if ctx in [:no_parens, :no_parens_arg],
          do: np_more_args(t, j, [arg], is_kw, diags, nid, fuel),
          else: {[arg], j, diags, nid, fuel}

      {build_np_call(t, lhs, args, k), k, diags, nid, fuel}
    else
      {lhs, i, diags, nid, fuel}
    end
  end

  # Additional comma-separated args. A newline is allowed after the comma (`f a,\n b`), and
  # keyword pairs must come last.
  defp np_more_args(t, i, args, seen_kw, diags, nid, fuel) do
    if Tokens.kind(t, i) == :"," do
      {arg, j, is_kw, diags, nid, fuel} = parse_np_arg(t, skip_eols(t, i + 1), diags, nid, fuel)
      {diags, nid} = check_kw_last(seen_kw, is_kw, t, arg, diags, nid)
      np_more_args(t, j, [arg | args], seen_kw or is_kw, diags, nid, fuel)
    else
      {:lists.reverse(args), i, diags, nid, fuel}
    end
  end

  # Build the no-parens call, marking it `:no_parens` (so a container can detect the ambiguous
  # `[f a, b]`). A plain identifier callee becomes `:np_call`; a bare remote (`a.b`) gains args.
  defp build_np_call(t, lhs, args, end_i) do
    span = merge(cst_span(t, lhs), tok_span(t, end_i - 1))

    case lhs do
      {:node, :remote_call, _sp, [base, name], _f, _d} ->
        CST.node(:remote_call, span, [base, name | args], :no_parens, nil)

      _ ->
        CST.node(:np_call, span, [lhs | args], :no_parens, nil)
    end
  end

  # A no-parens argument is a keyword pair or a full expression, parsed in `:no_parens`. Returns
  # the node, next index, and whether it was a keyword pair (for keyword-last enforcement).
  defp parse_np_arg(t, i, diags, nid, fuel) do
    if Tokens.kind(t, i) == :kw_identifier do
      key = CST.token(i)
      {val, j, diags, nid, fuel} = parse_expr(t, i + 1, 0, :no_parens_arg, diags, nid, fuel - 1)

      node =
        CST.node(:kw_pair, merge(tok_span(t, i), cst_span(t, val)), [key, val], :matched, nil)

      {node, j, true, diags, nid, fuel}
    else
      {expr, j, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens_arg, diags, nid, fuel - 1)
      {expr, j, false, diags, nid, fuel}
    end
  end

  # A no-parens callee is a bare identifier, or a bare remote (`a.b` with no args yet).
  defp np_callee?({:token, idx, _f, _d}, t), do: Tokens.kind(t, idx) == :identifier
  defp np_callee?({:node, :remote_call, _sp, [_base, _name], _f, _d}, _t), do: true
  defp np_callee?(_lhs, _t), do: false

  # Can a no-parens argument start at `i`, given the callee `lhs`? Requires a space after the
  # callee (same line). `f -1` is a call (op adjacent to operand); `f - 1` is binary subtraction.
  defp np_arg_start?(t, lhs, i) do
    case {cst_span(t, lhs), Tokens.span(t, i)} do
      {{_, _, el, ec}, {sl, sc, _, _}} when el == sl and ec < sc ->
        case Tokens.kind(t, i) do
          :dual_op -> Tokens.adjacent?(t, i, i + 1) and np_first_kind?(Tokens.kind(t, i + 1))
          # `not` starts an arg (`f not x`) unless it is the `not in` operator (`a not in b`).
          :unary_op -> not not_in?(t, i)
          k -> np_first_kind?(k)
        end

      _ ->
        false
    end
  end

  defp not_in?(t, i) do
    Tokens.kind(t, i) == :unary_op and Tokens.value(t, i) == :not and
      Tokens.kind(t, skip_eols(t, i + 1)) == :in_op
  end

  defp np_first_kind?(kind) do
    kind in [
      :int,
      :flt,
      :char,
      :atom,
      :literal,
      :identifier,
      :alias,
      :"(",
      :"[",
      :"{",
      :"<<",
      :percent,
      :at_op,
      :capture_op,
      :capture_int,
      :unary_op,
      :kw_identifier
    ]
  end

  # Postfix operations bind tightest (yecc 310): a paren call `f(...)` (adjacent `(`), and dot
  # forms `a.b` / `a.b(...)` / `a.(...)` / `Foo.Bar` (alias chain). `pdepth` counts paren-call
  # groups already applied to the CURRENT call base: Elixir's "double parens" rule allows at most
  # two (`foo(a)(b)`, `a.b()()`), so a third is rejected. A dot / access / alias starts a fresh
  # base (`pdepth` resets to 0); a consumed first group (remote/anon call) continues at 1.
  defp postfix(t, i, lhs, ctx, diags, nid, fuel), do: postfix(t, i, lhs, ctx, diags, nid, fuel, 0)

  defp postfix(t, i, lhs, ctx, diags, nid, fuel, pdepth) do
    cond do
      paren_call?(t, lhs, i, pdepth) ->
        {args, j, diags, nid, fuel} = parse_seq(t, i + 1, :")", :call, diags, nid, fuel)

        call =
          CST.node(
            :call,
            merge(cst_span(t, lhs), tok_span(t, j - 1)),
            [lhs | args],
            :matched,
            nil
          )

        postfix(t, j, call, ctx, diags, nid, fuel, pdepth + 1)

      access?(t, lhs, i) ->
        access(t, i, lhs, ctx, diags, nid, fuel)

      # A dot may follow on the next line (`a\n.b`); skip eols only to reach a dot, not past one.
      dot_continuation?(t, i) ->
        dot(t, skip_eols(t, i), lhs, ctx, diags, nid, fuel)

      true ->
        {lhs, i, diags, nid, fuel}
    end
  end

  defp dot_continuation?(t, i), do: Tokens.kind(t, skip_eols(t, i)) == :dot

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

  # A paren-call needs an adjacent `(` and an eligible callee for the current depth: at depth 0 a
  # bare local-call identifier (`foo(`), at depth 1 the call node it produced (the double
  # `foo()(`); never deeper, and never an alias / access / container / literal callee.
  defp paren_call?(t, lhs, i, pdepth) do
    Tokens.kind(t, i) == :"(" and paren_callee?(t, lhs, pdepth) and
      adjacent_after?(cst_span(t, lhs), Tokens.span(t, i))
  end

  defp paren_callee?(t, lhs, 0),
    do: CST.tag(lhs) == :token and Tokens.kind(t, CST.token_index(lhs)) == :identifier

  defp paren_callee?(_t, lhs, 1),
    do: CST.tag(lhs) == :node and CST.node_kind(lhs) in [:call, :remote_call, :anon_call]

  defp paren_callee?(_t, _lhs, _pdepth), do: false

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

        # An alias chain (`Foo.Bar`) is a fresh base that does NOT take a paren-call (`Foo.Bar()`
        # is rejected by Elixir), so depth 0.
        postfix(t, j + 1, node, ctx, diags, nid, fuel, 0)

      :identifier ->
        remote_call(t, j, lhs, ctx, diags, nid, fuel)

      :"(" ->
        {args, k, diags, nid, fuel} = parse_seq(t, j + 1, :")", :call, diags, nid, fuel)

        node =
          CST.node(
            :anon_call,
            merge(cst_span(t, lhs), tok_span(t, k - 1)),
            [lhs | args],
            :matched,
            nil
          )

        # Anon call `a.(...)` consumed its first paren group; one more (`a.()()`) is allowed.
        postfix(t, k, node, ctx, diags, nid, fuel, 1)

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
      {args, k, diags, nid, fuel} = parse_seq(t, name_i + 2, :")", :call, diags, nid, fuel)

      node =
        CST.node(
          :remote_call,
          merge(cst_span(t, lhs), tok_span(t, k - 1)),
          [lhs, name | args],
          :matched,
          nil
        )

      # `a.b(...)` consumed its first paren group; the double `a.b()()` is allowed.
      postfix(t, k, node, ctx, diags, nid, fuel, 1)
    else
      node =
        CST.node(
          :remote_call,
          merge(cst_span(t, lhs), tok_span(t, name_i)),
          [lhs, name],
          :matched,
          nil
        )

      # `a.b` (no adjacent parens) is a fresh base; a following `(` would have been consumed above.
      postfix(t, name_i + 1, node, ctx, diags, nid, fuel, 0)
    end
  end

  defp alias_node?(cst), do: CST.tag(cst) == :node and CST.node_kind(cst) == :alias

  defp led(_t, i, lhs, _min_bp, _ctx, diags, nid, fuel) when fuel <= 0,
    do: {lhs, i, diags, nid, fuel}

  defp led(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    # `a not in b`: the two-token `not in` operator (in_op precedence 170, left-assoc). Built as a
    # faithful :not_in_op CST; the rewrite to `not(a in b)` happens only in lowering (P: no
    # rewrite-ish work in Pratt).
    if not_in?(t, i) and 170 >= min_bp do
      led_not_in(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    else
      led_infix(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    end
  end

  defp led_not_in(t, not_i, lhs, min_bp, ctx, diags, nid, fuel) do
    in_i = skip_eols(t, not_i + 1)
    rhs_start = skip_eols(t, in_i + 1)
    {rhs, k, diags, nid, fuel} = parse_expr(t, rhs_start, 171, :matched, diags, nid, fuel - 1)

    node =
      CST.node(:not_in_op, merge(cst_span(t, lhs), cst_span(t, rhs)), [lhs, rhs], :matched, nil)

    led(t, k, node, min_bp, ctx, diags, nid, fuel)
  end

  defp led_infix(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    case Precedence.infix(Tokens.kind(t, i)) do
      {prec, assoc} when prec >= min_bp ->
        op_leaf = CST.token(i)
        next_min = if assoc == :left, do: prec + 1, else: prec
        rhs_start = skip_eols(t, i + 1)
        # Operands are `matched_expr`: a no-parens call here may take only a single argument.
        {rhs, k, diags, nid, fuel} =
          parse_expr(t, rhs_start, next_min, :matched, diags, nid, fuel - 1)

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

      true ->
        parse_primary(kind, t, i, ctx, diags, nid, fuel)
    end
  end

  # Structural prefixes (one trivial clause per opener; keeps `parse_prefix` under the complexity
  # budget). `ctx` is only load-bearing for parens; the rest ignore it.
  defp parse_primary(:"(", t, i, ctx, diags, nid, fuel),
    do: parse_paren(t, i, ctx, diags, nid, fuel)

  defp parse_primary(:"[", t, i, _ctx, diags, nid, fuel),
    do: parse_container(t, i, :"]", :list, diags, nid, fuel)

  defp parse_primary(:"{", t, i, _ctx, diags, nid, fuel),
    do: parse_container(t, i, :"}", :tuple, diags, nid, fuel)

  defp parse_primary(:"<<", t, i, _ctx, diags, nid, fuel),
    do: parse_container(t, i, :">>", :bitstring, diags, nid, fuel)

  defp parse_primary(:percent, t, i, _ctx, diags, nid, fuel),
    do: parse_percent(t, i, diags, nid, fuel)

  defp parse_primary(:fn, t, i, _ctx, diags, nid, fuel), do: parse_fn(t, i, diags, nid, fuel)

  defp parse_primary(:string_start, t, i, _ctx, diags, nid, fuel),
    do: parse_quoted(t, i, :string, diags, nid, fuel)

  defp parse_primary(:charlist_start, t, i, _ctx, diags, nid, fuel),
    do: parse_quoted(t, i, :charlist, diags, nid, fuel)

  defp parse_primary(:sigil_start, t, i, _ctx, diags, nid, fuel),
    do: parse_sigil(t, i, diags, nid, fuel)

  defp parse_primary(_kind, t, i, _ctx, diags, nid, fuel),
    do: parse_unexpected(t, i, diags, nid, fuel)

  # A sigil is `:sigil_start <part>* :sigil_end`. The CST `:sigil` node keeps the start leaf
  # (carries the name), the parts (fragments / interpolations), and the end leaf (carries the
  # trailing modifiers) — lowering reads name + modifiers from those leaves.
  defp parse_sigil(t, start_i, diags, nid, fuel) do
    {children, j, diags, nid, fuel} =
      sigil_parts(t, start_i + 1, [CST.token(start_i)], diags, nid, fuel)

    span = merge(tok_span(t, start_i), tok_span(t, j - 1))
    {CST.node(:sigil, span, children, :matched, nil), j, diags, nid, fuel}
  end

  defp sigil_parts(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> sigil_part(Tokens.kind(t, i), t, i, acc, diags, nid, fuel)
    end
  end

  defp sigil_part(:string_fragment, t, i, acc, diags, nid, fuel),
    do: sigil_parts(t, i + 1, [CST.token(i) | acc], diags, nid, fuel)

  defp sigil_part(:begin_interpolation, t, i, acc, diags, nid, fuel) do
    {interp, j, diags, nid, fuel} = parse_interp(t, i, diags, nid, fuel)
    sigil_parts(t, j, [interp | acc], diags, nid, fuel)
  end

  defp sigil_part(:sigil_end, _t, i, acc, diags, nid, fuel),
    do: {:lists.reverse([CST.token(i) | acc]), i + 1, diags, nid, fuel}

  defp sigil_part(:error, t, i, acc, diags, nid, fuel) do
    {id, diags, nid} = emit_lex_error(t, i, diags, nid)
    sigil_parts(t, i + 1, [CST.token(i, error: true, diag: id) | acc], diags, nid, fuel)
  end

  defp sigil_part(_other, _t, i, acc, diags, nid, fuel),
    do: {:lists.reverse(acc), i, diags, nid, fuel}

  # --- strings / charlists / interpolation -------------------------------

  # A quoted literal is a linear run `<start> <part>* <end>`, where each part is a fragment leaf
  # or a `:begin_interpolation ... :end_interpolation` interpolation. `node_kind` (`:string` or
  # `:charlist`) is set from the opener; lowering decides the concrete shape from it.
  defp parse_quoted(t, start_i, node_kind, diags, nid, fuel) do
    {parts, j, diags, nid, fuel} = quoted_parts(t, start_i + 1, [], diags, nid, fuel)
    span = merge(tok_span(t, start_i), tok_span(t, j - 1))
    {CST.node(node_kind, span, parts, :matched, nil), j, diags, nid, fuel}
  end

  defp quoted_parts(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> quoted_part(Tokens.kind(t, i), t, i, acc, diags, nid, fuel)
    end
  end

  defp quoted_part(frag, t, i, acc, diags, nid, fuel)
       when frag in [:string_fragment, :charlist_fragment],
       do: quoted_parts(t, i + 1, [CST.token(i) | acc], diags, nid, fuel)

  defp quoted_part(:begin_interpolation, t, i, acc, diags, nid, fuel) do
    {interp, j, diags, nid, fuel} = parse_interp(t, i, diags, nid, fuel)
    quoted_parts(t, j, [interp | acc], diags, nid, fuel)
  end

  defp quoted_part(close, _t, i, acc, diags, nid, fuel)
       when close in [:string_end, :charlist_end],
       do: {:lists.reverse(acc), i + 1, diags, nid, fuel}

  # The lexer's unterminated marker (sole transport, P3): record and keep going; a synthetic end
  # follows it.
  defp quoted_part(:error, t, i, acc, diags, nid, fuel) do
    {id, diags, nid} = emit_lex_error(t, i, diags, nid)
    quoted_parts(t, i + 1, [CST.token(i, error: true, diag: id) | acc], diags, nid, fuel)
  end

  # No closer (truncated stream): stop without consuming.
  defp quoted_part(_other, _t, i, acc, diags, nid, fuel),
    do: {:lists.reverse(acc), i, diags, nid, fuel}

  # `#{ <block> }` — the inner is a statement block (0 → empty, 1 → expr, n → block at lowering).
  defp parse_interp(t, begin_i, diags, nid, fuel) do
    {exprs, j, diags, nid, fuel} = collect_interp(t, begin_i + 1, [], diags, nid, fuel - 1)

    {end_i, diags, nid} =
      if Tokens.kind(t, j) == :end_interpolation do
        {j + 1, diags, nid}
      else
        {_id, diags, nid} =
          Diagnostics.emit(
            diags,
            nid,
            :parser,
            :error,
            :unclosed_interpolation,
            tok_span(t, j),
            %{}
          )

        {j, diags, nid}
      end

    span = merge(tok_span(t, begin_i), tok_span(t, end_i - 1))
    {CST.node(:interp, span, exprs, :matched, nil), end_i, diags, nid, fuel}
  end

  defp collect_interp(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 ->
        {:lists.reverse(acc), i, diags, nid, fuel}

      Tokens.kind(t, i) in [:end_interpolation, :eof] ->
        {:lists.reverse(acc), i, diags, nid, fuel}

      Tokens.kind(t, i) in [:eol, :";"] ->
        collect_interp(t, skip_eoe(t, i), acc, diags, nid, fuel)

      true ->
        collect_interp_one(t, i, acc, diags, nid, fuel)
    end
  end

  defp collect_interp_one(t, i, acc, diags, nid, fuel) do
    {expr, i2, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens, diags, nid, fuel - 1)
    i2 = if i2 > i, do: i2, else: i + 1
    {i3, diags, nid} = end_interp_stmt(t, i2, diags, nid)
    collect_interp(t, i3, [expr | acc], diags, nid, fuel)
  end

  # A statement inside `#{...}` ends at EOE or the closing `}`; anything else is leftover.
  defp end_interp_stmt(t, i, diags, nid) do
    case Tokens.kind(t, i) do
      k when k in [:eol, :";"] ->
        {skip_eoe(t, i), diags, nid}

      k when k in [:end_interpolation, :eof] ->
        {i, diags, nid}

      :error ->
        {_id, diags, nid} = emit_lex_error(t, i, diags, nid)
        {skip_to_interp_eoe(t, i + 1), diags, nid}

      k ->
        {_id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), %{
            kind: k
          })

        {skip_to_interp_eoe(t, i + 1), diags, nid}
    end
  end

  defp skip_to_interp_eoe(t, i) do
    case Tokens.kind(t, i) do
      k when k in [:eol, :";", :end_interpolation, :eof] -> i
      _ -> skip_to_interp_eoe(t, i + 1)
    end
  end

  # --- fn / stab clauses -------------------------------------------------

  # `fn <clause>+ end`, each clause `<patterns> [when guard] -> <body>`.
  defp parse_fn(t, fn_i, diags, nid, fuel) do
    {clauses, j, diags, nid, fuel} = parse_clauses(t, fn_i + 1, [], diags, nid, fuel)

    {CST.node(:fn, merge(tok_span(t, fn_i), tok_span(t, j - 1)), clauses, :matched, nil), j,
     diags, nid, fuel}
  end

  defp parse_clauses(t, i, acc, diags, nid, fuel) do
    i = skip_eoe(t, i)

    cond do
      Tokens.kind(t, i) == :end ->
        # `fn end` (no clauses) is invalid in Elixir.
        {diags, nid} =
          if acc == [] do
            {_id, d, n} =
              Diagnostics.emit(diags, nid, :parser, :error, :missing_clauses, tok_span(t, i), %{})

            {d, n}
          else
            {diags, nid}
          end

        {:lists.reverse(acc), i + 1, diags, nid, fuel}

      Tokens.at_eof?(t, i) ->
        {id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :expected_end, eof_span(t), %{})

        {:lists.reverse([CST.missing(:end, i, diag: id) | acc]), i, diags, nid, fuel}

      true ->
        {clause, j, diags, nid, fuel} = parse_clause(t, i, diags, nid, fuel)
        j = if j > i, do: j, else: i + 1
        parse_clauses(t, j, [clause | acc], diags, nid, fuel)
    end
  end

  defp parse_clause(t, i, diags, nid, fuel) do
    {head, arrow_i, diags, nid, fuel} = parse_clause_head(t, i, diags, nid, fuel)

    if Tokens.kind(t, arrow_i) == :stab_op do
      {body, k, diags, nid, fuel} = parse_clause_body(t, arrow_i + 1, [], diags, nid, fuel)

      {CST.node(:stab, merge(cst_span(t, head), cst_span(t, body)), [head, body], :matched, nil),
       k, diags, nid, fuel}
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_stab, tok_span(t, arrow_i), %{})

      {CST.node(
         :stab,
         cst_span(t, head),
         [head, CST.missing(:->, arrow_i, diag: id)],
         :matched,
         nil
       ), arrow_i, diags, nid, fuel}
    end
  end

  # Returns {head_node, arrow_index, ...}. The head is the patterns (with optional `when` guard);
  # `arrow_index` is where the `->` should be.
  defp parse_clause_head(t, i, diags, nid, fuel) do
    i = skip_eols(t, i)

    if Tokens.kind(t, i) == :stab_op do
      {CST.node(:stab_args, tok_span(t, i), [], :matched, nil), i, diags, nid, fuel}
    else
      {patterns, j, diags, nid, fuel} = head_patterns(t, i, [], diags, nid, fuel)
      jj = skip_eols(t, j)
      clause_head_guard(t, jj, patterns, diags, nid, fuel)
    end
  end

  defp clause_head_guard(t, i, patterns, diags, nid, fuel) do
    if Tokens.kind(t, i) == :when_op do
      {guard, j, diags, nid, fuel} =
        parse_expr(t, skip_eols(t, i + 1), 0, :matched, diags, nid, fuel - 1)

      when_node =
        CST.node(
          :stab_when,
          head_span(t, patterns, guard),
          Enum.concat(patterns, [guard]),
          :matched,
          nil
        )

      {CST.node(:stab_args, cst_span(t, when_node), [when_node], :matched, nil), skip_eols(t, j),
       diags, nid, fuel}
    else
      {CST.node(:stab_args, head_span(t, patterns, nil), patterns, :matched, nil), i, diags, nid,
       fuel}
    end
  end

  # Comma-separated patterns, each parsed stopping before `when` (50) and `->` (not infix).
  defp head_patterns(t, i, acc, diags, nid, fuel) do
    i = skip_eols(t, i)

    {pat, j, diags, nid, fuel} =
      parse_expr(t, i, @clause_pattern_bp, :matched, diags, nid, fuel - 1)

    j = if j > i, do: j, else: i + 1
    jj = skip_eols(t, j)

    if Tokens.kind(t, jj) == :"," do
      head_patterns(t, jj + 1, [pat | acc], diags, nid, fuel)
    else
      {:lists.reverse([pat | acc]), j, diags, nid, fuel}
    end
  end

  # Clause body: statements until `end`, EOF, or the next clause head (a `->` on the line ahead).
  defp parse_clause_body(t, i, acc, diags, nid, fuel) do
    i = skip_eoe(t, i)

    cond do
      at_section_end?(t, i) or clause_head_ahead?(t, i, 0) ->
        {CST.node(
           :stab_body,
           list_span(t, :lists.reverse(acc)),
           :lists.reverse(acc),
           :matched,
           nil
         ), i, diags, nid, fuel}

      true ->
        {stmt, j, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens, diags, nid, fuel - 1)
        j = if j > i, do: j, else: i + 1
        {j, diags, nid} = body_boundary(t, j, diags, nid)
        parse_clause_body(t, j, [stmt | acc], diags, nid, fuel)
    end
  end

  # After a body statement, the cursor must be at a boundary (EOE / `end` / block label / EOF /
  # next clause head). A same-line leftover token (`fn -> 1 2 end`) is an error; skip to a boundary.
  defp body_boundary(t, i, diags, nid) do
    cond do
      at_section_end?(t, i) or Tokens.kind(t, i) in [:eol, :";"] or clause_head_ahead?(t, i, 0) ->
        {i, diags, nid}

      true ->
        {_id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), %{
            kind: Tokens.kind(t, i)
          })

        {skip_to_body_boundary(t, i + 1), diags, nid}
    end
  end

  defp skip_to_body_boundary(t, i) do
    if at_section_end?(t, i) or Tokens.kind(t, i) in [:eol, :";"] do
      i
    else
      skip_to_body_boundary(t, i + 1)
    end
  end

  # A clause/section body ends at `end`, a block label (`else`/`catch`/`rescue`/`after`), or EOF.
  defp at_section_end?(t, i),
    do: Tokens.kind(t, i) in [:end, :block_label] or Tokens.at_eof?(t, i)

  # Is the upcoming line a clause head? True if a depth-0 `->` precedes the next EOE / `end` / EOF.
  defp clause_head_ahead?(t, i, depth) do
    case Tokens.kind(t, i) do
      :eof -> false
      :stab_op when depth == 0 -> true
      :end when depth == 0 -> false
      # A block label ends the current section, so a `->` beyond it belongs to a later section.
      :block_label when depth == 0 -> false
      k when depth == 0 and k in [:eol, :";"] -> false
      k when k in [:"(", :"[", :"{", :"<<", :fn, :do] -> clause_head_ahead?(t, i + 1, depth + 1)
      k when k in [:")", :"]", :"}", :">>", :end] -> clause_head_ahead?(t, i + 1, depth - 1)
      _ -> clause_head_ahead?(t, i + 1, depth)
    end
  end

  # `head_patterns` always returns at least one pattern, so `patterns` is non-empty here.
  defp head_span(t, patterns, nil), do: list_span(t, patterns)
  defp head_span(t, patterns, guard), do: merge(cst_span(t, hd(patterns)), cst_span(t, guard))

  # --- do/end blocks -----------------------------------------------------

  # `do <section>+ end`, where the first section is `do` and later sections are block labels
  # (`else`/`catch`/`rescue`/`after`). Each section body is statements or stab clauses.
  defp parse_do_block(t, do_i, diags, nid, fuel) do
    {sections, j, diags, nid, fuel} = parse_sections(t, do_i, [], diags, nid, fuel)

    {CST.node(:do_block, merge(tok_span(t, do_i), tok_span(t, j - 1)), sections, :matched, nil),
     j, diags, nid, fuel}
  end

  defp parse_sections(t, i, acc, diags, nid, fuel) do
    label = CST.token(i)
    {body, j, diags, nid, fuel} = parse_section_body(t, i + 1, diags, nid, fuel)

    section =
      CST.node(
        :do_section,
        merge(tok_span(t, i), cst_span(t, body)),
        [label, body],
        :matched,
        nil
      )

    cond do
      Tokens.kind(t, j) == :block_label ->
        parse_sections(t, j, [section | acc], diags, nid, fuel)

      Tokens.kind(t, j) == :end ->
        {:lists.reverse([section | acc]), j + 1, diags, nid, fuel}

      true ->
        {id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :expected_end, tok_span(t, j), %{})

        {:lists.reverse([CST.missing(:end, j, diag: id), section | acc]), j, diags, nid, fuel}
    end
  end

  # A section body is stab clauses (if a `->` heads the line) or a statement sequence.
  defp parse_section_body(t, i, diags, nid, fuel) do
    i = skip_eoe(t, i)

    if not at_section_end?(t, i) and clause_head_ahead?(t, i, 0) do
      {clauses, j, diags, nid, fuel} = parse_block_clauses(t, i, [], diags, nid, fuel)
      {CST.node(:do_clauses, list_span(t, clauses), clauses, :matched, nil), j, diags, nid, fuel}
    else
      {stmts, j, diags, nid, fuel} = parse_block_stmts(t, i, [], diags, nid, fuel)
      {CST.node(:do_body, list_span(t, stmts), stmts, :matched, nil), j, diags, nid, fuel}
    end
  end

  defp parse_block_clauses(t, i, acc, diags, nid, fuel) do
    i = skip_eoe(t, i)

    if at_section_end?(t, i) do
      {:lists.reverse(acc), i, diags, nid, fuel}
    else
      {clause, j, diags, nid, fuel} = parse_clause(t, i, diags, nid, fuel)
      j = if j > i, do: j, else: i + 1
      parse_block_clauses(t, j, [clause | acc], diags, nid, fuel)
    end
  end

  defp parse_block_stmts(t, i, acc, diags, nid, fuel) do
    i = skip_eoe(t, i)

    if at_section_end?(t, i) do
      {:lists.reverse(acc), i, diags, nid, fuel}
    else
      {stmt, j, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens, diags, nid, fuel - 1)
      j = if j > i, do: j, else: i + 1
      {j, diags, nid} = body_boundary(t, j, diags, nid)
      parse_block_stmts(t, j, [stmt | acc], diags, nid, fuel)
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
        {entries, j, diags, nid, fuel} = map_entries(t, i, [], false, diags, nid, fuel)

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
          map_entries(t, skip_eols(t, jj + 1), [], false, diags, nid, fuel)

        {diags, nid} =
          if entries == [] do
            {_id, d, n} =
              Diagnostics.emit(
                diags,
                nid,
                :parser,
                :error,
                :empty_map_update,
                tok_span(t, jj),
                %{}
              )

            {d, n}
          else
            {diags, nid}
          end

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

        {entries, m, diags, nid, fuel} = map_rest(t, k, [first], false, diags, nid, fuel)

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

  # After an entry: finish at `}` (trailing comma allowed), continue at `,`, else unterminated.
  defp map_rest(t, i, acc, seen_kw, diags, nid, fuel) do
    i2 = skip_eols(t, i)

    cond do
      Tokens.kind(t, i2) == :"}" ->
        {:lists.reverse(acc), i2 + 1, diags, nid, fuel}

      Tokens.kind(t, i2) == :"," ->
        map_entries(t, skip_eols(t, i2 + 1), acc, seen_kw, diags, nid, fuel)

      true ->
        map_unterminated(t, i2, acc, diags, nid, fuel)
    end
  end

  # Comma-separated map entries (assoc or keyword pair) until `}`; keyword pairs must come last.
  defp map_entries(t, i, acc, seen_kw, diags, nid, fuel) do
    i = skip_eols(t, i)

    if Tokens.kind(t, i) == :"}" do
      {:lists.reverse(acc), i + 1, diags, nid, fuel}
    else
      {entry, j, diags, nid, fuel} = parse_map_entry(t, i, diags, nid, fuel)
      is_kw = CST.node_kind(entry) == :kw_pair
      {diags, nid} = check_kw_last(seen_kw, is_kw, t, entry, diags, nid)
      map_rest(t, j, [entry | acc], seen_kw or is_kw, diags, nid, fuel)
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

  # `[ ... ]` / `{ ... }` / `<< ... >>`: a comma-separated sequence; `kind` is also the seq `mode`.
  defp parse_container(t, open, close, kind, diags, nid, fuel) do
    {elems, j, diags, nid, fuel} = parse_seq(t, open + 1, close, kind, diags, nid, fuel)

    {CST.node(kind, merge(tok_span(t, open), tok_span(t, j - 1)), elems, :matched, nil), j, diags,
     nid, fuel}
  end

  # Comma-separated elements up to `close`. `mode` (`:list | :tuple | :bitstring | :call`) controls
  # the permissive-grammar edges: a trailing comma is allowed everywhere except calls; keyword
  # pairs are allowed only in lists and calls; and keyword pairs must come last.
  defp parse_seq(t, i, close, mode, diags, nid, fuel) do
    i = skip_eols(t, i)

    if Tokens.kind(t, i) == close do
      {[], i + 1, diags, nid, fuel}
    else
      seq_elems(t, i, [], false, close, mode, diags, nid, fuel)
    end
  end

  defp seq_elems(t, i, acc, seen_kw, close, mode, diags, nid, fuel) do
    {el, i, is_kw, diags, nid, fuel} = parse_element(t, i, mode, diags, nid, fuel)
    {diags, nid} = check_kw_last(seen_kw, is_kw, t, el, diags, nid)
    acc = [el | acc]
    i2 = skip_eols(t, i)

    cond do
      Tokens.kind(t, i2) == close ->
        {:lists.reverse(acc), i2 + 1, diags, nid, fuel}

      Tokens.kind(t, i2) == :"," ->
        {diags, nid} = check_np_comma(mode, el, t, i2, diags, nid)
        seq_after_comma(t, i2, acc, seen_kw or is_kw, close, mode, diags, nid, fuel)

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

        {:lists.reverse([CST.missing(close, i2, diag: id) | acc]), i2, diags, nid, fuel}
    end
  end

  # After a comma: a trailing comma before `close` is allowed in lists/tuples/bitstrings, but is
  # an error in calls (`f(1,)`). Otherwise parse the next element.
  defp seq_after_comma(t, comma_i, acc, seen_kw, close, mode, diags, nid, fuel) do
    nxt = skip_eols(t, comma_i + 1)

    cond do
      Tokens.kind(t, nxt) != close ->
        seq_elems(t, nxt, acc, seen_kw, close, mode, diags, nid, fuel)

      mode != :call ->
        {:lists.reverse(acc), nxt + 1, diags, nid, fuel}

      true ->
        {id, diags, nid} =
          Diagnostics.emit(
            diags,
            nid,
            :parser,
            :error,
            :unexpected_trailing_comma,
            tok_span(t, comma_i),
            %{}
          )

        {:lists.reverse([CST.missing(close, nxt, diag: id) | acc]), nxt + 1, diags, nid, fuel}
    end
  end

  # An element is a `key: value` keyword pair (only in lists/calls) or an expression. Returns the
  # node, the next index, and whether it was a keyword pair (for keyword-last enforcement).
  defp parse_element(t, i, mode, diags, nid, fuel) do
    # Call args are a `:no_parens` context (so `f(g a, b)` makes `g` absorb the commas, arity 1);
    # list/tuple/bitstring elements are `:matched` (a no-parens element may take only one arg).
    ctx = if mode == :call, do: :no_parens, else: :matched

    if Tokens.kind(t, i) == :kw_identifier do
      key = CST.token(i)
      {val, j, diags, nid, fuel} = parse_expr(t, i + 1, 0, ctx, diags, nid, fuel - 1)

      node =
        CST.node(:kw_pair, merge(tok_span(t, i), cst_span(t, val)), [key, val], :matched, nil)

      {diags, nid} = check_kw_allowed(mode, t, i, diags, nid)
      {node, j, true, diags, nid, fuel}
    else
      {expr, j, diags, nid, fuel} = parse_expr(t, i, 0, ctx, diags, nid, fuel)
      {expr, j, false, diags, nid, fuel}
    end
  end

  # A no-parens call as a non-last container element (`[f a, b]`) is ambiguous — Elixir requires
  # parens. (In call args the comma is absorbed by the inner call, so this only fires in
  # list/tuple/bitstring.)
  defp check_np_comma(mode, el, t, comma_i, diags, nid) when mode != :call do
    if CST.category(el) == :no_parens do
      {_id, diags, nid} =
        Diagnostics.emit(
          diags,
          nid,
          :parser,
          :error,
          :ambiguous_no_parens,
          tok_span(t, comma_i),
          %{}
        )

      {diags, nid}
    else
      {diags, nid}
    end
  end

  defp check_np_comma(_mode, _el, _t, _comma_i, diags, nid), do: {diags, nid}

  # A non-keyword element after a keyword pair: keyword lists must come last.
  defp check_kw_last(true, false, t, el, diags, nid) do
    {_id, diags, nid} =
      Diagnostics.emit(
        diags,
        nid,
        :parser,
        :error,
        :keyword_not_last,
        cst_span(t, el) || {1, 1, 1, 1},
        %{}
      )

    {diags, nid}
  end

  defp check_kw_last(_seen, _is_kw, _t, _el, diags, nid), do: {diags, nid}

  # Keyword pairs are not allowed inside tuples / bitstrings.
  defp check_kw_allowed(mode, _t, _i, diags, nid) when mode in [:list, :call], do: {diags, nid}

  defp check_kw_allowed(mode, t, i, diags, nid) do
    {_id, diags, nid} =
      Diagnostics.emit(diags, nid, :parser, :error, :keyword_not_allowed, tok_span(t, i), %{
        in: mode
      })

    {diags, nid}
  end

  defp parse_unary(t, i, prefix_bp, _ctx, diags, nid, fuel) do
    op_leaf = CST.token(i)
    operand_start = skip_eols(t, i + 1)
    # A unary operand is `matched_expr` (no-parens here takes a single argument).
    {operand, k, diags, nid, fuel} =
      parse_expr(t, operand_start, prefix_bp, :matched, diags, nid, fuel - 1)

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
