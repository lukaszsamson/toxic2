defmodule Toxic2.ImportedParserConformanceTest do
  # Opt-in regression guard for the imported PARSER backlog (run: `mix test --include imported`).
  # It does not assert the whole corpus passes — only that the frozen floor (sources already
  # green, captured in imported_freeze_parser.json) never regresses. Promote new passes with
  # `mix toxic2.conformance.imported --update-freeze`.
  use ExUnit.Case, async: true
  @moduletag :imported

  alias Mix.Tasks.Toxic2.Conformance, as: Harness

  @green [:pass, :ok_invalid]

  test "every frozen imported-parser source still parses green" do
    frozen = "imported_freeze_parser.json" |> File.read!() |> :json.decode()

    regressed =
      for src <- frozen,
          status = Harness.evaluate(src),
          status not in @green,
          do: {src, status}

    assert regressed == [],
           "imported-parser freeze regressions (#{length(regressed)}):\n" <>
             Enum.map_join(Enum.take(regressed, 30), "\n", fn {s, st} ->
               "  #{inspect(s)} -> #{inspect(st)}"
             end)
  end
end
