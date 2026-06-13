defmodule Toxic2 do
  @moduledoc """
  Toxic 2 — tolerant-only Elixir lexer + parser + lowerer.

  See `TOXIC_2.md` (repo root) for the canonical design spec.

  - `tokenize/2` — batch lexer → `{tokens, notices}` (notices are out-of-band lexer warnings).
  - `parse/2` — lexer + parser → `{cst, diagnostics}` (a green CST + combined diagnostic stream).
  - `parse_to_ast/2` — full pipeline (lex → parse → lower) → `{ast, diagnostics}`.
  """

  @doc """
  Tokenize Elixir source into `{tokens, notices}`, both in source order (`notices` are the lexer's
  out-of-band warnings).

  Delegates to `Toxic2.Lexer.tokenize/2`.
  """
  @spec tokenize(binary(), keyword()) :: {[Toxic2.Token.t()], [term()]}
  defdelegate tokenize(source, opts \\ []), to: Toxic2.Lexer

  @doc """
  Parse Elixir source into `{cst, diagnostics}` (green CST + combined diagnostic stream).

  The parser is tolerant-only and covers the full Elixir grammar (the whole distribution
  round-trips — see the conformance suite). Delegates to `Toxic2.Parser.parse/2`.
  """
  @spec parse(binary(), keyword()) :: Toxic2.Parser.result()
  defdelegate parse(source, opts \\ []), to: Toxic2.Parser

  @doc """
  Full pipeline: tokenize → parse → lower. Returns `{ast, diagnostics}` where `ast` is the
  Elixir AST (exact for valid code in the supported grammar subset, best-effort with
  `{:__error__, ...}` nodes otherwise) and `diagnostics` is the combined source-ordered stream.

  Options:

    * `:existing_atoms_only` — atomize source names with `String.to_existing_atom/1` (tolerant of
      untrusted input; missing atoms become `{:__error__, ...}` with a lowerer diagnostic).
    * `:range` (default `false`) — attach `range: {{start_line, start_col}, {end_line, end_col}}`
      (end exclusive) to every AST node that corresponds to source, alongside the usual
      `line:`/`column:` anchor. Macro-generated nodes (interpolation's `Kernel.to_string`/`::`,
      a sigil's inner `<<>>`, …) carry no range. A parent's range always contains every child's.
    * `:literal_encoder` — `fn value, meta -> {:ok, ast} | {:error, reason} end`, called for each
      literal (integers, floats, atoms, strings, charlists, `true`/`false`/`nil`, list and 2-tuple
      containers, keyword keys) so bare literals — which have no metadata slot in the AST — can be
      wrapped to carry position info. Elixir-compatible; combine with `:range` for literal ranges.
    * `:token_metadata` (default `false`) — attach Elixir's `token_metadata: true` meta keys:
      `closing:`, `do:`/`end:`, `delimiter:`, `token:` (raw numeric/char text), `format: :keyword`,
      `assoc:`, `last:`, `from_brackets:`, `from_interpolation:`, `indentation:` (heredocs),
      `no_parens:`, `parens:`, `newlines:`, and `end_of_expression: [newlines:, line:, column:]`.
      Source-derived; pair with `:literal_encoder` so literals carry meta too (matching how the
      oracle threads `token_metadata` through the encoder).
  """
  @spec parse_to_ast(binary(), keyword()) :: {Macro.t(), [Toxic2.Diagnostic.t()]}
  def parse_to_ast(source, opts \\ []) when is_binary(source) do
    {view, lex_notices} = Toxic2.Tokens.from_source(source, opts)
    {cst, parser_diags} = Toxic2.Parser.parse_tokens(view)

    # Ids: parser first, then lexer warning notices, then the lowerer — each range disjoint so the
    # combined stream stays unique (lexer ERRORS are already numbered by the parser in-stream).
    {lex_diags, nid} =
      Toxic2.Diagnostics.number(lex_notices, Toxic2.Diagnostics.next_id(parser_diags))

    {ast, lowerer_diags} = Toxic2.Lower.to_ast(cst, view, source, opts, nid)

    {ast, Toxic2.Diagnostics.merge_sorted([lex_diags, parser_diags, lowerer_diags])}
  end

  @doc """
  Like `parse_to_ast/2` but also returns the source's comments — `{ast, diagnostics, comments}`.

  Each comment is a map `%{line:, column:, previous_eol_count:, next_eol_count:, text:}` matching
  `Code.string_to_quoted_with_comments/2` (1-based positions; `text` includes the leading `#`).
  Comments are collected by the lexer and never reach the parser, so the `ast`/`diagnostics` are
  identical to `parse_to_ast/2`. Accepts the same options as `parse_to_ast/2`.
  """
  @spec string_to_quoted_with_comments(binary(), keyword()) ::
          {Macro.t(), [Toxic2.Diagnostic.t()], [map()]}
  def string_to_quoted_with_comments(source, opts \\ []) when is_binary(source) do
    {view, lex_notices, comments} = Toxic2.Tokens.from_source_with_comments(source, opts)
    {cst, parser_diags} = Toxic2.Parser.parse_tokens(view)

    {lex_diags, nid} =
      Toxic2.Diagnostics.number(lex_notices, Toxic2.Diagnostics.next_id(parser_diags))

    {ast, lowerer_diags} = Toxic2.Lower.to_ast(cst, view, source, opts, nid)

    {ast, Toxic2.Diagnostics.merge_sorted([lex_diags, parser_diags, lowerer_diags]), comments}
  end
end
