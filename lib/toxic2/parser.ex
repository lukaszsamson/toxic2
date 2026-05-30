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

  Not yet handled (later phases): stabs/blocks (`fn`, `do`/`end`, `case`…), strings/sigils,
  `&` capture, multi-statement parens. Encountering those yields error/leaf nodes rather than
  crashing.
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
    led(t, i, lhs, min_bp, ctx, diags, nid, fuel)
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
        if ctx == :no_parens,
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
      {val, j, diags, nid, fuel} = parse_expr(t, i + 1, 0, :no_parens, diags, nid, fuel - 1)

      node =
        CST.node(:kw_pair, merge(tok_span(t, i), cst_span(t, val)), [key, val], :matched, nil)

      {node, j, true, diags, nid, fuel}
    else
      {expr, j, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens, diags, nid, fuel - 1)
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
      :unary_op,
      :kw_identifier
    ]
  end

  # Postfix operations bind tightest (yecc 310): a paren call `f(...)` (adjacent `(`), and dot
  # forms `a.b` / `a.b(...)` / `a.(...)` / `Foo.Bar` (alias chain).
  defp postfix(t, i, lhs, ctx, diags, nid, fuel) do
    cond do
      paren_call?(t, lhs, i) ->
        {args, j, diags, nid, fuel} = parse_seq(t, i + 1, :")", :call, diags, nid, fuel)

        call =
          CST.node(
            :call,
            merge(cst_span(t, lhs), tok_span(t, j - 1)),
            [lhs | args],
            :matched,
            nil
          )

        postfix(t, j, call, ctx, diags, nid, fuel)

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
        {args, k, diags, nid, fuel} = parse_seq(t, j + 1, :")", :call, diags, nid, fuel)

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
      {args, k, diags, nid, fuel} = parse_seq(t, name_i + 2, :")", :call, diags, nid, fuel)

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
