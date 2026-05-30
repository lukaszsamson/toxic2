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

  defp lower_node(cst, view, opts, acc, nid) do
    children = CST.children(cst)

    case CST.node_kind(cst) do
      :expr_list -> lower_block(children, view, opts, acc, nid)
      :paren -> lower_paren(children, view, opts, acc, nid)
      :binary_op -> lower_binary(children, view, opts, acc, nid)
      :unary_op -> lower_unary(children, view, opts, acc, nid)
      _ -> {error_ast(cst, view), acc, nid}
    end
  end

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
