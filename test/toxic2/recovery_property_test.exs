defmodule Toxic2.RecoveryPropertyTest do
  use ExUnit.Case, async: true

  # Phase 11: parser-only recovery + invalid-code property harness.
  #
  # The tolerant contract (P1/P3/P5): for ANY input — including truncated, mutated, and pure
  # random bytes — `Toxic2.tokenize/2` and `Toxic2.parse_to_ast/2` must NEVER raise; they always
  # return tokens and `{ast, diagnostics}`. This harness mutates valid sources and throws random
  # bytes at the pipeline, asserting that contract holds (it does NOT use the oracle).
  #
  # Atomization runs with `existing_atoms_only: true` so the (large) input volume can't grow the
  # atom table. Random generation is seeded for reproducibility (phase 12 ports any failure here
  # into a permanent fixture).

  alias Toxic2.Conformance.Corpus

  @opts [existing_atoms_only: true]
  @seeds Enum.map(Corpus.all(), & &1.source)

  # `:ok` if the whole pipeline is total on `src`, else a descriptive failure tuple.
  defp total(src) do
    {_tokens, _warnings} = Toxic2.tokenize(src)

    case Toxic2.parse_to_ast(src, @opts) do
      {_ast, diags} when is_list(diags) -> :ok
      other -> {:bad_return, other}
    end
  rescue
    e -> {:raise, Exception.message(e)}
  catch
    kind, reason -> {:throw, {kind, reason}}
  end

  defp first_failure(inputs),
    do: Enum.find_value(inputs, fn s -> total(s) != :ok && {s, total(s)} end)

  describe "totality under mutation (the tolerant contract, P5)" do
    test "every byte-prefix (truncation) of every seed is total" do
      prefixes = for s <- @seeds, n <- 0..byte_size(s), do: binary_part(s, 0, n)
      assert first_failure(prefixes) == nil
    end

    test "every single-byte deletion of every seed is total" do
      deletions =
        for s <- @seeds,
            byte_size(s) > 0,
            i <- 0..(byte_size(s) - 1),
            do: binary_part(s, 0, i) <> binary_part(s, i + 1, byte_size(s) - i - 1)

      assert first_failure(deletions) == nil
    end

    test "structural-token insertions at every position are total" do
      inject = [
        "(",
        ")",
        "[",
        "]",
        "{",
        "}",
        "<<",
        ">>",
        "do",
        "end",
        "fn",
        "->",
        "::",
        "|",
        ",",
        ";",
        "\"",
        "'",
        "\"\"\"",
        "\\",
        "#",
        "~r/",
        "\#{",
        "%{",
        "@"
      ]

      insertions =
        for s <- @seeds,
            tok <- inject,
            pos <- [0, div(byte_size(s), 2), byte_size(s)],
            do: binary_part(s, 0, pos) <> tok <> binary_part(s, pos, byte_size(s) - pos)

      assert first_failure(insertions) == nil
    end

    test "random byte strings are total" do
      :rand.seed(:exsss, {11, 22, 33})

      randoms =
        for _ <- 1..20_000 do
          for(_ <- 1..:rand.uniform(60), into: <<>>, do: <<:rand.uniform(255)>>)
        end

      assert first_failure(randoms) == nil
    end

    test "random ASCII/operator soup is total" do
      :rand.seed(:exsss, {99, 88, 77})
      alphabet = ~c"abc09 \n\t().[]{}<>,;:|+-*/=&^~!@%\"'#_"

      soup =
        for _ <- 1..20_000 do
          for(_ <- 1..:rand.uniform(80), into: <<>>, do: <<Enum.random(alphabet)>>)
        end

      assert first_failure(soup) == nil
    end
  end

  describe "invalid-UTF-8 totality fixtures (phase 11 fuzz finds — the oracle can't even be run on these)" do
    # Each crashed the pipeline before the fix; pinned here so a regression is caught directly.
    @utf8_fixtures [
      # truncated multibyte mid-identifier (`αβ` cut) — vendored `String.Tokenizer.continue`
      <<206, 177, 206>>,
      # a charlist with invalid bytes — `build_charlist`/`String.to_charlist`
      <<?', 185, 151>>,
      # `\` before an invalid byte inside a string — `Lexer.esc`
      <<?", ?\\, 160, 183, ?">>
    ]

    test "lex + parse are total on truncated/invalid UTF-8" do
      for src <- @utf8_fixtures, do: assert(total(src) == :ok)
    end
  end

  describe "parser recovery (invalid code yields a best-effort AST + an :error diagnostic)" do
    @recoverable [
      "[1, 2",
      "foo(",
      "%{a: ",
      "fn x ->",
      "case x do",
      "1 +",
      "a.",
      ")",
      "<<1",
      "if x do",
      "def f(a, b"
    ]

    test "recovers from common truncations: a best-effort AST plus at least one error diagnostic" do
      for src <- @recoverable do
        {ast, diags} = Toxic2.parse_to_ast(src, @opts)
        assert ast != nil, "expected a best-effort AST for #{inspect(src)}"

        assert Enum.any?(diags, &(elem(&1, 2) == :error)),
               "expected an :error diagnostic for the invalid #{inspect(src)}"
      end
    end
  end
end
