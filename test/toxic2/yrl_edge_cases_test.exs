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

      # Elixir 1.20: only `\xHH` (a byte) is accepted — `\xH` (1 digit) and `\x{…}` are now errors
      assert_lex_rejected("\"\\xA\"")
      assert_lex_rejected("\"\\x{1F}\"")
    end

    test "valid escapes are accepted" do
      assert_lex_ok("\"\\xAB\"")
      assert_lex_ok("\"é\"")
      # codepoints use `\uHHHH` / `\u{H..}` (NOT `\x{…}`)
      assert_lex_ok("\"\\u{1F600}\"")
      assert_lex_ok("\"\\n\\t plain\"")
    end

    test "the same applies inside heredocs" do
      assert_lex_rejected("\"\"\"\n\\xG\n\"\"\"")
      assert_lex_rejected("\"\"\"\n\\x{1F}\n\"\"\"")
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

  defp ast(src) do
    {ast, _diags} = Toxic2.parse_to_ast(src)
    ast
  end

  describe "capture of the `/` operator (GRAMMAR_GAPS §1.1, build_unary_op '//')" do
    # `unary_op_eol -> ternary_op`: `//operand` is the documented capture of `Kernel.//2`. The yrl's
    # `build_unary_op('//')` builds the nested `{:/, [c+1], [{:/, [c], nil}, operand]}` (outer `/`
    # one column past the `//` token, inner at the token column).
    test "&//2 captures division" do
      assert_accepted("&//2")

      assert ast("&//2") ==
               {:&, [line: 1, column: 1],
                [{:/, [line: 1, column: 3], [{:/, [line: 1, column: 2], nil}, 2]}]}
    end

    test "standalone //2 (no &) yields the same nested shape" do
      assert_accepted("//2")

      assert ast("//2") ==
               {:/, [line: 1, column: 2], [{:/, [line: 1, column: 1], nil}, 2]}
    end
  end

  describe "operator-as-identifier in capture (GRAMMAR_GAPS §2.1)" do
    # In capture position an operator followed by `/arity` re-emits as an identifier, so `&../2`
    # builds `{:.., _, nil}` (args nil, NOT the nullary-op `[]`). Same for `...`. The space form
    # `& ../2` is also nil upstream.
    test "&../2 yields identifier-style {:.., _, nil}" do
      assert_accepted("&../2")

      assert ast("&../2") ==
               {:&, [line: 1, column: 1],
                [{:/, [line: 1, column: 4], [{:.., [line: 1, column: 2], nil}, 2]}]}
    end

    test "&.../2 yields identifier-style {:..., _, nil}" do
      assert_accepted("&.../2")

      assert ast("&.../2") ==
               {:&, [line: 1, column: 1],
                [{:/, [line: 1, column: 5], [{:..., [line: 1, column: 2], nil}, 2]}]}
    end

    test "& ../2 (space form) also yields nil args" do
      assert_accepted("& ../2")

      assert ast("& ../2") ==
               {:&, [line: 1, column: 1],
                [{:/, [line: 1, column: 5], [{:.., [line: 1, column: 3], nil}, 2]}]}
    end

    test "standalone .. / ... stay nullary-op {:.., _, []} (unchanged)" do
      assert ast("..") == {:.., [line: 1, column: 1], []}
      assert ast("(..)") == {:.., [line: 1, column: 2], []}
      assert ast("...") == {:..., [line: 1, column: 1], []}
    end
  end

  describe "eol between struct base and body (GRAMMAR_GAPS §1.2)" do
    # `map -> '%' map_base_expr eol map_args` admits an eol (the lexer collapses consecutive newlines
    # into one eol token, so one or more blank lines both parse).
    # Default (no-meta-parity) mode: container nodes (`%`, `%{}`) carry empty meta; only the alias
    # keeps its anchor. token_metadata fidelity for these is covered by `token_metadata_test.exs`.
    test "%Foo\\n{} is a valid empty struct" do
      assert_accepted("%Foo\n{}")

      assert ast("%Foo\n{}") ==
               {:%, [], [{:__aliases__, [line: 1, column: 2], [:Foo]}, {:%{}, [], []}]}
    end

    test "%Foo\\n\\n{} (two newlines collapse to one eol) is also valid" do
      assert_accepted("%Foo\n\n{}")

      assert ast("%Foo\n\n{}") ==
               {:%, [], [{:__aliases__, [line: 1, column: 2], [:Foo]}, {:%{}, [], []}]}
    end
  end

  describe "unwrap_splice through parens in stab heads (GRAMMAR_GAPS §2.2)" do
    # `stab_parens_many` applies `unwrap_splice` to the head args: a sole arg of shape
    # `{:__block__, _, [{:unquote_splicing, _, _}]}` (the `__block__` the inner paren wraps a lone
    # splice in) is stripped back to the bare splice. The single-paren form never grows the wrapper.
    test "((unquote_splicing([1, 2])) -> :ok) unwraps the __block__ around the splice" do
      assert_accepted("((unquote_splicing([1, 2])) -> :ok)")

      assert ast("((unquote_splicing([1, 2])) -> :ok)") ==
               [{:->, [], [[{:unquote_splicing, [line: 1, column: 3], [[1, 2]]}], :ok]}]
    end

    test "single-paren (unquote_splicing([1, 2]) -> :ok) stays unwrapped (no regression)" do
      assert_accepted("(unquote_splicing([1, 2]) -> :ok)")

      assert ast("(unquote_splicing([1, 2]) -> :ok)") ==
               [{:->, [], [[{:unquote_splicing, [line: 1, column: 2], [[1, 2]]}], :ok]}]
    end

    test "fn unquote_splicing([a]) -> 1 end stays correct" do
      assert_accepted("fn unquote_splicing([a]) -> 1 end")

      assert ast("fn unquote_splicing([a]) -> 1 end") ==
               {:fn, [],
                [
                  {:->, [],
                   [
                     [
                       {:unquote_splicing, [line: 1, column: 4],
                        [[{:a, [line: 1, column: 22], nil}]]}
                     ],
                     1
                   ]}
                ]}
    end
  end

  describe "not in must not split across lines (GRAMMAR_GAPS §3.1)" do
    # Upstream fuses `not` + `in` into a single `in_op` only when both words are on the same line;
    # across an eol it is a syntax error. Toxic2 stops fusing and recovers tolerantly.
    test "a not\\nin b is rejected with an :unexpected_token error on the stray `in`" do
      assert_rejected("a not\nin b")

      # Pin phase + severity + code: recovery flags the now-bare `in` operator at line 2 col 1.
      [d | _] = parser_errors("a not\nin b")
      assert Diagnostic.phase(d) == :parser
      assert Diagnostic.severity(d) == :error
      assert Diagnostic.code(d) == :unexpected_token
      assert Diagnostic.span(d) == {2, 1, 2, 3}
      assert Diagnostic.details(d) == %{kind: :in_op}
    end

    test "a not in b (same line) still fuses (no regression)" do
      assert_accepted("a not in b")

      # `not`/`in` keyword anchors are only filled in token_metadata mode; default mode is no-meta.
      assert ast("a not in b") ==
               {:not, [],
                [
                  {:in, [], [{:a, [line: 1, column: 1], nil}, {:b, [line: 1, column: 10], nil}]}
                ]}
    end
  end

  describe "no-parens-many call as map assoc key/value (GRAMMAR_GAPS §3.2)" do
    # `assoc_expr` admits only matched/unmatched exprs — a no-parens MANY call (`g b, c`) in an
    # assoc key/value (or a bare entry) position is `error_no_parens_many_strict`.
    test "%{f(a) => g b, c} (no-parens-many in assoc value) is rejected" do
      assert_rejected("%{f(a) => g b, c}")
    end

    test "%{g b, c => 1} (no-parens-many in assoc key) is rejected" do
      assert_rejected("%{g b, c => 1}")
    end

    test "%{g b, c} (no-parens-many as a bare entry) is rejected" do
      assert_rejected("%{g b, c}")
    end

    test "%{m | k => g b, c} (no-parens-many in update assoc value) is rejected" do
      assert_rejected("%{m | k => g b, c}")
    end

    test "valid maps with a no-parens call NOT followed by a comma stay accepted" do
      assert_accepted("%{f(a) => g b}")
      assert_accepted("%{1 => 2, 3}")
      assert_accepted("%{a => b, c => d}")
      assert_accepted("%{x, y}")
    end
  end
end
