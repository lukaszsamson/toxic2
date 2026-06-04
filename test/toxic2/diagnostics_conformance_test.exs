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
    # totality (P5): the call returns `{ast, diagnostics}` and never raises — the match itself proves
    # the shape (a non-tuple or a raise fails here). `ast` may legitimately be any quoted term,
    # including `nil` (for the input `"nil"`), so we don't constrain it; `diagnostics` is a list.
    {_ast, diags} = Toxic2.parse_to_ast(src)
    assert is_list(diags)
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

    test "keyword colon must be followed by whitespace" do
      # `foo:bar` / `foo:1` / `Foo:1` / `foo:` at EOF are rejected (keyword needs a trailing space)
      assert_classified("[foo:bar]")
      assert_classified("[a:1]")
      assert_classified("[a: 1, b:2]")
      assert_classified("[Foo:1]")
      assert_classified("foo:")
      # a properly-spaced keyword stays valid (space, tab, or newline all count)
      assert_classified("[foo: 1]")
      assert_classified("%{foo: 1}")
      assert_classified("[foo:\n1]")
      assert_classified("[Foo: 1]")
    end

    test "an atom literal cannot be followed by an alias" do
      # `:foo.Bar` / `nil.Bar` etc. — the base of a `.Alias` must not be a bare atom
      assert_classified(":foo.Bar")
      assert_classified("nil.Bar")
      assert_classified("true.Bar")
      assert_classified(~S(:"foo".Bar))
      assert_classified(":foo.Bar.Baz")
      # non-atom bases stay valid
      assert_classified("__MODULE__.Bar")
      assert_classified("x.Bar")
      assert_classified("@x.Bar")
      assert_classified(":foo.bar")
      assert_classified("Foo.Bar")
    end

    test "consecutive semicolons are rejected (single/leading/trailing are fine)" do
      assert_classified(";;")
      assert_classified("a;;b")
      assert_classified("a ; ; b")
      assert_classified("a;\n;b")
      # a single, leading, or trailing semicolon is valid
      assert_classified(";")
      assert_classified(";a")
      assert_classified("a;")
      assert_classified("a;b;c")
    end

    test "aliases must be pure ASCII (a non-ASCII module name is rejected)" do
      assert_classified("Foó")
      assert_classified("Café")
      assert_classified("Módulo")
      assert_classified("Café.Bar")
      assert_classified("x = Café")
      # but a non-ASCII KEYWORD key is a valid atom, and unicode atoms / vars are fine
      assert_classified("[Café: 1]")
      assert_classified(":Σ")
      assert_classified("café")
    end

    test "already-covered escape / sigil / bidi rejections still hold" do
      assert_classified("\"\\xG\"")
      assert_classified("\"\\u{110000}\"")
      assert_classified("~Ab(foo)")
    end

    test "unsupported line-break chars in a comment are rejected" do
      # VT/FF/NEL/LS/PS inside a `#` comment (an invisible line break) — Elixir errors
      for cp <- [0x000B, 0x000C, 0x0085, 0x2028, 0x2029] do
        assert_classified("# x" <> <<cp::utf8>> <> "\n1")
      end

      assert_classified("# a normal comment\n1")
    end

    test "a single-quoted charlist with a non-UTF-8 byte is rejected" do
      # `'\xFF'` yields the raw byte (not codepoint U+00FF), which is invalid UTF-8 for a charlist
      assert_classified("'\\xFF'")
      assert_classified("'''\n\\xFF\n'''")
      # the codepoint escape and a double-quoted string are fine (`<<255>>` is a valid binary)
      assert_classified("'\\x{FF}'")
      assert_classified("\"\\xFF\"")
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

      # a single-quoted atom that needs no quotes carries BOTH the single-quote deprecation and the
      # unnecessary-quote note (matching Elixir); a double-quoted one carries only the latter.
      codes = fn src -> Enum.map(warnings(src), &Diagnostic.code/1) |> Enum.sort() end
      assert codes.(":'foo'") == [:deprecated_quoted_atom, :unnecessary_quoted_atom]
      assert codes.(~S(:"foo")) == [:unnecessary_quoted_atom]
      # an atom that genuinely needs quotes warns only about the single quotes (not "unnecessary")
      assert codes.(":'foo bar'") == [:deprecated_quoted_atom]
      assert warnings(~S(:"foo bar")) == []
    end

    test "quoted keyword keys / remote calls warn (unnecessary or single-quote deprecation)" do
      codes = fn src -> Enum.map(warnings(src), &Diagnostic.code/1) |> Enum.sort() end
      # unnecessary quotes take precedence over the single-quote deprecation for keywords
      assert codes.("['foo': 1]") == [:unnecessary_quoted_keyword]
      assert codes.(~S(["foo": 1])) == [:unnecessary_quoted_keyword]
      # a single-quoted call carries both; a double-quoted one only the unnecessary note
      assert codes.("a.'foo'()") == [:deprecated_quoted_call, :unnecessary_quoted_call]
      assert codes.("a.\"foo\"()") == [:unnecessary_quoted_call]
      # quotes that are actually required don't trigger the unnecessary note
      assert warnings("[\"foo bar\": 1]") == []
      assert warnings("a.\"foo bar\"()") == []
    end

    test "an identifier/atom ending in ! or ? immediately before = is ambiguous" do
      codes = fn src -> Enum.map(warnings(src), &Diagnostic.code/1) end
      assert codes.("a!=b") == [:ambiguous_bang_before_equals]
      assert codes.("a?=1") == [:ambiguous_bang_before_equals]
      assert codes.(":foo!=1") == [:ambiguous_bang_before_equals]
      # a space on either side (or no following `=`) removes the ambiguity
      assert warnings("foo! = 1") == []
      assert warnings("foo? =1") == []
      assert warnings("x = foo!") == []
      assert warnings("a != b") == []
    end

    test "a 4th repeat of a &&& / ^^^ / +++ / --- operator char warns" do
      # `&&&` / `+++` / `---` aren't deprecated ops, so only the too-many-same-char warning
      for src <- ["a &&&& b", "a ++++ b", "a ---- b"] do
        assert errors(src) == []
        assert Enum.map(warnings(src), &Diagnostic.code/1) == [:too_many_same_char]
      end

      # `^^^` IS deprecated, so `^^^^` carries both warnings (matching Elixir)
      assert errors("a ^^^^ b") == []

      assert Enum.sort(Enum.map(warnings("a ^^^^ b"), &Diagnostic.code/1)) ==
               [:deprecated_op_xor, :too_many_same_char]

      # the 3-char operators themselves are fine
      assert warnings("a &&& b") == []
      assert warnings("a +++ b") == []
    end

    test "a heredoc line outdented past its closing delimiter warns" do
      outdented = "x = \"\"\"\n  hi\n    \"\"\"\n"
      aligned = "x = \"\"\"\n    hi\n    \"\"\"\n"
      assert Enum.map(warnings(outdented), &Diagnostic.code/1) == [:outdented_heredoc]
      assert warnings(aligned) == []
    end

    test "an unsupported line-break char in a string/sigil/heredoc is an error (Elixir 1.20)" do
      # Elixir 1.20 made `?break` chars inside strings/sigils/heredocs an ERROR (was a warning);
      # a bare CR (0x0D) is also a break char now (CRLF stays a normal newline).
      for cp <- [0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029] do
        c = <<cp::utf8>>

        for src <- ["\"x" <> c <> "\"", "~s/x" <> c <> "/", "~S/x" <> c <> "/"] do
          assert_classified(src)
          assert :invalid_break in Enum.map(errors(src), &Diagnostic.code/1)
        end
      end

      # CRLF in a string is a normal newline, not a break error
      assert warnings("\"x\r\ny\"") == []
      assert errors("\"x\r\ny\"") == []
    end

    test "confusable identifiers warn (UTS-39)" do
      cyr_a = <<0x0430::utf8>>
      # Cyrillic `а` and Latin `a` share a skeleton — flagged when both appear
      assert Enum.map(warnings(cyr_a <> " = 1\na = 2"), &Diagnostic.code/1) == [
               :confusable_identifier
             ]

      assert Enum.map(warnings("%{" <> cyr_a <> ": a}"), &Diagnostic.code/1) == [
               :confusable_identifier
             ]

      # a lone non-ASCII identifier, or distinct unicode names, do not warn
      assert warnings(cyr_a <> " = 1") == []
      assert warnings("café = 1\ncafe = 2") == []
      # ASCII-only code never runs the lint
      assert warnings("a = 1\nb = 2") == []
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

    # Regression: a no-parens call whose args are ALL keywords is a SINGLE (keyword-list) argument,
    # so it is not "nested no-parens keyword" — `defmodule Foo, do: defstruct a: 1, b: 2` is common
    # and must stay clean (was a false positive caught by the fuzzer corpus on real earmark code).
    test "kw-only no-parens call as a keyword value does not warn" do
      assert warnings("defmodule Blank, do: defstruct lnb: 0, line: \"\"") == []
      assert warnings("foo do: defstruct a: 1, b: 2") == []
      assert warnings("foo(x: bar a: 1)") == []
      # a MULTI-positional no-parens kw value still warns
      assert Enum.map(warnings("foo a: bar b, c"), &Diagnostic.code/1) == [
               :nested_no_parens_keyword
             ]
    end

    # Regression: `(;)` is a `;`-block, not the `empty_paren` rule — and `fn () -> …` parens are a
    # clause-head argument list, not an expression — so neither warns; only a literal `()` does.
    test "empty-paren warning is precise (() yes; (;) and fn () no)" do
      assert Enum.map(warnings("()"), &Diagnostic.code/1) == [:empty_paren]
      assert Enum.map(warnings("( )"), &Diagnostic.code/1) == [:empty_paren]
      assert warnings("(;)") == []
      assert warnings("fn () -> 1 end") == []
      assert warnings("fn () when node() == x -> true end") == []
    end
  end
end
