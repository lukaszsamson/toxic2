defmodule Toxic2.SourceRanges do
  @moduledoc """
  Selection / source ranges over the green **CST** (not the lowered AST).

  `Toxic2.parse_to_ast(src, range: true)` carries a range on each AST node, but lowering DISCARDS
  CST-only structure — parenthesised groups, string/interpolation delimiters and content, operator
  tokens, quoted/interpolated keyword keys. Those are exactly what an editor needs for "expand
  selection". This engine walks the CST + token view instead, so every structural node AND every
  semantic leaf token contributes a range:

    * `(1 + 2)` yields the parens, the `1 + 2` node, and the `1` / `+` / `2` tokens;
    * `"a\#{b}c"` yields the whole string, each content fragment, the `\#{...}` body, and `b`;
    * a keyword pair yields the pair, and its key and value — even interpolated keys.

  Ranges are `{{start_line, start_col}, {end_line, end_col}}` (end-exclusive), sorted and
  de-duplicated. (Comments are not yet retained by the lexer, so comment ranges are out of scope.)
  """

  alias Toxic2.{CST, Parser, Tokens}

  @doc "All CST node + token ranges in `code`, sorted and de-duplicated."
  @spec ranges(String.t(), keyword()) :: [
          {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}}
        ]
  def ranges(code, opts \\ []) when is_binary(code) do
    {view, _warnings} = Tokens.from_source(code, opts)
    {cst, _diags} = Parser.parse_tokens(view)

    cst |> collect(view, []) |> Enum.uniq() |> Enum.sort()
  end

  # Walk the CST: every node contributes its span, every token leaf its token span (operators,
  # operands, names, string fragments, …). Missing/synthetic placeholders contribute nothing.
  defp collect({:node, _kind, span, children, _f, _d}, view, acc) do
    acc = put(span, acc)
    Enum.reduce(children, acc, &collect(&1, view, &2))
  end

  defp collect({:token, idx, _f, _d}, view, acc), do: put(Tokens.span(view, idx), acc)
  defp collect({:missing, _e, _ai, _f, _d}, _view, acc), do: acc

  defp put({sl, sc, el, ec}, acc), do: [{{sl, sc}, {el, ec}} | acc]
  defp put(_no_span, acc), do: acc

  @doc "The outer (whole-program) range, or `nil` for empty input."
  @spec outer_range(String.t()) ::
          {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}} | nil
  def outer_range(code) do
    {view, _} = Tokens.from_source(code)
    {cst, _} = Parser.parse_tokens(view)

    case CST.span(cst) do
      {sl, sc, el, ec} -> {{sl, sc}, {el, ec}}
      _ -> nil
    end
  end

  @doc """
  The ordered parent chain of ranges containing `{line, col}` — outermost first, as an LSP
  "selection range" walk would produce. Each range strictly contains the next.
  """
  @spec chain_at(String.t(), {pos_integer(), pos_integer()}) :: [
          {{pos_integer(), pos_integer()}, {pos_integer(), pos_integer()}}
        ]
  def chain_at(code, pos) do
    code
    |> ranges()
    |> Enum.filter(fn {from, to} -> leq?(from, pos) and lt?(pos, to) end)
    |> Enum.sort_by(fn {from, to} -> {from, negate(to)} end)
  end

  defp leq?({l1, c1}, {l2, c2}), do: l1 < l2 or (l1 == l2 and c1 <= c2)
  defp lt?(a, b), do: a != b and leq?(a, b)
  defp negate({l, c}), do: {-l, -c}
end
