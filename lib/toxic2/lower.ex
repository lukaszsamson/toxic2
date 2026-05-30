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

  @type ast :: Macro.t()

  @doc """
  Lower `cst` to AST. Returns `{ast, lowerer_diagnostics}` (source-ordered). `start_id` is the
  next free diagnostic id (so ids don't collide with lexer/parser diagnostics).
  """
  @spec to_ast(CST.t(), Tokens.t(), keyword(), pos_integer()) :: {ast(), [Toxic2.Diagnostic.t()]}
  def to_ast(cst, view, opts \\ [], start_id \\ 1) do
    {ast, acc, _nid} = lower(cst, view, opts, [], start_id)
    {ast, Diagnostics.to_list(acc)}
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
    meta = tmeta(view, idx)

    case Tokens.kind(view, idx) do
      :int -> {val, acc, nid}
      :flt -> {val, acc, nid}
      :char -> {val, acc, nid}
      :literal -> {val, acc, nid}
      :atom -> atomize(cst, view, opts, acc, nid, val, & &1)
      :identifier -> atomize(cst, view, opts, acc, nid, val, &{&1, meta, nil})
      :alias -> atomize(cst, view, opts, acc, nid, val, &{:__aliases__, meta, [&1]})
      _ -> {error_ast(cst, view), acc, nid}
    end
  end

  # Atomize a source-derived name via `build`, or — under `existing_atoms_only` for a missing
  # atom — emit a lowerer diagnostic and an error node (never raise).
  defp atomize(cst, view, opts, acc, nid, val, build) do
    case to_atom(val, opts) do
      {:ok, atom} ->
        {build.(atom), acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(acc, nid, :lowerer, :error, :nonexistent_atom, name_span(cst, view), %{
            name: val
          })

        {{:__error__, error_meta(cst, view), %{diag_ids: [id]}}, acc, nid}
    end
  end

  # One trivial clause per node kind (keeps each clause's cyclomatic complexity at 1).
  defp lower_node(cst, view, opts, acc, nid),
    do: lower_kind(CST.node_kind(cst), CST.children(cst), cst, view, opts, acc, nid)

  defp lower_kind(:expr_list, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(:paren, ch, _cst, view, opts, acc, nid),
    do: lower_paren(ch, view, opts, acc, nid)

  defp lower_kind(:binary_op, ch, _cst, view, opts, acc, nid),
    do: lower_binary(ch, view, opts, acc, nid)

  defp lower_kind(:unary_op, ch, _cst, view, opts, acc, nid),
    do: lower_unary(ch, view, opts, acc, nid)

  defp lower_kind(:list, ch, _cst, view, opts, acc, nid), do: lower_list(ch, view, opts, acc, nid)

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

  defp lower_kind(_other, _ch, cst, view, _opts, acc, nid), do: {error_ast(cst, view), acc, nid}

  defp lower_block([], _view, _opts, acc, nid), do: {{:__block__, [], []}, acc, nid}
  defp lower_block([only], view, opts, acc, nid), do: lower(only, view, opts, acc, nid)

  defp lower_block(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_each(children, view, opts, acc, nid)
    {{:__block__, [], asts}, acc, nid}
  end

  # Parentheses are transparent in the AST (they only carry metadata upstream).
  defp lower_paren([], _view, _opts, acc, nid), do: {{:__block__, [], []}, acc, nid}

  defp lower_paren([inner | _maybe_missing], view, opts, acc, nid),
    do: lower(inner, view, opts, acc, nid)

  defp lower_binary([lhs, op_leaf, rhs], view, opts, acc, nid) do
    {l, acc, nid} = lower(lhs, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)
    {{op_atom(op_leaf, view), op_meta(op_leaf, view), [l, r]}, acc, nid}
  end

  defp lower_unary([op_leaf, operand], view, opts, acc, nid) do
    {o, acc, nid} = lower(operand, view, opts, acc, nid)
    {{op_atom(op_leaf, view), op_meta(op_leaf, view), [o]}, acc, nid}
  end

  # A list literal lowers to the Elixir list of its lowered elements.
  defp lower_list(children, view, opts, acc, nid), do: lower_each(children, view, opts, acc, nid)

  # 2-tuples are literal `{a, b}`; all other arities use `{:{}, [], elems}`.
  defp lower_tuple(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_each(children, view, opts, acc, nid)

    case asts do
      [a, b] -> {{a, b}, acc, nid}
      _ -> {{:{}, [], asts}, acc, nid}
    end
  end

  # `f(args)` => `{fun_atom, meta, lowered_args}`. The callee name respects the atom policy.
  defp lower_call([callee | arg_children], view, opts, acc, nid) do
    {args, acc, nid} = lower_args(arg_children, view, opts, acc, nid)
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
            %{name: name}
          )

        {{:__error__, tmeta(view, idx), %{diag_ids: [id]}}, acc, nid}
    end
  end

  # Alias chain: `{:__aliases__, meta, segments}`. A leading alias segment contributes its atom;
  # a leading non-alias base (e.g. `foo.Bar`) contributes its lowered AST as the first segment.
  # (Alias segment atoms are not gated by `existing_atoms_only` — module names are a controlled
  # namespace, not arbitrary user atoms.)
  defp lower_alias([first | rest], view, opts, acc, nid) do
    rest_atoms =
      Enum.map(rest, fn leaf -> String.to_atom(Tokens.value(view, CST.token_index(leaf))) end)

    meta = error_meta(first, view)

    if CST.tag(first) == :token and Tokens.kind(view, CST.token_index(first)) == :alias do
      seg0 = String.to_atom(Tokens.value(view, CST.token_index(first)))
      {{:__aliases__, meta, [seg0 | rest_atoms]}, acc, nid}
    else
      {base_ast, acc, nid} = lower(first, view, opts, acc, nid)
      {{:__aliases__, meta, [base_ast | rest_atoms]}, acc, nid}
    end
  end

  # `a.b` / `a.b(args)` => `{{:., m, [base, name]}, m, args}` (zero-arg form is just `args = []`).
  defp lower_remote_call([base, name_leaf | arg_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {args, acc, nid} = lower_args(arg_children, view, opts, acc, nid)
    idx = CST.token_index(name_leaf)
    meta = tmeta(view, idx)

    case to_atom(Tokens.value(view, idx), opts) do
      {:ok, name} -> {{{:., meta, [base_ast, name]}, meta, args}, acc, nid}
      :error -> name_error(name_leaf, view, acc, nid)
    end
  end

  # `a.(args)` => `{{:., m, [base]}, m, args}`.
  defp lower_anon_call([base | arg_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {args, acc, nid} = lower_args(arg_children, view, opts, acc, nid)
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
  defp lower_kw_pair([key_leaf, val], view, opts, acc, nid) do
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    {{String.to_atom(Tokens.value(view, CST.token_index(key_leaf))), v}, acc, nid}
  end

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

  # `<<...>>` => `{:<<>>, [], elems}` (segments incl. `::` are ordinary expressions).
  defp lower_bitstring(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_each(children, view, opts, acc, nid)
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
  defp lower_stab_args(args_node, view, opts, acc, nid) do
    case CST.children(args_node) do
      [{:node, :stab_when, _sp, when_ch, _f, _d}] ->
        {parts, acc, nid} = lower_each(when_ch, view, opts, acc, nid)
        {[{:when, [], parts}], acc, nid}

      children ->
        lower_each(children, view, opts, acc, nid)
    end
  end

  # Stab clause body -> nil (empty), the expression (one), or a `__block__` (many).
  defp lower_stab_body(body_node, view, opts, acc, nid) do
    case CST.children(body_node) do
      [] -> {nil, acc, nid}
      [one] -> lower(one, view, opts, acc, nid)
      many -> wrap_block(lower_each(many, view, opts, acc, nid))
    end
  end

  defp wrap_block({asts, acc, nid}), do: {{:__block__, [], asts}, acc, nid}

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

  defp tmeta(view, idx) do
    case Tokens.span(view, idx) do
      {sl, sc, _el, _ec} -> [line: sl, column: sc]
      nil -> []
    end
  end

  defp span_meta({sl, sc, _el, _ec}), do: [line: sl, column: sc]
  defp span_meta(_), do: []

  defp to_atom(bin, opts) do
    if Keyword.get(opts, :existing_atoms_only, false) do
      {:ok, String.to_existing_atom(bin)}
    else
      {:ok, String.to_atom(bin)}
    end
  rescue
    ArgumentError -> :error
  end
end
