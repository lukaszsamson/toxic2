defmodule Toxic2.ImportedWarningsConformanceTest do
  use ExUnit.Case, async: true

  # Ported from `toxic_parser/test/warnings_test.exs` — its INPUT cases are reused verbatim, but the
  # assertion follows toxic2's design (per the diagnostics plan): we validate behavior CLASS against
  # the live oracle (`:ok | :warning | :error`), never message-text parity. So an input the oracle
  # WARNS on must make toxic2 warn (and never error); an input the oracle ACCEPTS cleanly must keep
  # toxic2 clean; an input the oracle REJECTS must make toxic2 error. This is robust to Elixir
  # version drift (e.g. `?\a` no longer warns, `Foo."bar"[]` now errors — both handled by the
  # oracle classification rather than a frozen expectation).

  alias Toxic2.Diagnostic

  defp oracle_class(src) do
    {res, diags} = Code.with_diagnostics(fn -> Code.string_to_quoted(src) end)

    cond do
      match?({:error, _}, res) -> :error
      diags != [] -> :warning
      true -> :ok
    end
  rescue
    _ -> :error
  end

  defp toxic2_class(src) do
    {_ast, diags} = Toxic2.parse_to_ast(src)

    cond do
      Enum.any?(diags, &(Diagnostic.severity(&1) == :error)) -> :error
      Enum.any?(diags, &(Diagnostic.severity(&1) == :warning)) -> :warning
      true -> :ok
    end
  end

  defp assert_conforms(src) do
    assert toxic2_class(src) == oracle_class(src),
           "classification mismatch for #{inspect(src)}: " <>
             "oracle=#{oracle_class(src)} toxic2=#{toxic2_class(src)}"
  end

  # The codes toxic2 attaches, for the cases where we also pin the diagnostic (not just the class).
  defp toxic2_codes(src) do
    {_ast, diags} = Toxic2.parse_to_ast(src)

    diags
    |> Enum.filter(&(Diagnostic.severity(&1) in [:warning, :error]))
    |> Enum.map(&Diagnostic.code/1)
  end

  describe "parser-level warnings (reused inputs, oracle-classified)" do
    test "deprecated not expr1 in expr2" do
      assert_conforms("not left in right")
      assert :deprecated_not_in in toxic2_codes("not left in right")
    end

    test "ambiguous pipe into call" do
      src = """
      [5, 6, 7, 3]
      |> Enum.map_join "", &(Integer.to_string(&1))
      |> String.to_integer
      """

      assert_conforms(src)
      assert :ambiguous_pipe in toxic2_codes(src)
    end

    test "missing parens inside keyword" do
      src = """
      quote do
        IO.inspect arg, label: if true, do: "foo", else: "baz"
      end
      """

      assert_conforms(src)
      assert :nested_no_parens_keyword in toxic2_codes(src)
    end

    test "trailing comma in call" do
      assert_conforms("Keyword.merge([], foo: 1,)")
      assert :trailing_comma in toxic2_codes("Keyword.merge([], foo: 1,)")
    end

    test "empty parentheses expression" do
      assert_conforms("()")
      assert :empty_paren in toxic2_codes("()")
    end

    test "empty stab clause" do
      assert_conforms("fn x -> end")
      assert :empty_stab_clause in toxic2_codes("fn x -> end")
    end

    test "missing parens after operator" do
      src = """
      quote do
        case do
        end || raise 1, 2
      end
      """

      assert_conforms(src)
      assert :no_parens_after_do_op in toxic2_codes(src)
    end
  end

  describe "lexer-level warnings (reused inputs, oracle-classified)" do
    # `{input, expected_toxic2_code_present}` — the code is asserted only when the oracle warns.
    cases = [
      {"'''\nhello\n'''", :deprecated_charlist},
      {"'hello'", :deprecated_charlist},
      {":::", :ambiguous_quoted_atom},
      {":'1hello'", :deprecated_quoted_atom},
      {":'hello'", :unnecessary_quoted_atom},
      {":\"hello\"", :unnecessary_quoted_atom},
      {"'hello': 1", :unnecessary_quoted_keyword},
      {"\"hello\": 1", :unnecessary_quoted_keyword},
      {"&&&& true", :too_many_same_char},
      {"|||| true", :too_many_same_char},
      {"++++", :too_many_same_char},
      {"----", :too_many_same_char},
      {"^^^^", :too_many_same_char},
      {":foo!= 1", :ambiguous_bang_before_equals},
      {"foo!= 1", :ambiguous_bang_before_equals},
      {":foo?= 1", :ambiguous_bang_before_equals},
      {"foo?= 1", :ambiguous_bang_before_equals},
      {"1 ^^^ 2", :deprecated_op_xor},
      {"~~~1", :deprecated_op_bnot},
      {"1 <|> 2", :deprecated_op_pipe},
      {"Foo.'1bar'", :deprecated_quoted_call},
      {"Foo.'bar'", :unnecessary_quoted_call},
      {"Foo.\"bar\"", :unnecessary_quoted_call},
      {"Foo.\"bar\"()", :unnecessary_quoted_call},
      {"Foo.\"bar\" do\n:ok\nend", :unnecessary_quoted_call},
      {"~S|foo\\|", :deprecated_sigil_escape},
      {"?\\q", :unknown_char_escape},
      {"?\\t", :unusual_char_literal}
    ]

    for {src, code} <- cases do
      test "#{inspect(src)} (#{code})" do
        src = unquote(src)
        assert_conforms(src)

        # when the oracle warns, toxic2 must carry the expected code (it may carry more)
        if oracle_class(src) == :warning do
          assert unquote(code) in toxic2_codes(src),
                 "expected #{unquote(code)} for #{inspect(src)}, got #{inspect(toxic2_codes(src))}"
        end
      end
    end
  end
end
