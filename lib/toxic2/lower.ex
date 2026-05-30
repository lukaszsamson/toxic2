defmodule Toxic2.Lower do
  @moduledoc """
  CST → Elixir AST lowering (see `TOXIC_2.md` → Lowering; Migration Phases #6).

  This is the **one** pass that knows Elixir AST quirks (P5). The parser builds a structural
  green CST; everything Elixir-AST-specific — variable shape, alias shape, atomization, block
  wrapping, operator nodes — lives here, so a conformance failure localizes cleanly to "CST
  wrong" (parser bug) vs "lowering rule wrong" (here).

  Phase-6 scope mirrors the phase-5 grammar: literals, identifiers/aliases/atoms, prefix/infix
  operators, parentheses, and the top-level expression list. Valid code lowers to AST comparable
  (after metadata normalization) to `Code.string_to_quoted/2`; error/missing CST nodes lower to
  `{:__error__, meta, payload}` and **never raise** (the lowerer is total).

  Atom policy: source-derived names are atomized here (never in the lexer — review #1). Pass
  `existing_atoms_only: true` to use `String.to_existing_atom/1`.
  """

  alias Toxic2.{CST, Tokens}

  @type ast :: Macro.t()

  @spec to_ast(CST.t(), Tokens.t(), keyword()) :: ast()
  def to_ast(cst, view, opts \\ []), do: lower(cst, view, opts)

  defp lower(cst, view, opts) do
    case CST.tag(cst) do
      :token -> lower_token(cst, view, opts)
      :missing -> error_ast(cst, view)
      :node -> lower_node(cst, view, opts)
    end
  end

  defp lower_token(cst, view, opts) do
    idx = CST.token_index(cst)
    val = Tokens.value(view, idx)
    meta = tmeta(view, idx)

    case Tokens.kind(view, idx) do
      :int -> val
      :flt -> val
      :char -> val
      :literal -> val
      :atom -> to_atom(val, opts)
      :identifier -> {to_atom(val, opts), meta, nil}
      :alias -> {:__aliases__, meta, [to_atom(val, opts)]}
      _ -> error_ast(cst, view)
    end
  end

  defp lower_node(cst, view, opts) do
    children = CST.children(cst)

    case CST.node_kind(cst) do
      :expr_list -> lower_block(children, view, opts)
      :paren -> lower_paren(children, view, opts)
      :binary_op -> lower_binary(children, view, opts)
      :unary_op -> lower_unary(children, view, opts)
      _ -> error_ast(cst, view)
    end
  end

  defp lower_block([], _view, _opts), do: {:__block__, [], []}
  defp lower_block([only], view, opts), do: lower(only, view, opts)

  defp lower_block(children, view, opts),
    do: {:__block__, [], Enum.map(children, &lower(&1, view, opts))}

  # Parentheses are transparent in the AST (they only carry metadata upstream).
  defp lower_paren([], _view, _opts), do: {:__block__, [], []}
  defp lower_paren([inner | _maybe_missing], view, opts), do: lower(inner, view, opts)

  defp lower_binary([lhs, op_leaf, rhs], view, opts) do
    op = Tokens.value(view, CST.token_index(op_leaf))
    {op, tmeta(view, CST.token_index(op_leaf)), [lower(lhs, view, opts), lower(rhs, view, opts)]}
  end

  defp lower_unary([op_leaf, operand], view, opts) do
    op = Tokens.value(view, CST.token_index(op_leaf))
    {op, tmeta(view, CST.token_index(op_leaf)), [lower(operand, view, opts)]}
  end

  # --- error nodes (invalid code; never raises) --------------------------

  defp error_ast(cst, view) do
    {:__error__, error_meta(cst, view), %{diag_ids: CST.diag_ids(cst)}}
  end

  defp error_meta(cst, view) do
    case CST.tag(cst) do
      :node -> span_meta(CST.span(cst))
      :token -> tmeta(view, CST.token_index(cst))
      :missing -> tmeta(view, CST.anchor_index(cst))
    end
  end

  # --- meta + atom policy ------------------------------------------------

  defp tmeta(view, idx) do
    case Tokens.span(view, idx) do
      {sl, sc, _el, _ec} -> [line: sl, column: sc]
      nil -> []
    end
  end

  defp span_meta({sl, sc, _el, _ec}), do: [line: sl, column: sc]
  defp span_meta(_), do: []

  defp to_atom(bin, opts) do
    if Keyword.get(opts, :existing_atoms_only, false),
      do: String.to_existing_atom(bin),
      else: String.to_atom(bin)
  end
end
