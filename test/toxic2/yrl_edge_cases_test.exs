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

  describe "uppercase radix / malformed \\u{} / trailing continuation (OX2, R6, R14)" do
    test "uppercase radix prefixes are errors (upstream: invalid character after number)" do
      # toxic2 tolerantly lexes `0` + alias and errors in the parser; upstream errors in the
      # tokenizer — status parity is what's pinned here (diagnostic codes for numbers may differ).
      Enum.each(["0XFF", "0O17", "0B101", "x = 0XFF + 1"], &assert_rejected/1)
      Enum.each(["0xFF", "0o17", "0b101"], &assert_accepted/1)
    end

    test "braced unicode escapes need 1-6 hex digits immediately closed by }" do
      assert_lex_rejected("\"\\u{41\"")
      assert_lex_rejected("\"\\u{41x}\"")
      assert_lex_rejected("\"\\u{0000041}\"")
      assert_lex_rejected(":\"\\u{41\"")
      assert_lex_ok("\"\\u{41}\"")
      assert_lex_ok("\"\\u{10FFFF}\"")
    end

    test "a line continuation at EOF is an invalid escape" do
      assert_lex_rejected("x\\\n")
      assert_lex_rejected("x\\\r\n")
      assert_lex_ok("x\\\n+1")
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

  describe "heredoc indentation pre-scan is interpolation-aware (GRAMMAR_GAPS R3)" do
    test "a raw sigil's literal \#{ does not derail indentation stripping" do
      assert {{:sigil_S, _, [{:<<>>, _, ["\#{\n"]}, []]}, []} =
               Toxic2.parse_to_ast("~S\"\"\"\n  \#{\n  \"\"\"")
    end

    test "braces inside interpolated strings and comments are not counted" do
      strip = fn ast -> Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end)) end

      for src <- [
            "\"\"\"\n  \#{\"{\"}\n  \"\"\"",
            "\"\"\"\n  before\n  \#{# {\n1}\n  after\n  \"\"\""
          ] do
        assert {ast, []} = Toxic2.parse_to_ast(src)
        assert strip.(ast) == strip.(Code.string_to_quoted!(src))
      end
    end
  end

  describe "atom-shaped keyword keys (GRAMMAR_GAPS R5)" do
    test "keyword keys read the full atom name before the colon" do
      for src <- ["[foo@bar: 1]", "[Foo!: 1]", "[Foo?: 1]", "[x@: 1]", "[Foo@bar: 1]"] do
        assert_accepted(src)
      end

      assert {[foo@bar: 1], []} = Toxic2.parse_to_ast("[foo@bar: 1]")
      assert {[Foo!: 1], []} = Toxic2.parse_to_ast("[Foo!: 1]")
    end

    test "the bare names stay invalid and :: stays the type operator" do
      assert_rejected("foo@bar")
      assert_accepted("a :: b")
      assert_accepted("foo::bar")
    end
  end

  describe "`when` with keyword RHS in restricted positions (GRAMMAR_GAPS K6)" do
    test "containers, brackets, map values, and non-first args reject `x when k: v`" do
      for src <- [
            "f x, a when b: 1",
            "f a, b when c: d",
            "f(x, a when b: 1)",
            "f(k: a when b: 1)",
            "[a when b: 1]",
            "[k: a when b: 1]",
            "{a when b: 1}",
            "<<a when b: 1>>",
            "m[a when b: 1]",
            "%{a => a when b: 1}",
            "%{k: a when b: 1}"
          ] do
        assert_rejected(src)
      end
    end

    test "statement, paren, sole-arg, and no-parens kw-value positions stay valid" do
      for src <- [
            "x = y when a: 1",
            "(y when a: 1)",
            "f(a when b: 1)",
            "f a when b: 1",
            "g k: a when b: 1"
          ] do
        assert_accepted(src)
      end
    end
  end

  describe "clause-head restrictions (GRAMMAR_GAPS K4, K7)" do
    test "do-block calls are never head patterns or guards" do
      for src <- [
            "fn if x do y end -> z end",
            "case x do if y do z end -> w end",
            "receive do a after foo do b end -> c end",
            "fn foo a, b do c end -> d end",
            "fn x when quote do y end -> z end"
          ] do
        assert_rejected(src)
      end

      assert_accepted("fn x -> if a do b end end")
      assert_accepted("fn -> quote do x end end")
    end

    test "a keyword run must be the LAST head argument" do
      for src <- [
            "fn a: 1, b -> c end",
            "fn a, b: 1, c -> d end",
            "fn x, a: 1, b -> c end",
            "(a: 1, b -> c)",
            "case x do a: 1, b -> c end"
          ] do
        assert_rejected(src)
      end

      assert_accepted("fn a: 1 -> b end")
      assert_accepted("fn a, b: 1, c: 2 -> d end")
      assert_accepted("fn a when b, c: 1 -> d end")
    end
  end

  describe "doubled `->` and unmatched-unary postfix (GRAMMAR_GAPS OX1, R16)" do
    test "a second -> without a `;` boundary is an error" do
      for src <- [
            "fn x -> y -> z end",
            "case x do 1 -> 2 -> 3 end",
            "cond do true -> 1 -> 2 end",
            "receive do msg -> msg -> :other end",
            "fn x -> y\n-> z end",
            "case x do 1 -> 2\n-> 3 end"
          ] do
        assert_rejected(src)
      end
    end

    test "`;`-separated zero-pattern clauses and multi-line heads stay valid" do
      for src <- [
            "fn x -> y; -> z end",
            "fn x -> y\nz -> w end",
            "fn\n-> 1 end",
            "case x do a when b\n-> c end"
          ] do
        assert_accepted(src)
      end
    end

    test "postfix after a unary-wrapped do-block is rejected like the unwrapped form" do
      assert_rejected("!f do x end.foo")
      assert_rejected("!f do x end[0]")
      assert_rejected("@f do x end.(1)")
      assert_accepted("!(f do x end).foo")
      assert_accepted("!f do x end |> g")
    end
  end

  describe "unwrap_when: comma after a stab-head guard (GRAMMAR_GAPS K1)" do
    test "a non-trailing `when` binds one pattern; more patterns follow" do
      for src <- [
            "fn a when b, c -> d end",
            "fn a when b, c, d -> e end",
            "fn a when f(b), c -> d end",
            "fn a, b when c, d -> e end",
            "fn a when b when c, d -> e end",
            "fn a when b, c when d, e -> f end",
            "fn a when b, c: 1 -> d end",
            "fn (a) when b, c -> d end",
            "fn (a when b, c) -> d end",
            "case x do a when b, c -> d end",
            "try do x rescue e when b, c -> d end",
            "try do x catch k, v when g, h -> i end",
            "(a when b, c -> d)"
          ] do
        assert_accepted(src)
      end

      assert {{:fn, _, [{:->, _, [[{:when, _, [{:a, _, nil}, {:b, _, nil}]}, {:c, _, nil}], _]}]},
              []} = Toxic2.parse_to_ast("fn a when b, c -> d end")

      # trailing `when` still guards ALL patterns
      assert {{:fn, _, [{:->, _, [[{:when, _, [{:a, _, nil}, {:b, _, nil}, {:c, _, nil}]}], _]}]},
              []} = Toxic2.parse_to_ast("fn a, b when c -> d end")
    end

    test "the outer parenthesised-head guard still admits no comma" do
      assert_accepted("fn (a, b) when c -> d end")
      assert_rejected("fn (a, b) when c, d -> e end")
    end
  end

  describe "`not in` keyword ownership and strictness (GRAMMAR_GAPS R4)" do
    test "a trailing keyword run belongs to the call under `not in`" do
      assert {[{:not, _, [{:in, _, [{:a, _, nil}, {:f, _, [[x: 1, y: 2]]}]}]}], []} =
               Toxic2.parse_to_ast("[a not in f x: 1, y: 2]")
    end

    test "ambiguous commas after `not in` no-parens calls are rejected" do
      assert_rejected("f 0, a not in f b, c")
      assert_rejected("[a not in f b, c]")
      assert_accepted("[a in f x: 1, y: 2]")
    end
  end

  describe "spaced bracket access (GRAMMAR_GAPS R1/R2)" do
    test "any access_expr base takes a spaced bracket_arg" do
      for src <- ["f() [0]", "(x) [0]", "Foo [0]", "%{} [0]", "a.b() [0]", "1 [0]", "&1 [0]"] do
        assert_accepted(src)
      end
    end

    test "identifier-like callees keep the tokenizer's adjacency distinction" do
      # spaced `f [0]` / `a.b [0]` stay no-parens calls with a list argument
      assert {{:f, _, [[0]]}, []} = Toxic2.parse_to_ast("f [0]")

      assert {{{:., _, [{:a, _, nil}, :b]}, _, [[0]]}, []} = Toxic2.parse_to_ast("a.b [0]")

      assert {{{:., _, [Access, :get]}, _, [{:f, _, nil}, 0]}, []} = Toxic2.parse_to_ast("f[0]")
    end

    test "a nullary range is not an access base; a completed a.b() is not a no-parens callee" do
      assert_rejected("..[0]")
      assert_accepted("(..)[0]")
      assert_rejected("a.b() 1")
      assert_rejected("a.b() x: 1")
    end
  end

  describe "adjacent no-parens arguments (GRAMMAR_GAPS F1)" do
    test "separate primary/prefix tokens do not require whitespace after a local callee" do
      for src <- [
            "f{1}",
            "f<<1>>",
            "f%{}",
            "f%Foo{}",
            "f~s(x)",
            "f&1",
            "f^x",
            "f~~~x",
            "f...x",
            "f!x",
            "f?x"
          ] do
        assert_accepted(src)
      end
    end

    test "remote operator callees accept an adjacent argument token" do
      for src <- [
            "Kernel.+1",
            "Kernel.-1",
            "Kernel.++1",
            "Kernel.+@x",
            "Kernel.+foo: 1",
            "Bitwise.~~~x"
          ] do
        assert_accepted(src)
      end
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
