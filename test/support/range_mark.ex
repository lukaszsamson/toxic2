defmodule Toxic2.RangeMark do
  @moduledoc """
  A tiny range-visualisation engine for tests, adapted from the `ast_show` project.

  `ast_show` needed a *custom engine* (`AST.annotate_ranges`) to RECONSTRUCT each node's outer
  range from Elixir's scattered token metadata (`closing:`/`end:`/`do:`/…). Toxic2 carries the
  range DIRECTLY on every source-corresponding node (`parse_to_ast(src, range: true)`), so the
  engine collapses to: lower with ranges + a literal encoder (so bare literals get a range too),
  collect every `meta[:range]`, and render the source with `«`/`»` at each range boundary.

  `mark/1` returns the source annotated with guillemets — the same readable golden format
  `ast_show` used — so a range is wrong iff the markers don't bracket the right span.
  """

  # Wrap literals so they carry position metadata (otherwise bare `1`/`:a`/`"s"` have no meta slot),
  # matching `ast_show`'s `literal_encoder: &{:ok, {:__block__, &2, [&1]}}`.
  defp encoder, do: fn value, meta -> {:ok, {:__block__, meta, [value]}} end

  @doc "All node ranges in `code`, as sorted, de-duplicated `{{sl,sc},{el,ec}}` (end-exclusive)."
  def ranges(code) do
    {ast, _diags} = Toxic2.parse_to_ast(code, range: true, literal_encoder: encoder())

    {_ast, ranges} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          case Keyword.get(meta, :range) do
            nil -> {node, acc}
            range -> {node, [range | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    ranges |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  The outer range of the ROOT node of `code` (the `node_range/1` of `ast_show`'s `AstUtils`, but
  read straight off the node instead of reconstructed). `nil` if the root carries no range.
  """
  def node_range(code) do
    {ast, _diags} = Toxic2.parse_to_ast(code, range: true, literal_encoder: encoder())

    case ast do
      {_form, meta, _args} when is_list(meta) -> Keyword.get(meta, :range)
      _ -> nil
    end
  end

  @doc "Source annotated with `«`/`»` at each AST-node range boundary."
  def mark(code), do: render(code, ranges(code))

  @doc "Render `source` with `«`/`»` at the boundaries of the given `{{sl,sc},{el,ec}}` ranges."
  def render(code, ranges) do
    # On a tie, emit the closing `»` before the opening `«` (no empty ranges expected, so `«»`
    # should never appear; `»«` may). Same tie-break as ast_show.
    marks =
      ranges
      |> Enum.flat_map(fn {from, to} -> [{from, 1, "«"}, {to, -1, "»"}] end)
      |> Enum.sort()

    walk(code, {1, 1}, marks, "")
  end

  defp walk(code, loc, [{loc, _prio, mark} | marks], acc),
    do: walk(code, loc, marks, acc <> mark)

  defp walk("", _loc, _marks, acc), do: acc

  defp walk(code, {line, col}, marks, acc) do
    {g, rest} = String.next_grapheme(code)
    loc = if g =~ "\n", do: {line + 1, 1}, else: {line, col + 1}
    walk(rest, loc, marks, acc <> g)
  end
end
