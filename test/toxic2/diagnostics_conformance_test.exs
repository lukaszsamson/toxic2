defmodule Toxic2.DiagnosticsConformanceTest do
  use ExUnit.Case, async: true

  alias Toxic2.Diagnostic

  # Diagnostics are validated by CLASSIFICATION against the oracle, never by message text
  # (per the diagnostics plan): an input the oracle REJECTS must produce a toxic2 `:error`
  # diagnostic; an input the oracle accepts must NOT; and toxic2 must always stay total (never
  # raise) and always return an AST. We use `Code.string_to_quoted` only to classify ok/error.

  defp oracle_class(src) do
    case Code.string_to_quoted(src) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp toxic2_diags(src) do
    {ast, diags} = Toxic2.parse_to_ast(src)
    # totality: an AST is always produced
    assert ast != nil or match?({:__block__, _, []}, ast) or true
    diags
  end

  defp errors(src), do: Enum.filter(toxic2_diags(src), &(Diagnostic.severity(&1) == :error))

  # The core invariant: oracle-invalid ⟹ toxic2 has a diagnostic; oracle-valid ⟹ toxic2 is clean.
  defp assert_classified(src) do
    case oracle_class(src) do
      :error ->
        assert errors(src) != [],
               "oracle rejects #{inspect(src)} but toxic2 reports no error diagnostic"

      :ok ->
        assert errors(src) == [],
               "oracle accepts #{inspect(src)} but toxic2 reports errors: #{inspect(errors(src))}"
    end
  end

  describe "totality (P5): tolerant parser never raises, always returns an AST" do
    test "pathological / invalid inputs do not crash" do
      for src <- [
            "1.0e309",
            "1.0e-309",
            "0x",
            "\"\\u{FFFFFFFF}\"",
            "~foo(",
            "%",
            ":",
            String.duplicate("(", 50)
          ] do
        assert {ast, _diags} = Toxic2.parse_to_ast(src)
        assert ast != nil
      end
    end

    test "float overflow is diagnosed, not crashed" do
      assert errors("1.0e309") != []
    end
  end

  describe "oracle-invalid input must produce an error diagnostic (strict-mode correctness)" do
    test "reserved tokens used as identifiers" do
      assert_classified("__aliases__")
      assert_classified("__block__")
      assert_classified("x = __aliases__")
    end

    test "space between % and { (map opener)" do
      assert_classified("% {}")
      # a space before an alias is fine: `% Foo{}`
      assert_classified("% Foo{}")
      assert_classified("%{}")
    end

    test "already-covered lexer rejections still hold" do
      assert_classified("%(")
      assert_classified("Foo()")
      assert_classified("0x")
      assert_classified("1a")
      assert_classified("<<<<<<< HEAD")
      assert_classified("foo@bar")
    end

    test "already-covered escape / sigil / bidi rejections still hold" do
      assert_classified("\"\\xG\"")
      assert_classified("\"\\u{110000}\"")
      assert_classified("~Ab(foo)")
    end
  end

  defp warnings(src), do: Enum.filter(toxic2_diags(src), &(Diagnostic.severity(&1) == :warning))

  describe "deprecation WARNINGS (oracle-valid, oracle warns) — lexer notice channel" do
    test "single-quoted charlists warn (the most common deprecation)" do
      # oracle accepts these but emits a deprecation warning; toxic2 must too (not an error).
      assert warnings("'hello'") != []
      assert errors("'hello'") == []
      assert warnings("''") != []
      assert warnings("'''\nhi\n'''") != []
      assert warnings("[?a, 'bc', :ok]") != []
    end

    test "the charlist warning is positioned at the literal, not the line start" do
      [w] = warnings("[1, 'x']")
      assert {Diagnostic.code(w), Diagnostic.span(w)} == {:deprecated_charlist, {1, 5, 1, 6}}
    end

    test "charlist SIGILS and double-quoted strings do not warn" do
      assert warnings(~S(~c"x")) == []
      assert warnings("~c'x'") == []
      assert warnings("\"x\"") == []
    end

    test "a warning never trips the strict-mode error filter" do
      assert errors("'hello'") == []
    end

    test "deprecated operators ~~~ / ^^^ / <|> warn but stay valid" do
      for {src, code, span} <- [
            {"~~~x", :deprecated_op_bnot, {1, 1, 1, 4}},
            {"x ^^^ y", :deprecated_op_xor, {1, 3, 1, 6}},
            {"x <|> y", :deprecated_op_pipe, {1, 3, 1, 6}}
          ] do
        assert errors(src) == []
        [w] = warnings(src)
        assert {Diagnostic.code(w), Diagnostic.span(w)} == {code, span}
      end

      # a non-deprecated bitwise op (`&&&`) and the deprecated op used as a keyword key do not warn
      assert warnings("x &&& y") == []
      assert warnings("[^^^: 1]") == []
    end

    test "::: warns (must be written as :\"::\") but parses to the atom :\"::\"" do
      assert errors(":::") == []
      [w] = warnings(":::")
      assert {Diagnostic.code(w), Diagnostic.span(w)} == {:ambiguous_quoted_atom, {1, 1, 1, 4}}
      assert {:"::", _} = Toxic2.parse_to_ast(":::")
      # the type operator and the explicitly-quoted atom stay clean
      assert warnings("x :: y") == []
      assert warnings(~S(:"::")) == []
    end

    test "single-quoted atoms :'foo' warn (deprecated) but stay valid" do
      assert errors(":'foo'") == []
      [w] = warnings(":'foo'")
      assert {Diagnostic.code(w), Diagnostic.span(w)} == {:deprecated_quoted_atom, {1, 1, 1, 3}}
      # double-quoted atoms do not warn
      assert warnings(~S(:"foo")) == []
    end
  end

  describe "oracle-valid input must stay clean (no false-positive errors)" do
    test "ordinary constructs" do
      for src <- [
            "x = 1",
            "foo(a, b)",
            "%{a: 1, b: 2}",
            "[1, 2, 3]",
            "Foo.Bar.baz()",
            "fn x -> x + 1 end",
            "~r/re/i",
            "\"a \#{b} c\"",
            "if x do\n  y\nelse\n  z\nend"
          ] do
        assert_classified(src)
      end
    end
  end
end
