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

  Also: multi-statement parens `(a; b)` => block; maps/structs with bare-expression entries
  (`%{x}`, `%Foo{x}`); struct bases beyond aliases (`%mod{}`, `%nil{}`, spaced `% (){}`);
  dot-quoted remote calls (`a."foo"`); quoted keyword keys (`"foo": 1`); operator-named keyword
  keys (`<<>>: 1`, `+: 1`); unicode identifiers/atoms (`café`, `:αβγ` — the lexer carries the NFC
  name); a no-parens-call keyword value must be last (`f(a: g b, c)` rejected); `&` capture;
  `..//` step range.
  """

  alias Toxic2.{CST, Diagnostics, LexError, Precedence, Tokens}

  # Narrow inlining of the tiny LOCAL span builders on the hot node-construction path (A/B-measured).
  @compile {:inline, merge: 2, merge_tt: 3, merge_ct: 3, merge_tc: 3}

  # Parser-LOCAL token-view reads. `Tokens.kind/value/token/at_eof?` are cross-module, so a callee-
  # module `@compile :inline` can't reach them — and `Tokens.kind/2` alone was ~12 % of ALL calls.
  # These read the view tuple `{toks, size, _cont}` directly and inline into the hot dispatch.
  @compile {:inline, tk: 2, tv: 2, tt: 2, t_eof?: 2}

  defp tk({toks, size, _cont}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 0)
  defp tk(_t, _i), do: :eof

  defp tv({toks, size, _cont}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 5)
  defp tv(_t, _i), do: nil

  defp tt({toks, size, _cont}, i) when i >= 0 and i < size, do: elem(toks, i)
  defp tt(_t, _i), do: :eof

  defp t_eof?({_toks, size, _cont}, i), do: i >= size

  # Parser-LOCAL CST reads + the two hottest tiny remote helpers (`Tokens.span/2` was ~97k calls,
  # `CST.token/1` ~79k — both trivial bodies). Constructors that do real work (`CST.node`,
  # `CST.missing`) stay remote.
  @compile {:inline, tspan: 2, ctoken: 1, ctag: 1, ckind: 1, cchildren: 1, ctoki: 1, cspan: 1}

  defp tspan(t, i) do
    case tt(t, i) do
      :eof -> nil
      tok -> {elem(tok, 1), elem(tok, 2), elem(tok, 3), elem(tok, 4)}
    end
  end

  defp ctoken(index), do: {:token, index, 0, []}

  defp ctag(cst), do: elem(cst, 0)

  defp ckind({:node, kind, _sp, _ch, _f, _d}), do: kind
  defp ckind({:missing, expected, _ai, _f, _d}), do: expected
  defp ckind({:token, _i, _f, _d}), do: :token

  defp cchildren({:node, _k, _sp, ch, _f, _d}), do: ch
  defp cchildren(_leaf), do: []

  defp ctoki({:token, i, _f, _d}), do: i
  defp ctoki(_cst), do: nil

  defp cspan({:node, _k, sp, _ch, _f, _d}), do: sp
  defp cspan(_leaf), do: nil

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
    {view, lex_notices} = Tokens.from_source(source, opts)
    {cst, parser_diags} = parse_tokens(view)
    {lex_diags, _nid} = Diagnostics.number(lex_notices, Diagnostics.next_id(parser_diags))
    {cst, Diagnostics.merge_sorted([lex_diags, parser_diags])}
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
      t_eof?(t, i) -> {:lists.reverse(acc), i, diags, nid, fuel}
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
    case tk(t, i) do
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

        # Don't discard the leftover tokens — leave the cursor in place so the caller's collect
        # loop re-parses them as the next statement (`1 2` recovers as two statements). The
        # leftover may carry meaning (an IDE cursor marker, a half-typed expression).
        {i, diags, nid}
    end
  end

  defp skip_to_eoe(t, i) do
    case tk(t, i) do
      k when k in [:eol, :";"] -> skip_eoe(t, i)
      :eof -> i
      _ -> skip_to_eoe(t, i + 1)
    end
  end

  # --- Pratt ------------------------------------------------------------

  # `parse_expr` is the hottest path. Each of the three post-prefix combinators (`postfix`,
  # `maybe_no_parens`, `maybe_do_block`) returns a fresh `{lhs, i, diags, nid, fuel}` state tuple
  # EVEN WHEN IT DOES NOTHING — tprof showed those no-op tuples are a big share of parser allocation.
  # `postfix` loops internally so we keep it unguarded, but the other two are gated by their exact
  # entry predicate and only CALLED when they'll do work; otherwise we tail-call onward with the
  # variables unchanged, allocating nothing. Behaviour-preserving (the guards equal the combinators'
  # own `if`/`cond` conditions).
  defp parse_expr(t, i, min_bp, ctx, diags, nid, fuel) do
    {lhs, i, diags, nid, fuel} = parse_prefix(t, i, ctx, diags, nid, fuel)
    # `postfix` loops internally and applies often (every paren call), so guarding its entry only
    # double-evaluates its predicate — left unguarded. The next two combinators ARE worth gating.
    {lhs, i, diags, nid, fuel} = postfix(t, i, lhs, ctx, diags, nid, fuel)
    parse_expr_np(t, i, lhs, min_bp, ctx, diags, nid, fuel)
  end

  defp parse_expr_np(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    if np_callee?(lhs, t) and np_arg_start?(t, lhs, i) do
      {lhs, i, diags, nid, fuel} = maybe_no_parens(t, i, lhs, ctx, diags, nid, fuel)
      parse_expr_do(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    else
      parse_expr_do(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    end
  end

  defp parse_expr_do(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    if ctx != :no_parens_arg and do_block_ahead?(t, i) do
      {lhs, i, diags, nid, fuel} = maybe_do_block(t, i, lhs, ctx, diags, nid, fuel)
      led(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    else
      led(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    end
  end

  defp do_block_ahead?(t, i),
    do: tk(t, i) == :do or tk(t, skip_eols(t, i)) == :do

  # `<call> do ... end`: the do-block attaches to the call as a trailing `[do: ..., else: ...]`
  # keyword list. Suppressed in `:no_parens_arg` so the do attaches to the OUTER call:
  # `foo bar do end` => `foo(bar, do: ...)`, not `foo(bar(do: ...))`. The `do` may sit on the NEXT
  # line after a multi-line head (`def f(x) when g\ndo … end`), but only for a call that already
  # has args (a node) — a bare callee on its own line does not take a newline `do` (`foo\ndo` is
  # invalid), so a same-line `do` is needed there.
  defp maybe_do_block(t, i, lhs, ctx, diags, nid, fuel) do
    cond do
      ctx == :no_parens_arg ->
        {lhs, i, diags, nid, fuel}

      tk(t, i) == :do and do_attachable?(lhs, t) ->
        attach_do_block(t, i, lhs, diags, nid, fuel)

      tk(t, skip_eols(t, i)) == :do and do_attachable_node?(lhs) ->
        attach_do_block(t, skip_eols(t, i), lhs, diags, nid, fuel)

      true ->
        {lhs, i, diags, nid, fuel}
    end
  end

  defp attach_do_block(t, do_i, lhs, diags, nid, fuel) do
    {db, j, diags, nid, fuel} = parse_do_block(t, do_i, diags, nid, fuel)
    {attach_do(t, lhs, db, j), j, diags, nid, fuel}
  end

  defp do_attachable?({:token, idx, _f, _d}, t), do: tk(t, idx) == :identifier
  defp do_attachable?(lhs, _t), do: do_attachable_node?(lhs)

  # A call NODE (has args / parens) — the only form that takes a `do` on a following line.
  defp do_attachable_node?({:node, k, _sp, _ch, _f, _d}),
    do: k in [:call, :np_call, :remote_call, :anon_call]

  defp do_attachable_node?(_lhs), do: false

  defp attach_do(t, lhs, db, end_i) do
    span = merge_ct(t, lhs, end_i - 1)

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

      # `:matched` normally caps a no-parens call at one arg, but a trailing `do` block makes a
      # multi-arg call unambiguous even there (`[for x <- a, y <- b do … end]`), so collect many.
      {args, k, diags, nid, fuel} =
        if ctx in [:no_parens, :no_parens_arg] or np_call_has_do?(t, j, 0),
          do: np_more_args(t, j, [arg], is_kw, diags, nid, fuel),
          else: {[arg], j, diags, nid, fuel}

      {build_np_call(t, lhs, args, k), k, diags, nid, fuel}
    else
      {lhs, i, diags, nid, fuel}
    end
  end

  # Is this no-parens call (args starting at `i`) terminated by a depth-0 `do` block before any
  # closer / end-of-expression? Such a call may carry many args even in a `:matched` position.
  defp np_call_has_do?(t, i, depth), do: np_call_has_do?(t, i, depth, :eol)

  defp np_call_has_do?(t, i, depth, prev) do
    k = tk(t, i)

    cond do
      # A reserved word as a dot member (`a.do`, `a.end`) is a name, not a block delimiter.
      prev == :dot and k in [:end, :do, :fn, :block_label] -> np_call_has_do?(t, i + 1, depth, k)
      k == :do and depth == 0 -> true
      k == :eof -> false
      depth == 0 and k in [:eol, :";", :")", :"]", :"}", :">>", :end, :stab_op] -> false
      true -> np_call_has_do?(t, i + 1, depth + depth_delta(k), k)
    end
  end

  # Additional comma-separated args. A newline is allowed after the comma (`f a,\n b`), and
  # keyword pairs must come last.
  defp np_more_args(t, i, args, seen_kw, diags, nid, fuel) do
    if tk(t, i) == :"," do
      {arg, j, is_kw, diags, nid, fuel} = parse_np_arg(t, skip_eols(t, i + 1), diags, nid, fuel)
      {diags, nid} = check_kw_last(seen_kw, is_kw, t, arg, diags, nid)
      {diags, nid} = check_no_parens_strict(t, arg, diags, nid)
      np_more_args(t, j, [arg | args], seen_kw or is_kw, diags, nid, fuel)
    else
      {:lists.reverse(args), i, diags, nid, fuel}
    end
  end

  # A non-first argument of a no-parens call may not itself be a no-parens MANY / ambiguous-one call
  # (`foo a, bar b, c` is ambiguous between `foo(a, bar(b, c))` and `foo(a, bar(b), c)`). Elixir's
  # grammar rejects it via `error_no_parens_many_strict`; parentheses are required. We diagnose it
  # (tolerant: the best-effort AST still nests the inner call).
  defp check_no_parens_strict(t, arg, diags, nid) do
    if no_parens_expr?(arg) do
      {_id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :ambiguous_no_parens, cst_span(t, arg), %{})

      {diags, nid}
    else
      {diags, nid}
    end
  end

  # A `no_parens_expr` in the grammar: a no-parens call with several args (`a, b` → no_parens_many)
  # or a single argument that is itself a no-parens expr (`g a, b` → no_parens_one_ambig). A plain
  # single-arg call (`f a`) is a `matched_expr`, which is fine.
  defp no_parens_expr?(arg) do
    kind = ctag(arg) == :node and ckind(arg)

    if kind in [:np_call, :remote_call] and CST.category(arg) == :no_parens do
      args = np_call_args(kind, cchildren(arg))

      # a trailing run of keyword pairs is ONE argument (`f a: 1, b: 2` is `call_args_no_parens_kw`,
      # a single kw-list arg), so it is NOT `no_parens_many`; only ≥2 positional groups are.
      {kws, positional} = Enum.split_with(args, &kw_pair_node?/1)
      groups = length(positional) + if kws == [], do: 0, else: 1

      cond do
        positional != [] and groups >= 2 -> true
        match?([_], positional) and kws == [] -> no_parens_expr?(hd(positional))
        true -> false
      end
    else
      false
    end
  end

  defp np_call_args(:np_call, [_callee | args]), do: args
  defp np_call_args(:remote_call, [_base, _name | args]), do: args
  defp np_call_args(_kind, _children), do: []

  # `a |> b c` — piping into a no-parens CALL is ambiguous (does `c` belong to `b` or the pipe?);
  # Elixir warns. `a |> b` (no call) and `a |> b(c)` (parens) are fine. Fires for any arrow op.
  defp maybe_ambiguous_pipe(t, i, rhs, diags, nid) do
    if tk(t, i) == :arrow_op and np_call?(rhs) do
      {_id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :warning, :ambiguous_pipe, tspan(t, i), %{})

      {diags, nid}
    else
      {diags, nid}
    end
  end

  defp np_call?(node) do
    kind = ctag(node) == :node and ckind(node)

    kind in [:np_call, :remote_call] and CST.category(node) == :no_parens and
      np_call_args(kind, cchildren(node)) != []
  end

  # `foo do end <- bar baz, x` — an expression ending in a `do…end` block, followed by an operator
  # whose RHS is a multi-arg no-parens call, is ambiguous; Elixir warns to add parentheses. The RHS
  # must be a `no_parens_expr` (so `foo do end <- bar baz` with a single arg does NOT warn), and the
  # LHS must carry a do-block (so `fn -> x end <- …`, which is not a do-block call, is excluded).
  defp maybe_no_parens_after_do(t, i, lhs, rhs, diags, nid) do
    if has_do_block?(lhs) and no_parens_expr?(rhs) do
      {_id, diags, nid} =
        Diagnostics.emit(
          diags,
          nid,
          :parser,
          :warning,
          :no_parens_after_do_op,
          tspan(t, i),
          %{}
        )

      {diags, nid}
    else
      {diags, nid}
    end
  end

  # Build the no-parens call, marking it `:no_parens` (so a container can detect the ambiguous
  # `[f a, b]`). A plain identifier callee becomes `:np_call`; a bare remote (`a.b`) gains args.
  defp build_np_call(t, lhs, args, end_i) do
    span = merge_ct(t, lhs, end_i - 1)

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
    if tk(t, i) == :kw_identifier do
      key = ctoken(i)
      # A newline is allowed after `key:` before the value (`[a:\n1]`, `f(a:\n1)`).
      {val, j, diags, nid, fuel} =
        parse_expr(t, skip_eols(t, i + 1), 0, :no_parens_arg, diags, nid, fuel - 1)

      node =
        CST.node(:kw_pair, merge_tc(t, i, val), [key, val], :matched, nil)

      {node, j, true, diags, nid, fuel}
    else
      {expr, j, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens_arg, diags, nid, fuel - 1)

      if quoted_kw?(t, j) do
        {node, k, diags, nid, fuel} =
          parse_quoted_kw(t, expr, j, :no_parens_arg, diags, nid, fuel)

        {node, k, true, diags, nid, fuel}
      else
        {expr, j, false, diags, nid, fuel}
      end
    end
  end

  # A no-parens callee is a bare identifier, or a bare remote (`a.b` with no args yet).
  defp np_callee?({:token, idx, _f, _d}, t), do: tk(t, idx) == :identifier
  defp np_callee?({:node, :remote_call, _sp, [_base, _name], _f, _d}, _t), do: true
  defp np_callee?(_lhs, _t), do: false

  # Can a no-parens argument start at `i`, given the callee `lhs`? Generally requires a space after
  # the callee (same line): `f -1` is a call (op adjacent to operand), `f - 1` is subtraction. A
  # string/charlist/heredoc is unambiguous, so it may be ADJACENT — `foo"bar"` => `foo("bar")`,
  # `Mix.shell().info"""…"""` => the heredoc is the argument.
  defp np_arg_start?(t, lhs, i) do
    case {cst_span(t, lhs), tspan(t, i)} do
      {{_, _, el, ec}, {sl, sc, _, _}} when el == sl and ec <= sc ->
        case tk(t, i) do
          k when k in [:string_start, :charlist_start] -> true
          _ when ec == sc -> false
          k -> np_arg_kind?(t, i, k)
        end

      # The arg sits on a LATER line than the callee yet the cursor reached it with no `:eol` token
      # between — only a `\`-newline line continuation does that, which joins them into one logical
      # line: `@x \⏎ File.foo()` => `x(File.foo())`.
      #
      # A leading `+`/`-` is the case Elixir 1.20 split: a SPACE-preceded `\`-newline is whitespace,
      # so `foo \⏎+1` => `foo(+1)` (like `foo +1`); the no-space `foo\⏎+1` stays `foo + 1`. The
      # lexer records the space-preceded continuation, so `cont_before?/2` distinguishes them: a
      # `:dual_op` is an argument start only across a space-preceded continuation (and only when its
      # operand is adjacent, just like the same-line case).
      {{_, _, el, _ec}, {sl, _sc, _, _}} when el < sl ->
        case tk(t, i) do
          :dual_op -> Tokens.cont_before?(t, i) and np_arg_kind?(t, i, :dual_op)
          :unary_op -> not not_in?(t, i)
          k -> np_first_kind?(k)
        end

      _ ->
        false
    end
  end

  defp np_arg_kind?(t, i, :dual_op),
    do: Tokens.adjacent?(t, i, i + 1) and np_first_kind?(tk(t, i + 1))

  # `not` starts an arg (`f not x`) unless it is the `not in` operator (`a not in b`).
  defp np_arg_kind?(t, i, :unary_op), do: not not_in?(t, i)
  defp np_arg_kind?(_t, _i, k), do: np_first_kind?(k)

  # `not in` is only fused when both words are on the same line — upstream's tokenizer rewrites
  # `not` + `in` to a single `in_op` only without an intervening newline; `a not\nin b` is a syntax
  # error (recovered tolerantly downstream).
  defp not_in?(t, i) do
    tk(t, i) == :unary_op and tv(t, i) == :not and tk(t, i + 1) == :in_op
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
      :kw_identifier,
      :string_start,
      :charlist_start,
      :sigil_start,
      :quoted_atom,
      :fn
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
            merge_ct(t, lhs, j - 1),
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

  defp dot_continuation?(t, i), do: tk(t, skip_eols(t, i)) == :dot

  # Token kinds that may name a remote-call member after a `.` (besides identifier/alias/quoted):
  # the reserved words (`true`/`false`/`nil`, `do`/`end`/`fn`, block labels, `when`/`and`/`or`/
  # `in`/`not`) and all operators EXCEPT `->`/`=>`/`//` and the structural `.`/`..`/`...`.
  @dot_member_kinds [
    :literal,
    :do,
    :end,
    :fn,
    :block_label,
    :type_op,
    :pipe_op,
    :match_op,
    :capture_op,
    :at_op,
    :arrow_op,
    :unary_op,
    :in_match_op,
    :in_op,
    :when_op,
    :power_op,
    :and_op,
    :or_op,
    :concat_op,
    :comp_op,
    :rel_op,
    :mult_op,
    :dual_op,
    :xor_op
  ]

  # `a[b]` access when `[` is adjacent to the primary (spaced `a [b]` is a no-parens call, phase 8).
  defp access?(t, lhs, i) do
    tk(t, i) == :"[" and cst_ends_at_token?(t, lhs, i)
  end

  defp adjacent_after?({_, _, el, ec}, {sl, sc, _, _}), do: el == sl and ec == sc
  defp adjacent_after?(_, _), do: false

  # True iff `cst` ends exactly where token `i` begins (no gap). Reads positions with `elem` so
  # neither side builds a transient span 4-tuple — this runs in `postfix` for every `(`/`[`.
  defp cst_ends_at_token?(t, cst, i) do
    case Tokens.token(t, i) do
      :eof -> false
      tok -> cst_ends_at?(t, cst, elem(tok, 1), elem(tok, 2))
    end
  end

  defp cst_ends_at?(t, cst, sl, sc) do
    case ctag(cst) do
      :token ->
        tok = Tokens.token(t, ctoki(cst))
        elem(tok, 3) == sl and elem(tok, 4) == sc

      :node ->
        {_, _, el, ec} = cspan(cst)
        el == sl and ec == sc

      :missing ->
        {_, _, el, ec} = anchor_span(t, CST.anchor_index(cst))
        el == sl and ec == sc
    end
  end

  # `a[b]`. A keyword-list index (`a[k: 1, j: 2]`) is the index `[k: 1, j: 2]`: parse the bracket
  # as a list sequence and use that list node as the single index.
  defp access(t, open, lhs, ctx, diags, nid, fuel) do
    # `a[foo: 1]` / `a['foo': 1]` — a keyword (bare or quoted key) index is a keyword-list arg.
    if kw_data_start?(t, skip_eols(t, open + 1)) do
      {elems, j, diags, nid, fuel} = parse_seq(t, open + 1, :"]", :list, diags, nid, fuel)
      idx = CST.node(:list, merge_tt(t, open, j - 1), elems, :matched, nil)

      node =
        CST.node(:access, merge_ct(t, lhs, j - 1), [lhs, idx], :matched, nil)

      postfix(t, j, node, ctx, diags, nid, fuel)
    else
      access_index(t, open, lhs, ctx, diags, nid, fuel)
    end
  end

  defp access_index(t, open, lhs, ctx, diags, nid, fuel) do
    # A newline after `[` is allowed before the index (`foo[\n:bar]`).
    {idx, j, diags, nid, fuel} =
      parse_expr(t, skip_eols(t, open + 1), 0, :matched, diags, nid, fuel - 1)

    # A single trailing comma is allowed (`foo[1,]`); `foo[a, b]` (a real second index) is not.
    jj0 = skip_eols(t, j)

    jj =
      if tk(t, jj0) == :"," and tk(t, skip_eols(t, jj0 + 1)) == :"]",
        do: skip_eols(t, jj0 + 1),
        else: jj0

    if tk(t, jj) == :"]" do
      node =
        CST.node(:access, merge_ct(t, lhs, jj), [lhs, idx], :matched, nil)

      postfix(t, jj + 1, node, ctx, diags, nid, fuel)
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_rbracket, tok_span(t, jj), %{})

      node =
        CST.node(
          :access,
          merge_ct(t, lhs, jj),
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
    tk(t, i) == :"(" and paren_callee?(t, lhs, pdepth) and
      cst_ends_at_token?(t, lhs, i)
  end

  defp paren_callee?(t, lhs, 0),
    do: ctag(lhs) == :token and tk(t, ctoki(lhs)) == :identifier

  defp paren_callee?(_t, lhs, 1),
    do: ctag(lhs) == :node and ckind(lhs) in [:call, :remote_call, :anon_call]

  defp paren_callee?(_t, _lhs, _pdepth), do: false

  # `.` after a primary: alias-chain extension (`.Alias`), remote call (`.name` / `.name(...)`),
  # or anonymous call (`.(...)`). A newline is allowed after the dot.
  defp dot(t, dot_i, lhs, ctx, diags, nid, fuel) do
    j = skip_eols(t, dot_i + 1)

    case tk(t, j) do
      :alias ->
        segs = if alias_node?(lhs), do: cchildren(lhs), else: [lhs]

        node =
          CST.node(
            :alias,
            merge_ct(t, lhs, j),
            Enum.concat(segs, [ctoken(j)]),
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
            merge_ct(t, lhs, k - 1),
            [lhs | args],
            :matched,
            nil
          )

        # Anon call `a.(...)` consumed its first paren group; one more (`a.()()`) is allowed.
        postfix(t, k, node, ctx, diags, nid, fuel, 1)

      # Dot-tuple multi-alias `Foo.{A, B}` (the `alias Foo.{Bar, Baz}` form): the brace contents
      # are a comma-separated sequence; lowers to `{{:., _, [base, :{}]}, _, [elems]}`.
      :"{" ->
        {elems, k, diags, nid, fuel} = parse_seq(t, j + 1, :"}", :tuple, diags, nid, fuel)
        {diags, nid} = check_container_lead(:dot_tuple, t, elems, diags, nid)

        node =
          CST.node(
            :dot_tuple,
            merge_ct(t, lhs, k - 1),
            [lhs | elems],
            :matched,
            nil
          )

        postfix(t, k, node, ctx, diags, nid, fuel, 0)

      # Dot-quoted remote call `a."foo"` / `a.'foo'`: the quoted string is the function name (an
      # atom; lowering rejects interpolation). `a."foo"(args)` takes an adjacent arg list.
      qk when qk in [:string_start, :charlist_start] ->
        qkind = if qk == :charlist_start, do: :charlist, else: :string
        {qname, k, diags, nid, fuel} = parse_quoted(t, j, qkind, diags, nid, fuel)
        remote_quoted_call(t, k, lhs, qname, ctx, diags, nid, fuel)

      # A reserved word or operator is a valid member name: `flags.true`, `a.when`, `conn.do`,
      # `Kernel.+`, `foo.++`, `foo.<>`. (`->`, `=>`, `//`, `.`, `..`, `...` are NOT members.)
      k when k in @dot_member_kinds ->
        remote_call(t, j, lhs, ctx, diags, nid, fuel)

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
            merge_ct(t, lhs, dot_i),
            [lhs, CST.missing(:identifier, j, diag: id)],
            :matched,
            nil
          )

        {node, j, diags, nid, fuel}
    end
  end

  defp remote_call(t, name_i, lhs, ctx, diags, nid, fuel) do
    name = ctoken(name_i)

    if tk(t, name_i + 1) == :"(" and Tokens.adjacent?(t, name_i, name_i + 1) do
      {args, k, diags, nid, fuel} = parse_seq(t, name_i + 2, :")", :call, diags, nid, fuel)

      node =
        CST.node(
          :remote_call,
          merge_ct(t, lhs, k - 1),
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
          merge_ct(t, lhs, name_i),
          [lhs, name],
          :matched,
          nil
        )

      # `a.b` (no adjacent parens) is a fresh base; a following `(` would have been consumed above.
      postfix(t, name_i + 1, node, ctx, diags, nid, fuel, 0)
    end
  end

  # `a."foo"` (quoted function name). An adjacent `(` makes it a call with args, else a 0-arg
  # remote call — same `:remote_call` node, but the name child is a `:string`/`:charlist` node.
  defp remote_quoted_call(t, after_q, lhs, qname, ctx, diags, nid, fuel) do
    if tk(t, after_q) == :"(" and cst_ends_at_token?(t, qname, after_q) do
      {args, k, diags, nid, fuel} = parse_seq(t, after_q + 1, :")", :call, diags, nid, fuel)
      span = merge_ct(t, lhs, k - 1)
      node = CST.node(:remote_call, span, [lhs, qname | args], :matched, nil)
      postfix(t, k, node, ctx, diags, nid, fuel, 1)
    else
      span = merge(cst_span(t, lhs), cst_span(t, qname))
      node = CST.node(:remote_call, span, [lhs, qname], :matched, nil)
      postfix(t, after_q, node, ctx, diags, nid, fuel, 0)
    end
  end

  defp alias_node?(cst), do: ctag(cst) == :node and ckind(cst) == :alias

  defp led(_t, i, lhs, _min_bp, _ctx, diags, nid, fuel) when fuel <= 0,
    do: {lhs, i, diags, nid, fuel}

  defp led(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    # A newline before a binding infix continues the expression (`a\n|> b`, the multi-line pipe
    # idiom) — for EVERY operator except `+`/`-` (dual_op, ambiguous with the unary forms, where a
    # leading newline starts a new statement). Dot continuation (`a\n.b`) is handled in postfix.
    i = led_skip_eol(t, i, min_bp)

    # `a not in b`: the two-token `not in` operator (in_op precedence 170, left-assoc). Built as a
    # faithful :not_in_op CST; the rewrite to `not(a in b)` happens only in lowering (P: no
    # rewrite-ish work in Pratt).
    if not_in?(t, i) and 170 >= min_bp do
      led_not_in(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    else
      led_infix(t, i, lhs, min_bp, ctx, diags, nid, fuel)
    end
  end

  defp led_skip_eol(t, i, min_bp) do
    if tk(t, i) == :eol do
      j = skip_eols(t, i)
      if continues_after_eol?(t, j, min_bp), do: j, else: i
    else
      i
    end
  end

  # The post-newline token continues the expression iff it's a binding infix that isn't `+`/`-`
  # (dual_op), or the two-token `not in`. "Binding" uses led_infix's threshold (`prec >= min_bp`).
  # At a depth-0 newline mid-head: keep scanning for the `->` only if the head continues across it
  # (the next line leads with an infix op / `when`, or the previous token expected more).
  defp head_eol_ahead?(t, nxt, stop, prev) do
    # The `->` itself may sit on the next line (`n when is_number(n)\n  -> …`), so a leading
    # `:stab_op` after the newline also continues the head.
    if tk(t, nxt) == :stab_op or continues_after_eol?(t, nxt, 0) or
         head_expects_more?(prev),
       do: clause_head_ahead?(t, nxt, 0, stop, prev),
       else: false
  end

  # Does a token at the end of a line leave a clause head incomplete (so the next line continues
  # it)? True for an infix op (`a &&\n…`), a prefix op (`-\n…`), or a pattern comma (`a,\n…`).
  defp head_expects_more?(kind) do
    Precedence.infix(kind) != nil or Precedence.prefix(kind) != nil or kind == :","
  end

  defp continues_after_eol?(t, j, min_bp) do
    if not_in?(t, j) do
      170 >= min_bp
    else
      kind = tk(t, j)

      case Precedence.infix(kind) do
        {prec, _assoc} -> kind != :dual_op and prec >= min_bp
        nil -> false
      end
    end
  end

  defp led_not_in(t, not_i, lhs, min_bp, ctx, diags, nid, fuel) do
    in_i = skip_eols(t, not_i + 1)
    rhs_start = skip_eols(t, in_i + 1)
    # Propagate the no-parens context (like `led_infix`) so a `do` after the RHS attaches to the
    # enclosing call, not the RHS operand — `def f(h) when h not in @x do … end`.
    rhs_ctx = if ctx in [:no_parens, :no_parens_arg], do: ctx, else: :matched
    {rhs, k, diags, nid, fuel} = parse_expr(t, rhs_start, 171, rhs_ctx, diags, nid, fuel - 1)

    node =
      CST.node(:not_in_op, merge(cst_span(t, lhs), cst_span(t, rhs)), [lhs, rhs], :matched, nil)

    led(t, k, node, min_bp, ctx, diags, nid, fuel)
  end

  defp led_infix(t, i, lhs, min_bp, ctx, diags, nid, fuel) do
    case Precedence.infix(tk(t, i)) do
      {prec, assoc} when prec >= min_bp ->
        op_leaf = ctoken(i)
        next_min = if assoc == :left, do: prec + 1, else: prec
        rhs_start = skip_eols(t, i + 1)

        {rhs, k, diags, nid, fuel} =
          cond do
            # `when` uniquely takes a bare keyword list on the right (`x when foo: 1, bar: 2`),
            # incl. quoted keys (`x when 'foo': 1`).
            tk(t, i) == :when_op and kw_data_start?(t, rhs_start) ->
              when_kw_rhs(t, rhs_start, diags, nid, fuel)

            # In a no-parens context the RIGHTMOST operand may be a no-parens call with several
            # args (`1 + foo 2, 3` => `1 + foo(2, 3)`). The context is PRESERVED, not flattened to
            # `:no_parens`: at top level (`:no_parens`) a `do` block attaches to the operand
            # (`1 + if x do … end`), but inside a no-parens ARG (`:no_parens_arg`) it stays
            # suppressed so the `do` attaches to the enclosing call (`def f when g do … end`).
            true ->
              rhs_ctx = if ctx in [:no_parens, :no_parens_arg], do: ctx, else: :matched
              parse_expr(t, rhs_start, next_min, rhs_ctx, diags, nid, fuel - 1)
          end

        node =
          CST.node(
            :binary_op,
            merge(cst_span(t, lhs), cst_span(t, rhs)),
            [lhs, op_leaf, rhs],
            :matched,
            nil
          )

        {diags, nid} = maybe_ambiguous_pipe(t, i, rhs, diags, nid)
        {diags, nid} = maybe_no_parens_after_do(t, i, lhs, rhs, diags, nid)
        led(t, k, node, min_bp, ctx, diags, nid, fuel)

      _ ->
        {lhs, i, diags, nid, fuel}
    end
  end

  # Does a keyword list start at `i` — a bare `key:` or a quoted `"key":` key? (Used for the `when`
  # right operand, keyword-list clause guards, and keyword indices in access `a[k: v]`.)
  defp kw_data_start?(t, i) do
    case tk(t, i) do
      :kw_identifier -> true
      k when k in [:string_start, :charlist_start] -> quoted_kw?(t, quote_end(t, i + 1, 0))
      _ -> false
    end
  end

  # Index just past a quoted literal's closing `string_end`/`charlist_end` (interpolation-aware).
  defp quote_end(t, i, depth) do
    case tk(t, i) do
      :eof -> i
      k when k in [:string_end, :charlist_end] and depth == 0 -> i + 1
      :begin_interpolation -> quote_end(t, i + 1, depth + 1)
      :end_interpolation -> quote_end(t, i + 1, depth - 1)
      _ -> quote_end(t, i + 1, depth)
    end
  end

  # The keyword-list right operand of `when` (`x when foo: 1, bar: 2` => `x when [foo: 1, …]`).
  # Collected like no-parens keyword args, then wrapped in a list node (lowers to a keyword list).
  defp when_kw_rhs(t, i, diags, nid, fuel) do
    {first, j, is_kw, diags, nid, fuel} = parse_np_arg(t, i, diags, nid, fuel)
    {pairs, k, diags, nid, fuel} = np_more_args(t, j, [first], is_kw, diags, nid, fuel)

    # `:kw_list`, not `:list` — this keyword list is synthesized from a bare `when a: t` guard (no
    # brackets in source), so it must NOT be treated as a list literal by the literal encoder.
    {CST.node(:kw_list, list_span(t, pairs), pairs, :matched, nil), k, diags, nid, fuel}
  end

  # Operator families that may name a function reference (`op/arity`). `->`, `=>` and the structural
  # `.` are excluded (`->/2` etc. are not captures). `..`/`...` (`range_op`/`ellipsis_op`) ARE valid
  # here: Elixir's tokenizer re-emits an operator followed by `/arity` in capture position as an
  # identifier, so `&../2` yields the identifier-shaped `{:.., _, nil}` (args nil), exactly as the
  # other op refs lower (`op_ref` => `{op_atom, meta, nil}`).
  @op_ref_kinds [
    :dual_op,
    :mult_op,
    :concat_op,
    :comp_op,
    :rel_op,
    :arrow_op,
    :and_op,
    :or_op,
    :xor_op,
    :power_op,
    :in_op,
    :when_op,
    :unary_op,
    :pipe_op,
    :type_op,
    :match_op,
    :in_match_op,
    :ternary_op,
    :range_op,
    :ellipsis_op
  ]

  defp op_ref_slash?(t, i), do: tk(t, i) == :mult_op and tv(t, i) == :/

  defp parse_prefix(t, i, ctx, diags, nid, fuel) do
    kind = tk(t, i)
    prefix_bp = Precedence.prefix(kind)

    cond do
      kind in @atomic_kinds ->
        {ctoken(i), i + 1, diags, nid, fuel}

      # An alias is a 1-segment alias node; `.Alias` postfixes extend its segments.
      kind == :alias ->
        {CST.node(:alias, tok_span(t, i), [ctoken(i)], :matched, nil), i + 1, diags, nid, fuel}

      kind == :error ->
        {id, diags, nid} = emit_lex_error(t, i, diags, nid)
        {CST.token(i, error: true, diag: id), i + 1, diags, nid, fuel}

      # An operator function reference: `+/2`, `>=/2`, `&++/2`. In nud position an operator name
      # immediately followed by `/` is a bare operator value (`{:+, [], nil}`); the trailing
      # `/arity` is an ordinary division in the led loop. The `/` guard keeps this from changing
      # any other use of these operators.
      kind in @op_ref_kinds and op_ref_slash?(t, i + 1) ->
        {CST.node(:op_ref, tok_span(t, i), [ctoken(i)], :matched, nil), i + 1, diags, nid, fuel}

      # `..` / `...` with no left operand: `..` is nullary only (`{:.., [], []}`); `...` is nullary
      # (`{:..., [], []}`) or unary when an operand follows (`...x` => `{:..., [], [x]}`).
      kind in [:range_op, :ellipsis_op] ->
        parse_dotdot(t, i, kind, ctx, diags, nid, fuel)

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

  # `:"..."` / `:'...'` — a `:quoted_atom` marker at `i`, then the quoted literal's tokens at i+1.
  defp parse_primary(:quoted_atom, t, i, _ctx, diags, nid, fuel) do
    kind = if tk(t, i + 1) == :charlist_start, do: :charlist, else: :string
    {inner, j, diags, nid, fuel} = parse_quoted(t, i + 1, kind, diags, nid, fuel)
    span = merge_tc(t, i, inner)
    {CST.node(:quoted_atom, span, [inner], :matched, nil), j, diags, nid, fuel}
  end

  defp parse_primary(_kind, t, i, _ctx, diags, nid, fuel),
    do: parse_unexpected(t, i, diags, nid, fuel)

  # A sigil is `:sigil_start <part>* :sigil_end`. The CST `:sigil` node keeps the start leaf
  # (carries the name), the parts (fragments / interpolations), and the end leaf (carries the
  # trailing modifiers) — lowering reads name + modifiers from those leaves.
  defp parse_sigil(t, start_i, diags, nid, fuel) do
    {children, j, diags, nid, fuel} =
      sigil_parts(t, start_i + 1, [ctoken(start_i)], diags, nid, fuel)

    span = merge_tt(t, start_i, j - 1)
    {CST.node(:sigil, span, children, :matched, nil), j, diags, nid, fuel}
  end

  defp sigil_parts(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> sigil_part(tk(t, i), t, i, acc, diags, nid, fuel)
    end
  end

  defp sigil_part(:string_fragment, t, i, acc, diags, nid, fuel),
    do: sigil_parts(t, i + 1, [ctoken(i) | acc], diags, nid, fuel)

  defp sigil_part(:begin_interpolation, t, i, acc, diags, nid, fuel) do
    {interp, j, diags, nid, fuel} = parse_interp(t, i, diags, nid, fuel)
    sigil_parts(t, j, [interp | acc], diags, nid, fuel)
  end

  defp sigil_part(:sigil_end, _t, i, acc, diags, nid, fuel),
    do: {:lists.reverse([ctoken(i) | acc]), i + 1, diags, nid, fuel}

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
    span = merge_tt(t, start_i, j - 1)
    {CST.node(node_kind, span, parts, :matched, nil), j, diags, nid, fuel}
  end

  defp quoted_parts(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> quoted_part(tk(t, i), t, i, acc, diags, nid, fuel)
    end
  end

  defp quoted_part(frag, t, i, acc, diags, nid, fuel)
       when frag in [:string_fragment, :charlist_fragment],
       do: quoted_parts(t, i + 1, [ctoken(i) | acc], diags, nid, fuel)

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
      if tk(t, j) == :end_interpolation do
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

    span = merge_tt(t, begin_i, end_i - 1)
    {CST.node(:interp, span, exprs, :matched, nil), end_i, diags, nid, fuel}
  end

  defp collect_interp(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 ->
        {:lists.reverse(acc), i, diags, nid, fuel}

      tk(t, i) in [:end_interpolation, :eof] ->
        {:lists.reverse(acc), i, diags, nid, fuel}

      tk(t, i) in [:eol, :";"] ->
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
    case tk(t, i) do
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
    case tk(t, i) do
      k when k in [:eol, :";", :end_interpolation, :eof] -> i
      _ -> skip_to_interp_eoe(t, i + 1)
    end
  end

  # --- fn / stab clauses -------------------------------------------------

  # `fn <clause>+ end`, each clause `<patterns> [when guard] -> <body>`.
  defp parse_fn(t, fn_i, diags, nid, fuel) do
    {clauses, j, diags, nid, fuel} = parse_clauses(t, fn_i + 1, [], diags, nid, fuel)

    {CST.node(:fn, merge_tt(t, fn_i, j - 1), clauses, :matched, nil), j, diags, nid, fuel}
  end

  defp parse_clauses(t, i, acc, diags, nid, fuel) do
    i = skip_eoe(t, i)

    cond do
      tk(t, i) == :end ->
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

      t_eof?(t, i) ->
        {id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :expected_end, eof_span(t), %{})

        {:lists.reverse([CST.missing(:end, i, diag: id) | acc]), i, diags, nid, fuel}

      true ->
        {clause, j, diags, nid, fuel} = parse_clause(t, i, :end, diags, nid, fuel)
        j = if j > i, do: j, else: i + 1
        parse_clauses(t, j, [clause | acc], diags, nid, fuel)
    end
  end

  defp parse_clause(t, i, stop, diags, nid, fuel) do
    {head, arrow_i, diags, nid, fuel} = parse_clause_head(t, i, diags, nid, fuel)

    if tk(t, arrow_i) == :stab_op do
      {body, k, diags, nid, fuel} = parse_clause_body(t, arrow_i + 1, [], stop, diags, nid, fuel)
      {diags, nid} = maybe_empty_stab_warn(t, arrow_i, body, diags, nid)

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

  # `1 ->` with no expression after the `->` (`case x do 1 -> end`, `fn -> end`) — Elixir warns an
  # expression is always required on the right side of `->`. The body is an empty `:stab_body`.
  defp maybe_empty_stab_warn(t, arrow_i, body, diags, nid) do
    if ctag(body) == :node and ckind(body) == :stab_body and cchildren(body) == [] do
      {_id, diags, nid} =
        Diagnostics.emit(
          diags,
          nid,
          :parser,
          :warning,
          :empty_stab_clause,
          tok_span(t, arrow_i),
          %{}
        )

      {diags, nid}
    else
      {diags, nid}
    end
  end

  # Returns {head_node, arrow_index, ...}. The head is the patterns (with optional `when` guard);
  # `arrow_index` is where the `->` should be.
  defp parse_clause_head(t, i, diags, nid, fuel) do
    i = skip_eols(t, i)

    cond do
      tk(t, i) == :stab_op ->
        {CST.node(:stab_args, tok_span(t, i), [], :matched, nil), i, diags, nid, fuel}

      # A parenthesised multi-arg head — `(a, b) -> …`, `(x, a: 1) when g -> …`: the parens wrap
      # the comma-separated arg list (`stab_parens_many`), so parse the interior as the patterns.
      stab_parens_head?(t, i) ->
        {patterns, j, diags, nid, fuel} = head_patterns(t, i + 1, [], diags, nid, fuel)
        close = skip_eols(t, j)
        after_close = if tk(t, close) == :")", do: close + 1, else: close
        clause_head_guard(t, skip_eols(t, after_close), patterns, diags, nid, fuel)

      true ->
        {patterns, j, diags, nid, fuel} = head_patterns(t, i, [], diags, nid, fuel)
        jj = skip_eols(t, j)
        clause_head_guard(t, jj, patterns, diags, nid, fuel)
    end
  end

  # Is the head a single parenthesised arg list (`(a, b) ->`, `(a: 1) ->`)? True when a `(` opens,
  # its body carries a depth-0 comma or keyword (so it can't be a plain single-pattern paren), and
  # the matching `)` is immediately followed by `->`/`when`. Single-arg `(a)` and empty `()` keep
  # their existing paren-expr path (same resulting AST).
  defp stab_parens_head?(t, i) do
    tk(t, i) == :"(" and
      case scan_paren(t, i + 1, 1, false) do
        {true, close} ->
          tk(t, close) == :")" and
            tk(t, skip_eols(t, close + 1)) in [:stab_op, :when_op]

        {false, _} ->
          false
      end
  end

  # Scan a paren whose `(` precedes `i`; returns {arg_list?, matching_close_index}, where
  # `arg_list?` is true if a depth-0 comma or keyword key was seen (marks a multi/keyword arg list).
  defp scan_paren(t, i, depth, args?), do: scan_paren(t, i, depth, args?, :eol)

  defp scan_paren(t, i, depth, args?, prev) do
    k = tk(t, i)

    cond do
      k == :eof ->
        {args?, i}

      # A reserved word as a dot member (`a.end`) is a name, not a block delimiter.
      prev == :dot and k in [:end, :do, :fn, :block_label] ->
        scan_paren(t, i + 1, depth, args?, k)

      depth == 1 and k == :")" ->
        {args?, i}

      depth == 1 and k in [:",", :kw_identifier, :kw_quote] ->
        scan_paren(t, i + 1, depth, true, k)

      true ->
        scan_paren(t, i + 1, depth + depth_delta(k), args?, k)
    end
  end

  defp clause_head_guard(t, i, patterns, diags, nid, fuel) do
    if tk(t, i) == :when_op do
      guard_start = skip_eols(t, i + 1)

      {guard, j, diags, nid, fuel} =
        if kw_data_start?(t, guard_start) do
          # `fn (a) when foo: 1 -> …`: a keyword-list guard, like the expression-level `when`.
          when_kw_rhs(t, guard_start, diags, nid, fuel)
        else
          # `:no_parens` so a guard that is a no-parens call takes several args (`when baz a, b`).
          parse_expr(t, guard_start, 0, :no_parens, diags, nid, fuel - 1)
        end

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

  # Comma-separated patterns, each parsed stopping before `when` (50) and `->` (not infix). A
  # trailing run of keyword pairs (`fn x, a: 1 -> …`) is collected like call/list args — kept as
  # `:kw_pair` nodes here and grouped into one keyword-list arg at lowering.
  defp head_patterns(t, i, acc, diags, nid, fuel) do
    i = skip_eols(t, i)
    {pat, j, diags, nid, fuel} = head_pattern(t, i, diags, nid, fuel)

    j = if j > i, do: j, else: i + 1
    jj = skip_eols(t, j)

    if tk(t, jj) == :"," do
      head_patterns(t, jj + 1, [pat | acc], diags, nid, fuel)
    else
      {:lists.reverse([pat | acc]), j, diags, nid, fuel}
    end
  end

  # One stab-head pattern: a keyword pair (`a: 1`) or an ordinary pattern (stopping before `when`).
  # Parsed in `:no_parens` so a pattern that is a no-parens call takes several args — the whole
  # `x 1, 2, 3` is ONE pattern (`x(1, 2, 3)`), and a keyword value may be one too (`a: b c, d`).
  defp head_pattern(t, i, diags, nid, fuel) do
    if tk(t, i) == :kw_identifier do
      key = ctoken(i)

      {val, j, diags, nid, fuel} =
        parse_expr(t, skip_eols(t, i + 1), 0, :no_parens, diags, nid, fuel - 1)

      node =
        CST.node(:kw_pair, merge_tc(t, i, val), [key, val], :matched, nil)

      {node, j, diags, nid, fuel}
    else
      {expr, j, diags, nid, fuel} =
        parse_expr(t, i, @clause_pattern_bp, :no_parens, diags, nid, fuel - 1)

      # A quoted keyword key in a stab head (`('a': 1) -> …`).
      if quoted_kw?(t, j) do
        parse_quoted_kw(t, expr, j, :matched, diags, nid, fuel)
      else
        {expr, j, diags, nid, fuel}
      end
    end
  end

  # Clause body: statements until the section terminator (`end`, or `)` for a parenthesised stab),
  # EOF, or the next clause head (a `->` on the line ahead).
  defp parse_clause_body(t, i, acc, stop, diags, nid, fuel) do
    # A single `;` at the very START of a stab body is an empty first statement: `-> ;t` =>
    # `__block__([nil, t])`, `-> ;` => `nil`. This is stab-specific (a paren block drops a leading
    # `;`). Newlines before it are insignificant; after the first statement `;`/newlines are plain
    # separators handled by `body_boundary`/`skip_eoe`.
    if acc == [] and tk(t, skip_eols(t, i)) == :";" do
      semi = skip_eols(t, i)
      parse_clause_body(t, semi + 1, [empty_stmt(t, semi)], stop, diags, nid, fuel)
    else
      parse_clause_body_cont(t, skip_eoe(t, i), acc, stop, diags, nid, fuel)
    end
  end

  defp empty_stmt(t, i), do: CST.node(:empty_stmt, tok_span(t, i), [], :matched, nil)

  defp parse_clause_body_cont(t, i, acc, stop, diags, nid, fuel) do
    cond do
      clause_section_end?(t, i, stop) or clause_head_ahead?(t, i, 0, stop) ->
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
        {j, diags, nid} = body_boundary(t, j, stop, diags, nid)
        parse_clause_body(t, j, [stmt | acc], stop, diags, nid, fuel)
    end
  end

  # A clause body ends at the section terminator: `end` / block label / EOF (always), plus the
  # caller's `stop` token — `:end` for `fn`/`do` (already covered) or `:")"` for a paren stab.
  defp clause_section_end?(t, i, stop),
    do: at_section_end?(t, i) or tk(t, i) == stop

  # After a body statement, the cursor must be at a boundary (EOE / `end` / block label / EOF /
  # next clause head). A same-line leftover token (`fn -> 1 2 end`) is an error; skip to a boundary.
  defp body_boundary(t, i, stop, diags, nid) do
    cond do
      clause_section_end?(t, i, stop) or tk(t, i) in [:eol, :";"] or
          clause_head_ahead?(t, i, 0, stop) ->
        {i, diags, nid}

      true ->
        {_id, diags, nid} =
          Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), %{
            kind: tk(t, i)
          })

        # As in `end_statement`: keep the leftover tokens so the body collect loop re-parses
        # them as the next statement instead of silently dropping them.
        {i, diags, nid}
    end
  end

  # A clause/section body ends at `end`, a block label (`else`/`catch`/`rescue`/`after`), or EOF.
  defp at_section_end?(t, i),
    do: tk(t, i) in [:end, :block_label] or t_eof?(t, i)

  defp clause_head_ahead?(t, i, depth, stop), do: clause_head_ahead?(t, i, depth, stop, :eol)

  # Is the upcoming line a clause head? True if a depth-0 `->` precedes the section terminator
  # (`stop` — `:end` or `)` for a paren stab), a hard statement boundary, or EOF. A clause head may
  # span several physical lines (`pattern\nwhen g ->`, `a &&\n b ->`), so a depth-0 NEWLINE only
  # stops the scan when the head is COMPLETE there — i.e. neither the previous token expects more
  # (an infix/prefix op or `,`) nor the next one continues it (a leading infix op / `when`). `prev`
  # is the last significant token kind. The depth-0 `stop` check comes first so a paren stab body
  # (`(-> 1) | (-> 2)`) doesn't scan past its `)` into a later clause.
  defp clause_head_ahead?(t, i, depth, stop, prev) do
    k = tk(t, i)

    cond do
      k == :eof ->
        false

      # A reserved word used as a dot member (`r.end`, `r.do`, `r.else`) is a NAME, not a section
      # terminator or a bracket — it must not move the depth or end the scan.
      prev == :dot and k in [:end, :do, :fn, :block_label] ->
        clause_head_ahead?(t, i + 1, depth, stop, k)

      depth == 0 and k == :stab_op ->
        true

      # The section terminator (`stop`/`end`), a block label, or a `;` ends the scan at depth 0.
      depth == 0 and k in [stop, :end, :block_label, :";"] ->
        false

      depth == 0 and k == :eol ->
        head_eol_ahead?(t, skip_eols(t, i), stop, prev)

      true ->
        clause_head_ahead?(t, i + 1, depth + depth_delta(k), stop, k)
    end
  end

  # Bracket/`fn`/`do`/`end` depth change for the clause-head scan (other tokens are depth-neutral).
  # Explicit per-atom clauses (not `k in [list]`) so the BEAM dispatches via a single atom select
  # rather than ~11 sequential `=:=` checks per token — `depth_delta` runs once per scanned token in
  # the `clause_head_ahead?` lookahead, which is hot on do-block-dense code.
  defp depth_delta(:"("), do: 1
  defp depth_delta(:"["), do: 1
  defp depth_delta(:"{"), do: 1
  defp depth_delta(:"<<"), do: 1
  defp depth_delta(:fn), do: 1
  defp depth_delta(:do), do: 1
  defp depth_delta(:")"), do: -1
  defp depth_delta(:"]"), do: -1
  defp depth_delta(:"}"), do: -1
  defp depth_delta(:">>"), do: -1
  defp depth_delta(:end), do: -1
  defp depth_delta(_k), do: 0

  # `head_patterns` always returns at least one pattern, so `patterns` is non-empty here.
  defp head_span(t, patterns, nil), do: list_span(t, patterns)
  defp head_span(t, patterns, guard), do: merge(cst_span(t, hd(patterns)), cst_span(t, guard))

  # --- do/end blocks -----------------------------------------------------

  # `do <section>+ end`, where the first section is `do` and later sections are block labels
  # (`else`/`catch`/`rescue`/`after`). Each section body is statements or stab clauses.
  defp parse_do_block(t, do_i, diags, nid, fuel) do
    {sections, j, diags, nid, fuel} = parse_sections(t, do_i, [], diags, nid, fuel)

    {CST.node(:do_block, merge_tt(t, do_i, j - 1), sections, :matched, nil), j, diags, nid, fuel}
  end

  defp parse_sections(t, i, acc, diags, nid, fuel) do
    label = ctoken(i)
    {body, j, diags, nid, fuel} = parse_section_body(t, i + 1, diags, nid, fuel)

    section =
      CST.node(
        :do_section,
        merge_tc(t, i, body),
        [label, body],
        :matched,
        nil
      )

    cond do
      tk(t, j) == :block_label ->
        parse_sections(t, j, [section | acc], diags, nid, fuel)

      tk(t, j) == :end ->
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

    if not at_section_end?(t, i) and clause_head_ahead?(t, i, 0, :end) do
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
      {clause, j, diags, nid, fuel} = parse_clause(t, i, :end, diags, nid, fuel)
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
      {j, diags, nid} = body_boundary(t, j, :end, diags, nid)
      parse_block_stmts(t, j, [stmt | acc], diags, nid, fuel)
    end
  end

  # `%{...}` map or `%Name{...}` struct.
  defp parse_percent(t, i, diags, nid, fuel) do
    j = i + 1

    cond do
      tk(t, j) == :"{" ->
        parse_map_body(t, j, i, diags, nid, fuel)

      struct_base_start?(tk(t, j)) ->
        parse_struct(t, i, diags, nid, fuel)

      # A `(`/`[` base is valid only when SPACED from `%`: `% (){}` is a struct on `()`, but the
      # adjacent `%(...)` / `%[...]` is rejected by Elixir.
      tk(t, j) in [:"(", :"["] and not adjacent_after?(tok_span(t, i), tok_span(t, j)) ->
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

  # A struct base is a (non-paren, non-bracket) primary expression — `%Alias{}`, `%var{}`,
  # `%nil{}`, `%@attr{}`, `%"s"{}`, `%-a{}`, `%<<x>>{}`, `%%{}{}`. Notably `%(...)`/`%[...]`/`%&x`
  # are NOT valid struct bases (Elixir rejects them), so `(`/`[`/capture are excluded.
  defp struct_base_start?(kind) do
    kind in [
      :alias,
      :identifier,
      :int,
      :flt,
      :char,
      :atom,
      :literal,
      :quoted_atom,
      :string_start,
      :charlist_start,
      :sigil_start,
      :at_op,
      :unary_op,
      :dual_op,
      :ellipsis_op,
      :"<<",
      :percent
    ]
  end

  defp parse_struct(t, pct, diags, nid, fuel) do
    {name, j0, diags, nid, fuel} =
      parse_expr(t, pct + 1, @struct_name_bp, :matched, diags, nid, fuel - 1)

    # `map -> '%' map_base_expr eol map_args` admits an eol between the base and `{` (the lexer
    # collapses consecutive newlines into one eol token, so `%Foo\n{}` and `%Foo\n\n{}` both work).
    j = if tk(t, j0) == :eol and tk(t, skip_eols(t, j0)) == :"{", do: skip_eols(t, j0), else: j0

    if tk(t, j) == :"{" do
      {map, k, diags, nid, fuel} = parse_map_body(t, j, j, diags, nid, fuel)

      {CST.node(:struct, merge_tc(t, pct, map), [name, map], :matched, nil), k, diags, nid, fuel}
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_struct_body, tok_span(t, j), %{})

      {CST.node(
         :struct,
         merge_tc(t, pct, name),
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
      tk(t, i) == :"}" ->
        {CST.node(:map, merge_tt(t, span_start, i), [], :matched, nil), i + 1, diags, nid, fuel}

      tk(t, i) == :kw_identifier ->
        {entries, j, diags, nid, fuel} = map_entries(t, i, [], false, diags, nid, fuel)

        {CST.node(
           :map,
           merge_tt(t, span_start, j - 1),
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
      tk(t, jj) == :pipe_op ->
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
           merge_tt(t, span_start, k - 1),
           [key | entries],
           :matched,
           nil
         ), k, diags, nid, fuel}

      tk(t, jj) == :assoc_op ->
        {val, k, diags, nid, fuel} =
          parse_expr(t, skip_eols(t, jj + 1), 0, :matched, diags, nid, fuel - 1)

        first =
          CST.node(:assoc, merge(cst_span(t, key), cst_span(t, val)), [key, val], :matched, nil)

        {entries, m, diags, nid, fuel} = map_rest(t, k, [first], false, diags, nid, fuel)

        {CST.node(
           :map,
           merge_tt(t, span_start, m - 1),
           entries,
           :matched,
           nil
         ), m, diags, nid, fuel}

      # `%{"k": v}` — a quoted keyword key as the first entry (kw, so seen_kw is now true).
      quoted_kw?(t, j) ->
        {first, k, diags, nid, fuel} = parse_quoted_kw(t, key, j, :matched, diags, nid, fuel)
        {entries, m, diags, nid, fuel} = map_rest(t, k, [first], true, diags, nid, fuel)

        {CST.node(
           :map,
           merge_tt(t, span_start, m - 1),
           entries,
           :matched,
           nil
         ), m, diags, nid, fuel}

      # No `|` and no `=>`: a BARE first entry (`%{x}`, `%{1, 2}`). Continue with the rest.
      true ->
        {entries, m, diags, nid, fuel} = map_rest(t, j, [key], false, diags, nid, fuel)

        {CST.node(
           :map,
           merge_tt(t, span_start, m - 1),
           entries,
           :matched,
           nil
         ), m, diags, nid, fuel}
    end
  end

  # After an entry: finish at `}` (trailing comma allowed), continue at `,`, else unterminated.
  defp map_rest(t, i, acc, seen_kw, diags, nid, fuel) do
    i2 = skip_eols(t, i)

    cond do
      tk(t, i2) == :"}" ->
        {:lists.reverse(acc), i2 + 1, diags, nid, fuel}

      tk(t, i2) == :"," ->
        {diags, nid} = check_map_entry_np_comma(t, hd(acc), i2, diags, nid)
        map_entries(t, skip_eols(t, i2 + 1), acc, seen_kw, diags, nid, fuel)

      true ->
        map_unterminated(t, i2, acc, diags, nid, fuel)
    end
  end

  # `assoc_expr` admits only matched/unmatched exprs — a no-parens MANY call (`g b, c`) in an assoc
  # key or value (or a bare entry) position is rejected (`%{f(a) => g b, c}`, `%{g b, c}`). The
  # signal is the entry's value being a bare no-parens call immediately followed by `,` (it would
  # otherwise absorb the comma into a `no_parens_many`). Mirrors `check_np_comma` for containers.
  defp check_map_entry_np_comma(t, entry, comma_i, diags, nid) do
    val = map_entry_value(entry)

    if val != nil and CST.category(val) == :no_parens and not has_do_block?(val) do
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

  # The node whose trailing no-parens call would illegally swallow the following comma: an assoc's
  # value (2nd child), or a bare expression entry itself. A `kw_pair` value is parsed `:matched`
  # (keyword-last is enforced separately), so it is exempt.
  defp map_entry_value(entry) do
    case entry do
      {:node, :assoc, _sp, [_key, val], _f, _d} -> val
      {:node, :kw_pair, _sp, _ch, _f, _d} -> nil
      {:node, _kind, _sp, _ch, _f, _d} = node -> node
      _ -> nil
    end
  end

  # Comma-separated map entries (assoc or keyword pair) until `}`; keyword pairs must come last.
  defp map_entries(t, i, acc, seen_kw, diags, nid, fuel) do
    i = skip_eols(t, i)

    if tk(t, i) == :"}" do
      {:lists.reverse(acc), i + 1, diags, nid, fuel}
    else
      {entry, j, diags, nid, fuel} = parse_map_entry(t, i, diags, nid, fuel)
      is_kw = ckind(entry) == :kw_pair
      {diags, nid} = check_kw_last(seen_kw, is_kw, t, entry, diags, nid)
      map_rest(t, j, [entry | acc], seen_kw or is_kw, diags, nid, fuel)
    end
  end

  defp parse_map_entry(t, i, diags, nid, fuel) do
    if tk(t, i) == :kw_identifier do
      key = ctoken(i)

      {val, j, diags, nid, fuel} =
        parse_expr(t, skip_eols(t, i + 1), 0, :matched, diags, nid, fuel - 1)

      {CST.node(:kw_pair, merge_tc(t, i, val), [key, val], :matched, nil), j, diags, nid, fuel}
    else
      {key, j, diags, nid, fuel} = parse_expr(t, i, @map_key_bp, :matched, diags, nid, fuel - 1)
      jj = skip_eols(t, j)

      cond do
        tk(t, jj) == :assoc_op ->
          {val, k, diags, nid, fuel} =
            parse_expr(t, skip_eols(t, jj + 1), 0, :matched, diags, nid, fuel - 1)

          {CST.node(:assoc, merge(cst_span(t, key), cst_span(t, val)), [key, val], :matched, nil),
           k, diags, nid, fuel}

        # `%{"k": v}` — a quoted keyword key (the `:kw_quote` sits right after the close quote).
        quoted_kw?(t, j) ->
          parse_quoted_kw(t, key, j, :matched, diags, nid, fuel)

        true ->
          # A map entry without `=>` is a BARE expression (`%{x}`, `%{1, 2}`, `%{&0}`) — Elixir
          # allows them freely (used in quoted/macro code). The expression IS the entry.
          {key, j, diags, nid, fuel}
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
    {diags, nid} = check_container_lead(kind, t, elems, diags, nid)

    {CST.node(kind, merge_tt(t, open, j - 1), elems, :matched, nil), j, diags, nid, fuel}
  end

  # A tuple/bitstring/dot-tuple may carry trailing keywords (`{1, a: 1}` => `{1, [a: 1]}`) but its
  # FIRST element must be positional — Elixir's `container_args` requires a positional lead, so an
  # all-keyword `{a: 1}` / `<<a: 1>>` / `Foo.{a: 1}` is rejected.
  defp check_container_lead(kind, t, [first | _], diags, nid)
       when kind in [:tuple, :bitstring, :dot_tuple] do
    if kw_pair_node?(first) do
      {_id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :keyword_not_allowed, cst_span(t, first), %{
          in: kind
        })

      {diags, nid}
    else
      {diags, nid}
    end
  end

  defp check_container_lead(_kind, _t, _elems, diags, nid), do: {diags, nid}

  defp kw_pair_node?(cst), do: ctag(cst) == :node and ckind(cst) == :kw_pair

  # Comma-separated elements up to `close`. `mode` (`:list | :tuple | :bitstring | :call`) controls
  # the permissive-grammar edges: a trailing comma is allowed everywhere except calls; keyword
  # pairs are allowed only in lists and calls; and keyword pairs must come last.
  defp parse_seq(t, i, close, mode, diags, nid, fuel) do
    i = skip_eols(t, i)

    if tk(t, i) == close do
      {[], i + 1, diags, nid, fuel}
    else
      seq_elems(t, i, [], false, close, mode, diags, nid, fuel)
    end
  end

  defp seq_elems(t, i, acc, seen_kw, close, mode, diags, nid, fuel) do
    {el, i, is_kw, diags, nid, fuel} = parse_element(t, i, mode, diags, nid, fuel)
    {diags, nid} = check_kw_last(seen_kw, is_kw, t, el, diags, nid)
    {diags, nid} = check_call_arg_strict(mode, el, acc, t, diags, nid)
    acc = [el | acc]
    i2 = skip_eols(t, i)

    cond do
      tk(t, i2) == close ->
        {:lists.reverse(acc), i2 + 1, diags, nid, fuel}

      tk(t, i2) == :"," ->
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
      tk(t, nxt) != close ->
        seq_elems(t, nxt, acc, seen_kw, close, mode, diags, nid, fuel)

      # Lists/tuples/bitstrings allow a trailing comma freely (no warning). A paren call allows it
      # only after a keyword arg (`foo(a: 1,)`; `foo(1,)` is the error below) — and even then Elixir
      # warns that trailing commas are not allowed inside call arguments.
      mode != :call or seen_kw ->
        {diags, nid} =
          if mode == :call,
            do: trailing_comma_warn(t, comma_i, diags, nid),
            else: {diags, nid}

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

  defp trailing_comma_warn(t, comma_i, diags, nid) do
    {_id, diags, nid} =
      Diagnostics.emit(diags, nid, :parser, :warning, :trailing_comma, tok_span(t, comma_i), %{})

    {diags, nid}
  end

  # An element is a `key: value` keyword pair (only in lists/calls) or an expression. Returns the
  # node, the next index, and whether it was a keyword pair (for keyword-last enforcement).
  defp parse_element(t, i, mode, diags, nid, fuel) do
    # Call args are a `:no_parens` context (so `f(g a, b)` makes `g` absorb the commas, arity 1);
    # list/tuple/bitstring elements are `:matched` (a no-parens element may take only one arg).
    ctx = if mode == :call, do: :no_parens, else: :matched

    if tk(t, i) == :kw_identifier do
      key = ctoken(i)

      # A keyword VALUE is a single `matched_expr` (`f(a: g b)` => `g(b)`), NOT a `:no_parens`
      # call that grabs the outer commas — `f(a: g b, c)` is rejected (keyword-not-last).
      {val, j, diags, nid, fuel} =
        parse_expr(t, skip_eols(t, i + 1), 0, :matched, diags, nid, fuel - 1)

      node =
        CST.node(:kw_pair, merge_tc(t, i, val), [key, val], :matched, nil)

      {diags, nid} = check_kw_allowed(mode, t, i, diags, nid)
      {diags, nid} = check_np_kw_last(val, t, j, diags, nid)
      {node, j, true, diags, nid, fuel}
    else
      {expr, j, diags, nid, fuel} = parse_expr(t, i, 0, ctx, diags, nid, fuel)

      if quoted_kw?(t, j) do
        {node, k, diags, nid, fuel} = parse_quoted_kw(t, expr, j, :matched, diags, nid, fuel)
        {diags, nid} = check_kw_allowed(mode, t, i, diags, nid)
        {node, k, true, diags, nid, fuel}
      else
        {expr, j, false, diags, nid, fuel}
      end
    end
  end

  # A keyword value that is a no-parens call (`a: g b`) must be the LAST element — Elixir rejects
  # `f(a: g b, c)` / `f(a: if e, do: x)`. (A parenthesised value `a: g(b)` is a `:call`, not
  # `:np_call`, so it may be followed by more.)
  defp check_np_kw_last(val, t, j, diags, nid) do
    # A no-parens-call value ending in a `do … end` block is unambiguous, so it may be followed by
    # more keywords (`f(a: case x do … end, b: 1)`); only a bare no-parens call is keyword-last.
    if ctag(val) == :node and ckind(val) == :np_call and not has_do_block?(val) and
         tk(t, skip_eols(t, j)) == :"," do
      {_id, diags, nid} =
        Diagnostics.emit(
          diags,
          nid,
          :parser,
          :error,
          :no_parens_kw_not_last,
          cst_span(t, val),
          %{}
        )

      {diags, nid}
    else
      {diags, nid}
    end
  end

  # Does a call node end in an attached `do … end` block (its last child is a `:do_block`)?
  defp has_do_block?({:node, _k, _sp, children, _f, _d}) do
    match?({:node, :do_block, _, _, _, _}, List.last(children))
  end

  defp has_do_block?(_), do: false

  # A quoted keyword key (`"foo": v`): the lexer marks the colon as `:kw_quote` right after the
  # close quote, so an expression that's a quoted literal followed by `:kw_quote` is a kw pair
  # whose key is the literal (atomized like a quoted atom in lowering).
  defp quoted_kw?(t, j), do: tk(t, j) == :kw_quote

  defp parse_quoted_kw(t, key, kw_i, ctx, diags, nid, fuel) do
    {val, k, diags, nid, fuel} =
      parse_expr(t, skip_eols(t, kw_i + 1), 0, ctx, diags, nid, fuel - 1)

    node =
      CST.node(:kw_pair, merge(cst_span(t, key), cst_span(t, val)), [key, val], :matched, nil)

    {node, k, diags, nid, fuel}
  end

  # A no-parens call as a non-last container element (`[f a, b]`) is ambiguous — Elixir requires
  # parens. (In call args the comma is absorbed by the inner call, so this only fires in
  # list/tuple/bitstring.)
  defp check_np_comma(mode, el, t, comma_i, diags, nid) when mode != :call do
    # A no-parens call ending in a `do … end` block is unambiguous, so it's a valid element even
    # when not last (`[a, for x <- xs, into: [] do … end]`); only a bare no-parens call is ambiguous.
    if CST.category(el) == :no_parens and not has_do_block?(el) do
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

  # A NON-FIRST parenthesised call argument may not be a no-parens MANY / ambiguous-one call (`foo(a,
  # bar b, c)` — `bar b, c` absorbs the comma into a `no_parens_many`). Elixir rejects it via
  # `error_no_parens_many_strict` on `call_args_parens_expr`. As the sole/first arg it is fine
  # (`foo(bar b, c)` = `foo(bar(b, c))`, a `call_args_parens_one`), hence the non-empty `acc` guard.
  defp check_call_arg_strict(:call, el, [_ | _] = _acc, t, diags, nid) do
    if no_parens_expr?(el) do
      {_id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :ambiguous_no_parens, cst_span(t, el), %{})

      {diags, nid}
    else
      {diags, nid}
    end
  end

  defp check_call_arg_strict(_mode, _el, _acc, _t, diags, nid), do: {diags, nid}

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
  # Keyword pairs are allowed in lists, calls, tuples, and bitstrings (tuples/bitstrings
  # additionally require a leading positional element — see `check_container_lead`).
  defp check_kw_allowed(mode, _t, _i, diags, nid) when mode in [:list, :call, :tuple, :bitstring],
    do: {diags, nid}

  defp check_kw_allowed(mode, t, i, diags, nid) do
    {_id, diags, nid} =
      Diagnostics.emit(diags, nid, :parser, :error, :keyword_not_allowed, tok_span(t, i), %{
        in: mode
      })

    {diags, nid}
  end

  # `..` / `...` in prefix (nud) position. `...` takes a low-precedence operand when one follows
  # (`...a + b` => `...(a + b)`); otherwise — and always for `..` — it's nullary (`{:.., [], []}`).
  @ellipsis_operand_bp 90
  defp parse_dotdot(t, i, kind, ctx, diags, nid, fuel) do
    op_leaf = ctoken(i)
    operand_start = skip_eols(t, i + 1)
    op_ctx = if ctx in [:no_parens, :no_parens_arg], do: ctx, else: :matched

    if kind == :ellipsis_op and dotdot_operand?(t, operand_start) do
      {operand, k, diags, nid, fuel} =
        parse_expr(t, operand_start, @ellipsis_operand_bp, op_ctx, diags, nid, fuel - 1)

      span = merge(cst_span(t, op_leaf), cst_span(t, operand))
      {CST.node(:unary_op, span, [op_leaf, operand], :matched, nil), k, diags, nid, fuel}
    else
      {CST.node(:unary_op, tok_span(t, i), [op_leaf], :matched, nil), i + 1, diags, nid, fuel}
    end
  end

  # Does an operand for a prefix `...` start at `i`? (`+`/`-` lead a unary operand here: `... + 1`.)
  defp dotdot_operand?(t, i) do
    case tk(t, i) do
      # `+`/`-` lead a unary operand (`... + 1`); a following `..` is NOT an operand — it's a
      # binary range whose left side is the nullary `...` (`... .. 1` => `(...) .. 1`).
      :dual_op -> true
      :ellipsis_op -> true
      k -> np_first_kind?(k)
    end
  end

  defp parse_unary(t, i, prefix_bp, ctx, diags, nid, fuel) do
    op_leaf = ctoken(i)
    operand_start = skip_eols(t, i + 1)
    # In a no-parens context the operand may itself be a multi-arg no-parens call: `@foo 1, 2`,
    # `-foo 1, 2`, `not bar :a, :b`. Inside brackets/parens it stays a single-arg `matched_expr`.
    # Context is preserved (`:no_parens_arg` keeps a `do` attaching to the enclosing call).
    op_ctx = if ctx in [:no_parens, :no_parens_arg], do: ctx, else: :matched

    {operand, k, diags, nid, fuel} =
      parse_unary_operand(prefix_bp, t, operand_start, op_ctx, diags, nid, fuel)

    # Elixir's `unary_op_eol expr` for an UNMATCHED operand (one ending in a `do … end` block): the
    # unary becomes greedy and captures the whole trailing operator chain, so `not quote do x end ||
    # b` is `not(quote(…) || b)` (not `(not quote(…)) || b`) and `@foo try do 1 end..1//2` is
    # `@(foo(try) do 1 end .. 1 // 2)`. A MATCHED operand keeps the normal tight binding
    # (`not a || b` => `(not a) || b`, `@x..1` => `(@x)..1`). The distinction is the do-block.
    {operand, k, diags, nid, fuel} =
      if has_do_block?(operand) do
        led(t, k, operand, 0, op_ctx, diags, nid, fuel)
      else
        {operand, k, diags, nid, fuel}
      end

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

  # `@` (at_op, 320) binds TIGHTER than the dot/access postfixes (310), so they attach to the
  # `@x` result — `@x.y` => `(@x).y`, `@x[i]` => `(@x)[i]`. But an ADJACENT paren call IS part of
  # the operand (`@callback(spec)` => `@(callback(spec))`), and `@` still takes a NO-PARENS operand
  # (`@moduledoc false`, `@spec f() :: t`). So its operand is prefix, then an adjacent paren call,
  # then a no-parens call, then a do-block. Lower unaries (`!`/`^`/`+`/`-`/`not`, 300) bind LOOSER
  # than postfix — their operand is a full matched_expr (`!x.y` => `!(x.y)`).
  defp parse_unary_operand(prefix_bp, t, i, op_ctx, diags, nid, fuel) when prefix_bp >= 310 do
    {lhs, j, diags, nid, fuel} = parse_prefix(t, i, :matched, diags, nid, fuel)
    {lhs, j, diags, nid, fuel} = maybe_paren_call(t, j, lhs, diags, nid, fuel)
    {lhs, j, diags, nid, fuel} = maybe_no_parens(t, j, lhs, op_ctx, diags, nid, fuel)
    maybe_do_block(t, j, lhs, op_ctx, diags, nid, fuel)
  end

  defp parse_unary_operand(prefix_bp, t, i, op_ctx, diags, nid, fuel),
    do: parse_expr(t, i, prefix_bp, op_ctx, diags, nid, fuel - 1)

  # One adjacent paren call (`callback(spec)`), used by the `@` operand — `@foo(x)` => `@(foo(x))`.
  defp maybe_paren_call(t, i, lhs, diags, nid, fuel) do
    if paren_call?(t, lhs, i, 0) do
      {args, j, diags, nid, fuel} = parse_seq(t, i + 1, :")", :call, diags, nid, fuel)
      span = merge_ct(t, lhs, j - 1)
      {CST.node(:call, span, [lhs | args], :matched, nil), j, diags, nid, fuel}
    else
      {lhs, i, diags, nid, fuel}
    end
  end

  # A single parenthesised expression. Multi-statement parens `(a; b)` are deferred; here a `;`
  # before `)` is reported as a missing `)` and recovered by the expr-list loop.
  # A paren resets to a fresh `:matched` context, so the caller's `ctx` is not threaded inside.
  # A parenthesised expression is a statement block: 0 statements => `{:__block__, [], []}` (`()`,
  # `(;)`), 1 => the statement (transparent, `(a)` => a), n => a block (`(a; b)` => block). Inner
  # statements are a `:no_parens` context (`(f a, b)` => `f(a, b)`), separated by `;` / newline.
  defp parse_paren(t, open, _ctx, diags, nid, fuel) do
    # A paren holding a depth-0 `->` is a stab-clause list (`(a -> b)`, `(a, b -> c; d -> e)`) —
    # used for anonymous-fn-style clauses and typespecs; otherwise it's a statement group.
    if paren_stab?(t, open + 1, 0) do
      {clauses, close, diags, nid, fuel} =
        paren_clauses(t, skip_eoe(t, open + 1), [], diags, nid, fuel)

      close_paren(t, open, close, clauses, diags, nid, fuel)
    else
      {stmts, close, diags, nid, fuel} =
        paren_stmts(t, skip_eoe(t, open + 1), [], diags, nid, fuel)

      close_paren(t, open, close, stmts, diags, nid, fuel)
    end
  end

  defp close_paren(t, open, close, children, diags, nid, fuel) do
    if tk(t, close) == :")" do
      span = merge_tt(t, open, close)
      {CST.node(:paren, span, children, :matched, nil), close + 1, diags, nid, fuel}
    else
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_rparen, tok_span(t, close))

      miss = CST.missing(:")", close, diag: id)
      span = merge_tt(t, open, close)

      {CST.node(:paren, span, Enum.concat(children, [miss]), :matched, nil), close, diags, nid,
       fuel}
    end
  end

  # Does the paren body (starting at `i`) hold a depth-0 `->` before its matching `)`?
  defp paren_stab?(t, i, depth), do: paren_stab?(t, i, depth, :eol)

  defp paren_stab?(t, i, depth, prev) do
    k = tk(t, i)

    cond do
      k == :eof -> false
      # A reserved word as a dot member (`a.end`, `a.do`) is a name, not a block delimiter.
      prev == :dot and k in [:end, :do, :fn, :block_label] -> paren_stab?(t, i + 1, depth, k)
      depth == 0 and k == :stab_op -> true
      depth == 0 and k == :")" -> false
      true -> paren_stab?(t, i + 1, depth + depth_delta(k), k)
    end
  end

  # Stab clauses inside parens, terminated by `)` (each clause body stops at `)` too).
  defp paren_clauses(t, i, acc, diags, nid, fuel) do
    i = skip_eoe(t, i)

    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      tk(t, i) == :")" -> {:lists.reverse(acc), i, diags, nid, fuel}
      t_eof?(t, i) -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> paren_clause(t, i, acc, diags, nid, fuel)
    end
  end

  defp paren_clause(t, i, acc, diags, nid, fuel) do
    {clause, j, diags, nid, fuel} = parse_clause(t, i, :")", diags, nid, fuel)
    j = if j > i, do: j, else: i + 1
    paren_clauses(t, j, [clause | acc], diags, nid, fuel)
  end

  defp paren_stmts(t, i, acc, diags, nid, fuel) do
    cond do
      fuel <= 0 -> {:lists.reverse(acc), i, diags, nid, fuel}
      tk(t, i) == :")" -> {:lists.reverse(acc), i, diags, nid, fuel}
      t_eof?(t, i) -> {:lists.reverse(acc), i, diags, nid, fuel}
      true -> paren_stmt(t, i, acc, diags, nid, fuel)
    end
  end

  defp paren_stmt(t, i, acc, diags, nid, fuel) do
    {expr, i2, diags, nid, fuel} = parse_expr(t, i, 0, :no_parens, diags, nid, fuel - 1)
    i2 = if i2 > i, do: i2, else: i + 1
    {i3, diags, nid} = paren_end_stmt(t, i2, diags, nid)
    paren_stmts(t, i3, [expr | acc], diags, nid, fuel)
  end

  # A paren statement ends at `;` / newline (separator) or `)`; anything else is leftover (error).
  defp paren_end_stmt(t, i, diags, nid) do
    case tk(t, i) do
      k when k in [:eol, :";"] ->
        {skip_eoe(t, i), diags, nid}

      k when k in [:")", :eof] ->
        {i, diags, nid}

      :error ->
        {_id, d, n} = emit_lex_error(t, i, diags, nid)
        {skip_to_paren_eoe(t, i + 1), d, n}

      k ->
        {_id, d, n} =
          Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), %{
            kind: k
          })

        {skip_to_paren_eoe(t, i + 1), d, n}
    end
  end

  defp skip_to_paren_eoe(t, i) do
    case tk(t, i) do
      k when k in [:eol, :";"] -> skip_eoe(t, i)
      k when k in [:")", :eof] -> i
      _ -> skip_to_paren_eoe(t, i + 1)
    end
  end

  defp parse_unexpected(t, i, diags, nid, fuel) do
    if t_eof?(t, i) do
      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :expected_expression, eof_span(t))

      {CST.missing(:expression, i, diag: id), i, diags, nid, fuel}
    else
      details = %{kind: tk(t, i)}

      {id, diags, nid} =
        Diagnostics.emit(diags, nid, :parser, :error, :unexpected_token, tok_span(t, i), details)

      {CST.token(i, error: true, diag: id), i + 1, diags, nid, fuel}
    end
  end

  # --- diagnostics for lexer error tokens (sole transport, P3) -----------

  defp emit_lex_error(t, i, diags, nid) do
    %LexError{code: code} = tv(t, i)
    Diagnostics.emit(diags, nid, :lexer, :error, code, tok_span(t, i))
  end

  # --- cursor helpers ----------------------------------------------------

  defp skip_eoe(t, i) do
    case tk(t, i) do
      :eol -> skip_eoe(t, i + 1)
      :";" -> skip_eoe(t, i + 1)
      _ -> i
    end
  end

  defp skip_eols(t, i) do
    case tk(t, i) do
      :eol -> skip_eols(t, i + 1)
      _ -> i
    end
  end

  # --- span resolution ---------------------------------------------------

  defp cst_span(t, cst) do
    case ctag(cst) do
      :node -> cspan(cst)
      :token -> tspan(t, ctoki(cst))
      :missing -> anchor_span(t, CST.anchor_index(cst))
    end
  end

  defp anchor_span(t, ai) do
    case tspan(t, ai) do
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

  # Span from the start of token `i` to the end of token `j` in ONE tuple — reads the two token
  # tuples directly (no alloc) instead of `merge(tok_span(i), tok_span(j))`, which built two
  # throwaway `{sl,sc,el,ec}` spans (tprof: `Token.span/1` was ~5% of full-pipeline allocation).
  defp merge_tt(t, i, j) do
    ti = tt(t, i)
    tj = tt(t, j)

    if is_tuple(ti) and is_tuple(tj) do
      {_, sl, sc, _, _, _} = ti
      {_, _, _, el, ec, _} = tj
      {sl, sc, el, ec}
    else
      # one side is past EOF (a recovered/truncated node) — fall back to the eof-aware spans.
      merge(tok_span(t, i), tok_span(t, j))
    end
  end

  # Span from CST `a`'s start to token `j`'s end, in one tuple. A node's start comes from its stored
  # span (matched inline — no alloc); a token-leaf start delegates to `merge_tt`; else fall back.
  defp merge_ct(t, {:node, _k, {sl, sc, _, _}, _ch, _f, _d}, j) do
    case tt(t, j) do
      {_, _, _, el, ec, _} -> {sl, sc, el, ec}
      _ -> {sl, sc, sl, sc}
    end
  end

  defp merge_ct(t, {:token, i, _f, _d}, j), do: merge_tt(t, i, j)
  defp merge_ct(t, a, j), do: merge(cst_span(t, a), tok_span(t, j))

  # Span from token `i`'s start to CST `b`'s end, in one tuple (mirror of `merge_ct`).
  defp merge_tc(t, i, {:node, _k, {_, _, el, ec}, _ch, _f, _d}) do
    case tt(t, i) do
      {_, sl, sc, _, _, _} -> {sl, sc, el, ec}
      _ -> {el, ec, el, ec}
    end
  end

  defp merge_tc(t, i, {:token, j, _f, _d}), do: merge_tt(t, i, j)
  defp merge_tc(t, i, b), do: merge(tok_span(t, i), cst_span(t, b))

  defp tok_span(t, i), do: tspan(t, i) || eof_span(t)

  defp eof_span(t) do
    case Tokens.size(t) do
      0 ->
        {1, 1, 1, 1}

      n ->
        {_, _, el, ec} = tspan(t, n - 1)
        {el, ec, el, ec}
    end
  end
end
