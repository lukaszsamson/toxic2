defmodule Toxic2 do
  @moduledoc """
  Toxic 2 — tolerant-only Elixir lexer + parser (lowerer lands in phase 6).

  See `TOXIC_2.md` (repo root) for the canonical design spec.

  - `tokenize/2` — batch lexer → `{tokens, warnings}`.
  - `parse/2` — lexer + parser → `{cst, diagnostics}` (a green CST; AST lowering is phase 6).
  """

  @doc """
  Tokenize Elixir source into `{tokens, warnings}`, both in source order.

  Delegates to `Toxic2.Lexer.tokenize/2`.
  """
  @spec tokenize(binary(), keyword()) :: {[Toxic2.Token.t()], [term()]}
  defdelegate tokenize(source, opts \\ []), to: Toxic2.Lexer

  @doc """
  Parse Elixir source into `{cst, diagnostics}` (green CST + combined diagnostic stream).

  The parser is tolerant-only and currently covers the phase-5 grammar subset (expression lists,
  literals, identifiers/aliases/atoms, prefix/infix operators, parentheses). Delegates to
  `Toxic2.Parser.parse/2`.
  """
  @spec parse(binary(), keyword()) :: Toxic2.Parser.result()
  defdelegate parse(source, opts \\ []), to: Toxic2.Parser

  @doc """
  Full pipeline: tokenize → parse → lower. Returns `{ast, diagnostics}` where `ast` is the
  Elixir AST (exact for valid code in the supported grammar subset, best-effort with
  `{:__error__, ...}` nodes otherwise) and `diagnostics` is the combined source-ordered stream.
  """
  @spec parse_to_ast(binary(), keyword()) :: {Macro.t(), [Toxic2.Diagnostic.t()]}
  def parse_to_ast(source, opts \\ []) when is_binary(source) do
    {view, warnings} = Toxic2.Tokens.from_source(source, opts)
    {cst, parser_diags} = Toxic2.Parser.parse_tokens(view)
    # Lowerer ids continue past lexer/parser ids so the combined stream stays unique.
    {ast, lowerer_diags} = Toxic2.Lower.to_ast(cst, view, opts, next_id(warnings, parser_diags))
    {ast, Toxic2.Diagnostics.merge_sorted([warnings, parser_diags, lowerer_diags])}
  end

  defp next_id(warnings, parser_diags) do
    Enum.concat(warnings, parser_diags)
    |> Enum.reduce(0, fn d, max -> max(max, elem(d, 0)) end)
    |> Kernel.+(1)
  end
end
