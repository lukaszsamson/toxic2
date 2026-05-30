defmodule Toxic2.ConformanceTest do
  use ExUnit.Case, async: true

  # This file is in the oracle allowlist (`*conformance*`): the reference parser is the
  # intended tool here. It drives the harness's `evaluate/1` over the curated corpus so
  # conformance is part of `mix toxic2.check` (the quality gate), with a per-source failure.

  alias Mix.Tasks.Toxic2.Conformance, as: Harness
  alias Toxic2.Conformance.Corpus

  describe "valid corpus → AST matches the reference parser (after metadata normalization)" do
    for %{source: src} <- Corpus.valid() do
      test "lowers #{inspect(src)} to the reference AST" do
        assert Harness.evaluate(unquote(src)) == :pass
      end
    end
  end

  describe "invalid corpus → tolerant (no crash, an :error diagnostic)" do
    for %{source: src} <- Corpus.invalid() do
      test "tolerates #{inspect(src)}" do
        assert Harness.evaluate(unquote(src)) == :ok_invalid
      end
    end
  end
end
