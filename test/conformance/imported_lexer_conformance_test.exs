defmodule Toxic2.ImportedLexerConformanceTest do
  # Opt-in regression guard for the imported LEXER backlog (run: `mix test --include imported`).
  # Asserts the frozen floor (imported_freeze_lexer.json) stays "lexer-clean": when the oracle
  # tokenizer accepts a source, Toxic2 emits no `:error` token and keeps source order. Promote new
  # passes with `mix toxic2.conformance.imported --lexer --update-freeze`.
  use ExUnit.Case, async: true
  @moduletag :imported

  alias Mix.Tasks.Toxic2.Conformance.Imported

  @green [:clean, :ok_lex_invalid]

  test "every frozen imported-lexer source still lexes clean" do
    frozen = "imported_freeze_lexer.json" |> File.read!() |> :json.decode()

    regressed =
      for src <- frozen,
          status = Imported.lex_evaluate(src),
          status not in @green,
          do: {src, status}

    assert regressed == [],
           "imported-lexer freeze regressions (#{length(regressed)}):\n" <>
             Enum.map_join(Enum.take(regressed, 30), "\n", fn {s, st} ->
               "  #{inspect(s)} -> #{inspect(st)}"
             end)
  end
end
