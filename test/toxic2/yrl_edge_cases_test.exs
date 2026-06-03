defmodule Toxic2.YrlEdgeCasesTest do
  use ExUnit.Case, async: true

  alias Toxic2.Diagnostic

  # Grammar-derived edge cases from `elixir_parser.yrl` that real-corpus sweeps miss: constructs the
  # yrl REJECTS but which a permissive parser might accept. Toxic2 is tolerant (it still produces a
  # best-effort AST), so "rejected" here means it emits a `:parser`/`:error` diagnostic. We assert
  # toxic2's own diagnostics directly (no oracle dependency), each case cross-checked against the
  # grammar rule named in the comment.

  defp parser_errors(src) do
    {_ast, diags} = Toxic2.parse_to_ast(src)
    Enum.filter(diags, &(Diagnostic.phase(&1) == :parser and Diagnostic.error?(&1)))
  end

  defp assert_rejected(src) do
    assert parser_errors(src) != [], "expected a parser error for #{inspect(src)}, got none"
  end

  defp assert_accepted(src) do
    assert parser_errors(src) == [],
           "unexpected parser error for #{inspect(src)}: #{inspect(parser_errors(src))}"
  end

  defp lexer_errors(src) do
    {_ast, diags} = Toxic2.parse_to_ast(src)
    Enum.filter(diags, &(Diagnostic.phase(&1) == :lexer and Diagnostic.error?(&1)))
  end

  defp assert_lex_rejected(src) do
    assert lexer_errors(src) != [], "expected a lexer error for #{inspect(src)}, got none"
  end

  defp assert_lex_ok(src) do
    assert lexer_errors(src) == [],
           "unexpected lexer error for #{inspect(src)}: #{inspect(lexer_errors(src))}"
  end

  # Source strings are built with explicit `\\` (a sigil containing `\x`/`\u`/`{}` trips the compiler).
  describe "malformed escape sequences (elixir_interpolation.erl)" do
    test "invalid \\x / \\u escapes are diagnosed" do
      assert_lex_rejected("\"\\xG\"")
      assert_lex_rejected("\"\\x{}\"")
      assert_lex_rejected("\"\\uZZZZ\"")
      assert_lex_rejected("\"\\u1F\"")
      assert_lex_rejected("\"\\u{110000}\"")
      assert_lex_rejected("\"\\u{D800}\"")
    end

    test "valid escapes are accepted" do
      assert_lex_ok("\"\\xA\"")
      assert_lex_ok("\"\\xAB\"")
      assert_lex_ok("\"\\x{1F}\"")
      assert_lex_ok("\"é\"")
      assert_lex_ok("\"\\u{1F600}\"")
      assert_lex_ok("\"\\n\\t plain\"")
    end

    test "the same applies inside heredocs" do
      assert_lex_rejected("\"\"\"\n\\xG\n\"\"\"")
      assert_lex_ok("\"\"\"\n\\xAB\n\"\"\"")
    end
  end

  describe "invalid sigil names (elixir_tokenizer.erl)" do
    test "rejected names" do
      assert_lex_rejected("~foo(bar)")
      assert_lex_rejected("~ab(foo)")
      assert_lex_rejected("~Ab(foo)")
      assert_lex_rejected("~A1b(foo)")
    end

    test "valid names: one lowercase letter, or uppercase + uppercase/digits" do
      assert_lex_ok("~r(foo)")
      assert_lex_ok("~s(foo)")
      assert_lex_ok("~S(foo)")
      assert_lex_ok("~A1(foo)")
      assert_lex_ok("~HTML(foo)")
    end
  end

  describe "bidirectional formatting controls (elixir_tokenizer.hrl ?bidi)" do
    @bidi <<0x202E::utf8>>

    test "bidi control in a comment is diagnosed" do
      assert_lex_rejected("#" <> @bidi <> "\n1")
    end

    test "bidi control in a string is diagnosed" do
      assert_lex_rejected("\"" <> @bidi <> "\"")
    end

    test "ordinary comments / strings are accepted" do
      assert_lex_ok("# a normal comment\n1")
      assert_lex_ok("\"a normal string\"")
    end
  end

  describe "dot-tuple keyword lead (container_args requires a positional lead)" do
    # `dot_alias -> matched_expr dot_op open_curly container_args close_curly`, and `container_args`
    # only allows `kw_data` AFTER a `container_args_base` (≥1 positional). All-keyword is invalid.
    test "all-keyword dot tuple is rejected" do
      assert_rejected("Foo.{a: x}")
      assert_rejected("Foo.{a: 1, b: 2}")
    end

    test "positional lead (or empty) is accepted" do
      assert_accepted("Foo.{A, B}")
      assert_accepted("Foo.{x, a: 1}")
      assert_accepted("Foo.{}")
    end
  end

  describe "no-parens strict ambiguity (error_no_parens_many_strict)" do
    # `call_args_no_parens_expr -> no_parens_expr` errors: a non-first no-parens argument that is
    # itself a no_parens_many / no_parens_one_ambig call is ambiguous; parentheses are required.
    test "nested no-parens MANY call in a non-first position is rejected" do
      assert_rejected("foo a, bar b, c")
      assert_rejected("foo a, b, bar c, d")
      assert_rejected("foo a, g h b, c")
    end

    test "the same inside a parenthesised call is rejected (call_args_parens_expr)" do
      assert_rejected("foo(a, bar b, c)")
    end

    test "unambiguous forms are accepted" do
      # explicit parens, a single no_parens_ONE arg, or a SOLE ambiguous arg are all fine.
      assert_accepted("foo a, bar(b, c)")
      assert_accepted("foo a, bar b")
      assert_accepted("foo bar b, c")
      assert_accepted("foo(bar b, c)")
      assert_accepted("foo(a, bar b)")
      assert_accepted("foo(g h a, b)")
    end
  end

  describe "container keyword lead (already enforced, pinned here)" do
    test "all-keyword tuple / bitstring rejected; lists allow it" do
      assert_rejected("{a: 1}")
      assert_rejected("<<a: 1>>")
      assert_accepted("[a: 1]")
      assert_accepted("{1, a: 2}")
    end
  end
end
