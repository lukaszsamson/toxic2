defmodule Toxic2.LexerTest do
  use ExUnit.Case, async: true

  alias Toxic2.Token

  defp tokens(src) do
    # The lexer now emits deprecation/ambiguity WARNINGS on the notice channel (`{toks, notices}`);
    # token-shape tests only care about `toks`. Warning behavior is covered by the diagnostics suites.
    {toks, _notices} = Toxic2.tokenize(src)
    toks
  end

  # {kind, value} shapes, spans stripped.
  defp shapes(src), do: src |> tokens() |> Enum.map(&{Token.kind(&1), Token.value(&1)})

  describe "names carry BINARY values (review #1: no source atom interning)" do
    test "identifiers and aliases are binaries, not atoms" do
      assert shapes("foo Bar baz?") == [
               {:identifier, "foo"},
               {:alias, "Bar"},
               {:identifier, "baz?"}
             ]
    end

    test "atoms carry binary values (atomization is a lowering concern)" do
      assert shapes(":foo :Bar :foo? :<>") == [
               {:atom, "foo"},
               {:atom, "Bar"},
               {:atom, "foo?"},
               {:atom, "<>"}
             ]
    end

    test "`:::` is the atom `:\"::\"`, not `::` + `:` (leading colon takes `::` as its name)" do
      assert shapes(":::") == [{:atom, "::"}]
      assert shapes(":::;") == [{:atom, "::"}, {:";", nil}]
      # `::` on its own and between operands stays the type operator
      assert shapes("::") == [{:type_op, :"::"}]
      assert shapes("a :: b") == [{:identifier, "a"}, {:type_op, :"::"}, {:identifier, "b"}]
    end

    test "keyword keys carry binary values" do
      assert shapes("foo: bar") == [{:kw_identifier, "foo"}, {:identifier, "bar"}]
    end

    test "atom names may contain `@` (`:nonode@nohost`), but identifiers may not" do
      assert shapes(":nonode@nohost") == [{:atom, "nonode@nohost"}]
      assert shapes(":foo@") == [{:atom, "foo@"}]
      assert shapes(":a@b@c") == [{:atom, "a@b@c"}]
    end

    test "operator/bracket names before a separator colon are keyword keys" do
      assert shapes("[<<>>: 1]") ==
               [{:"[", nil}, {:kw_identifier, "<<>>"}, {:int, 1}, {:"]", nil}]

      assert shapes("[%{}: 1]") ==
               [{:"[", nil}, {:kw_identifier, "%{}"}, {:int, 1}, {:"]", nil}]

      assert shapes("[{}: 1]") ==
               [{:"[", nil}, {:kw_identifier, "{}"}, {:int, 1}, {:"]", nil}]

      assert shapes("[+: 1]") == [{:"[", nil}, {:kw_identifier, "+"}, {:int, 1}, {:"]", nil}]
      assert shapes("[%: 1]") == [{:"[", nil}, {:kw_identifier, "%"}, {:int, 1}, {:"]", nil}]
      assert shapes("[&: 1]") == [{:"[", nil}, {:kw_identifier, "&"}, {:int, 1}, {:"]", nil}]
    end

    test "`op:name` (no separator) is the operator plus an `:atom`, not a keyword key" do
      assert [{:capture_op, _}, {:atom, "foo"}] = shapes("&:foo")
      assert [{:dual_op, _}, {:atom, "foo"}] = shapes("+:foo")
    end

    test "`::` and `//` are never keyword keys" do
      refute match?([{:kw_identifier, _} | _], shapes(":::"))
      refute match?([{:kw_identifier, _} | _], shapes("//: 1"))
    end
  end

  describe "unicode identifiers/atoms (vendored Toxic2.String.Tokenizer)" do
    test "ascii-started words flowing into unicode stay a single identifier" do
      assert shapes("café") == [{:identifier, "café"}]
      assert shapes("módulo") == [{:identifier, "módulo"}]
      assert shapes("naïve_x") == [{:identifier, "naïve_x"}]
      assert shapes("café?") == [{:identifier, "café?"}]
    end

    test "non-ascii-started identifiers" do
      assert shapes("αβγ") == [{:identifier, "αβγ"}]
      assert shapes("привет") == [{:identifier, "привет"}]
      assert shapes("_αβ") == [{:identifier, "_αβ"}]
    end

    test "names are NFC/NFKC normalized (µ U+00B5 → μ U+03BC)" do
      assert shapes("µ") == [{:identifier, "μ"}]
    end

    test "unicode atom literals, incl. unicode-uppercase usable only as an atom" do
      assert shapes(":café") == [{:atom, "café"}]
      assert shapes(":αβγ") == [{:atom, "αβγ"}]
      assert shapes(":Σ") == [{:atom, "Σ"}]
      assert shapes(":café?") == [{:atom, "café?"}]
    end

    test "unicode keyword keys" do
      assert shapes("[αβ: 1]") ==
               [{:"[", nil}, {:kw_identifier, "αβ"}, {:int, 1}, {:"]", nil}]
    end

    test "a lone unicode-uppercase word is an error (valid only inside an atom literal)" do
      assert [{:error, %Toxic2.LexError{}}] = shapes("Σ")
    end

    test "mixed-script identifiers are rejected (UTS-39), as a single error token" do
      assert [{:error, %Toxic2.LexError{}}] = shapes("aαb")
    end

    test "rejects identifiers that normalize to unsupported codepoints" do
      alias Toxic2.String.Tokenizer

      # [?u, 0x0308, 0x0300] (u + combining diaeresis + combining grave) are each
      # valid identifier continue chars, but normalize (NFC) to U+01DC `ǜ`, which
      # is not a supported identifier codepoint.
      decomposed = [?u, 0x0308, 0x0300]

      assert Tokenizer.tokenize(<<0x01DC::utf8>>) == {:error, :empty}

      assert Tokenizer.tokenize(:unicode.characters_to_binary(decomposed)) ==
               {:error, {:unexpected_token, :unicode.characters_to_binary(decomposed)}}

      assert Tokenizer.tokenize("fooǜlul") ==
               {:error, {:unexpected_token, "fooǜ"}}
    end
  end

  describe "closed-set lexemes carry atoms (safe to intern)" do
    test "true/false/nil are :literal with atom values" do
      assert shapes("true false nil") == [{:literal, true}, {:literal, false}, {:literal, nil}]
    end

    test "reserved word operators" do
      assert shapes("x when y and z or not w in v") == [
               {:identifier, "x"},
               {:when_op, :when},
               {:identifier, "y"},
               {:and_op, :and},
               {:identifier, "z"},
               {:or_op, :or},
               {:unary_op, :not},
               {:identifier, "w"},
               {:in_op, :in},
               {:identifier, "v"}
             ]
    end

    test "block labels and terminators" do
      assert shapes("fn do else after end") == [
               {:fn, nil},
               {:do, nil},
               {:block_label, :else},
               {:block_label, :after},
               {:end, nil}
             ]
    end
  end

  describe "no fused `not in` (P2)" do
    test "`not in` stays two tokens; fusion is a parser/lowering concern" do
      assert shapes("a not in b") == [
               {:identifier, "a"},
               {:unary_op, :not},
               {:in_op, :in},
               {:identifier, "b"}
             ]
    end
  end

  describe "`do:` keyword key vs `do` terminator" do
    test "adjacent colon makes a keyword key, even for reserved words" do
      assert shapes("do: end") == [{:kw_identifier, "do"}, {:end, nil}]
    end

    test "bare `do` is the terminator" do
      assert shapes("do end") == [{:do, nil}, {:end, nil}]
    end

    test "`foo::bar` is identifier + type_op, not a keyword key" do
      assert shapes("foo::bar") == [{:identifier, "foo"}, {:type_op, :"::"}, {:identifier, "bar"}]
    end
  end

  describe "numbers" do
    test "integers with underscores" do
      assert shapes("1_000_000") == [{:int, 1_000_000}]
    end

    test "hex / octal / binary integers" do
      assert shapes("0xFF 0o17 0b1010") == [{:int, 255}, {:int, 15}, {:int, 10}]
    end

    test "floats incl. exponents" do
      assert shapes("1.0 1.25 1.0e3 1.5e-3") == [
               {:flt, 1.0},
               {:flt, 1.25},
               {:flt, 1.0e3},
               {:flt, 1.5e-3}
             ]
    end

    test "`1.foo` is int then dot then identifier (dot needs a digit to be a float)" do
      assert shapes("1.foo") == [{:int, 1}, {:dot, :.}, {:identifier, "foo"}]
    end

    test "a radix prefix with no digits is a tolerant error" do
      assert [{:error, %Toxic2.LexError{code: :invalid_number}}] = shapes("0x")
    end

    test "only-underscore radix bodies are a tolerant error, never a crash (review #1)" do
      for src <- ["0x_", "0o_", "0b_"] do
        assert [{:error, %Toxic2.LexError{code: :invalid_number}}] = shapes(src),
               "#{src} must be an error token, not an exception"
      end
    end

    test "invalid underscore placement is an :error, not a silently-valid number (review #2)" do
      for src <- ["1_", "1__2", "0x_F", "0xF_", "1.2_", "1_.2"] do
        kinds = src |> tokens() |> Enum.map(&Token.kind/1)

        assert :error in kinds and :int not in kinds and :flt not in kinds,
               "#{src} must produce an :error token and no number token, got #{inspect(kinds)}"
      end
    end

    test "valid underscores (incl. in the exponent) still parse" do
      assert shapes("1_000 1_0.2_5 1.0e1_0") == [
               {:int, 1000},
               {:flt, 10.25},
               {:flt, 1.0e10}
             ]
    end
  end

  describe "char literals" do
    test "plain and escaped chars" do
      assert shapes("?a ?\\n ?\\s") == [{:char, ?a}, {:char, ?\n}, {:char, ?\s}]
    end
  end

  describe "operator families (tags ported from Toxic; precedence pinned in phase 5)" do
    test "longest-match across 1/2/3-char operators" do
      assert shapes("a +++ b == c <<< d ||| e") == [
               {:identifier, "a"},
               {:concat_op, :+++},
               {:identifier, "b"},
               {:comp_op, :==},
               {:identifier, "c"},
               {:arrow_op, :<<<},
               {:identifier, "d"},
               {:or_op, :|||},
               {:identifier, "e"}
             ]
    end

    test "<< and >> are bitstring delimiters, but <<< wins by length" do
      assert shapes("<<x>>") == [{:"<<", nil}, {:identifier, "x"}, {:">>", nil}]
      assert shapes("a <<< b") == [{:identifier, "a"}, {:arrow_op, :<<<}, {:identifier, "b"}]
    end

    test "assoc, stab, pipe, range, type, match" do
      assert shapes("=> -> |> .. :: =") == [
               {:assoc_op, :"=>"},
               {:stab_op, :->},
               {:arrow_op, :|>},
               {:range_op, :..},
               {:type_op, :"::"},
               {:match_op, :=}
             ]
    end

    test "capture op vs capture int" do
      assert shapes("&foo &1") == [{:capture_op, :&}, {:identifier, "foo"}, {:capture_int, 1}]
    end

    test "at op and percent" do
      assert shapes("@attr %{}") == [
               {:at_op, :@},
               {:identifier, "attr"},
               {:percent, nil},
               {:"{", nil},
               {:"}", nil}
             ]
    end
  end

  describe "comments are dropped (phase 2)" do
    test "a comment runs to end of line and produces no token" do
      assert shapes("a # trailing\nb") == [{:identifier, "a"}, {:eol, 1}, {:identifier, "b"}]
    end
  end

  describe "layout (P2: explicit eol, no newline swallowing)" do
    test "blank lines coalesce into one :eol carrying the count" do
      assert shapes("a\n\n\nb") == [{:identifier, "a"}, {:eol, 3}, {:identifier, "b"}]
    end

    test "operators never carry newline counts; the :eol is a separate token" do
      assert shapes("a +\nb") == [
               {:identifier, "a"},
               {:dual_op, :+},
               {:eol, 1},
               {:identifier, "b"}
             ]
    end
  end

  describe "spans (flat tuple, end-exclusive)" do
    test "single-line spans are precise and end-exclusive" do
      [foo, plus, bar] = tokens("foo + bar")
      assert Token.span(foo) == {1, 1, 1, 4}
      assert Token.span(plus) == {1, 5, 1, 6}
      assert Token.span(bar) == {1, 7, 1, 10}
    end

    test "keyword-key span includes the colon" do
      # the keyword colon must be followed by whitespace (`foo:` alone is a missing-space error)
      [kw] = tokens("foo: ")
      assert Token.span(kw) == {1, 1, 1, 5}
    end

    test "adjacency vs separation drive call decisions (consumed by parser later)" do
      [foo, popen | _] = tokens("foo(x)")
      assert Token.adjacent?(foo, popen)

      [bar, popen2 | _] = tokens("bar (x)")
      refute Token.adjacent?(bar, popen2)
      assert Token.separated_on_same_line?(bar, popen2)
    end

    test "tokens after an :eol get correct line/column" do
      [_a, _eol, b] = tokens("a\n  b")
      assert Token.span(b) == {2, 3, 2, 4}
    end

    test "the :eol after a multi-byte comment gets a codepoint (not byte) start column" do
      # `# café` is 6 codepoints but 7 bytes (é is 2 bytes); the newline starts at column 7.
      [eol, b] = tokens("# café\nx")
      assert {:eol, 1, 7, 2, 1, _} = eol
      assert Token.span(b) == {2, 1, 2, 2}
    end
  end

  describe "tolerant lexing (review #2: codepoint-aware; P3: :error is the sole transport)" do
    test "an unknown but valid UTF-8 codepoint is ONE error advancing one column" do
      toks = tokens("a √ b")

      assert [
               {:identifier, "a"},
               {:error, %Toxic2.LexError{code: :unexpected_char}},
               {:identifier, "b"}
             ] = Enum.map(toks, &{Token.kind(&1), Token.value(&1)})

      [_a, err, b] = toks

      assert Token.span(err) == {1, 3, 1, 4},
             "multibyte codepoint must advance exactly one column"

      assert Token.span(b) == {1, 5, 1, 6}
    end

    test "invalid UTF-8 bytes fall back to a per-byte error" do
      {toks, []} = Toxic2.tokenize(<<?a, 0xFF, ?b>>)

      assert [
               {:identifier, "a"},
               {:error, %Toxic2.LexError{code: :invalid_byte}},
               {:identifier, "b"}
             ] =
               Enum.map(toks, &{Token.kind(&1), Token.value(&1)})
    end

    test "no separate error list: tokenize/2 always returns {tokens, warnings}" do
      assert {[_ | _], []} = Toxic2.tokenize("a ~ b ~ c")
    end

    test "never raises on malformed input — the core tolerant-lexer contract" do
      nasty = [
        "0x",
        "0x_",
        "0o_",
        "0b_",
        "1_",
        "1__2",
        "0xF_",
        "1.2_",
        "1.0e",
        "1.0e_",
        ":",
        ":\"x",
        "?",
        "?\\",
        "~",
        "@",
        "&",
        "%",
        "::",
        "...",
        "\\",
        <<0xFF, 0xFE>>,
        "héllo@wörld",
        "  \t\n\n  ",
        "}{)(",
        "fn end do"
      ]

      for src <- nasty do
        assert {toks, []} = Toxic2.tokenize(src)
        assert is_list(toks)
      end
    end
  end

  describe "double-quoted strings (phase 10: linear, interpolation-aware)" do
    test "a simple string is start / fragment / end with the unescaped value" do
      assert shapes(~S("abc")) == [
               {:string_start, nil},
               {:string_fragment, "abc"},
               {:string_end, nil}
             ]

      assert shapes(~S("")) == [{:string_start, nil}, {:string_end, nil}]
    end

    test "escapes are processed into the fragment value" do
      assert shapes(~S("a\nb")) == [
               {:string_start, nil},
               {:string_fragment, "a\nb"},
               {:string_end, nil}
             ]

      assert shapes(~S("a\tb\\c\"d")) == [
               {:string_start, nil},
               {:string_fragment, "a\tb\\c\"d"},
               {:string_end, nil}
             ]
    end

    test "interpolation lexes to begin/end markers wrapping the inner tokens" do
      assert shapes(~S("a#{b}c")) == [
               {:string_start, nil},
               {:string_fragment, "a"},
               {:begin_interpolation, nil},
               {:identifier, "b"},
               {:end_interpolation, nil},
               {:string_fragment, "c"},
               {:string_end, nil}
             ]
    end

    test "a `}` inside the interpolation (nested braces) does NOT end it early" do
      kinds = ~S("#{ {1} }") |> tokens() |> Enum.map(&Token.kind/1)

      assert kinds == [
               :string_start,
               :begin_interpolation,
               :"{",
               :int,
               :"}",
               :end_interpolation,
               :string_end
             ]
    end

    test "an unterminated string is one :error then a synthetic :string_end, never a raise" do
      assert [{:string_start, _}, {:string_fragment, "abc"}, {:error, _}, {:string_end, _}] =
               shapes(~S("abc))
    end

    test "a quoted string immediately before `:` emits a :kw_quote marker (quoted kw key)" do
      assert shapes("\"foo\": 1") == [
               {:string_start, nil},
               {:string_fragment, "foo"},
               {:string_end, nil},
               {:kw_quote, nil},
               {:int, 1}
             ]

      # `::` after a string is the type operator, not a kw key
      assert [
               {:string_start, _},
               {:string_fragment, "x"},
               {:string_end, _},
               {:type_op, :"::"} | _
             ] =
               shapes("\"x\"::y")
    end

    test "operator-named atoms (brackets/percent) lex as a single :atom" do
      assert shapes(":<<>>") == [{:atom, "<<>>"}]
      assert shapes(":%{}") == [{:atom, "%{}"}]
      assert shapes(":..//") == [{:atom, "..//"}]
      # `//` alone is not a valid atom (`://` rejected — // is only the range step)
      assert [{:error, _} | _] = shapes("://")
    end

    test "quoted atoms emit a :quoted_atom marker then the quoted-literal tokens" do
      assert shapes(":\"ab\"") == [
               {:quoted_atom, nil},
               {:string_start, nil},
               {:string_fragment, "ab"},
               {:string_end, nil}
             ]

      assert [{:quoted_atom, nil}, {:string_start, nil} | _] = shapes(":\"a\#{x}\"")
    end

    test "sigils: name on :sigil_start, modifiers on :sigil_end, raw content" do
      assert shapes("~r/foo/i") == [
               {:sigil_start, "r"},
               {:string_fragment, "foo"},
               {:sigil_end, "i"}
             ]

      # uppercase sigil keeps `#{` literal (no interpolation tokens)
      assert shapes("~S(a\#{b})") == [
               {:sigil_start, "S"},
               {:string_fragment, "a\#{b}"},
               {:sigil_end, ""}
             ]
    end

    test "a sigil `\\` escape keeps a non-ASCII codepoint's bytes verbatim (no re-encoding)" do
      # `~s/\é/` => content `\é` — the escaped char is a full codepoint, kept as-is (the old
      # byte-wise clause re-encoded é's lead byte 0xC3 as UTF-8, corrupting it to 0xC3 0x83).
      assert shapes("~s/\\é/") == [
               {:sigil_start, "s"},
               {:string_fragment, "\\é"},
               {:sigil_end, ""}
             ]

      assert shapes("~s'\\λx'") == [
               {:sigil_start, "s"},
               {:string_fragment, "\\λx"},
               {:sigil_end, ""}
             ]

      # `\` before an invalid UTF-8 byte keeps the byte verbatim (tolerant)
      assert [{:sigil_start, "s"}, {:string_fragment, <<?a, ?\\, 0xFF, ?b>>}, {:sigil_end, ""}] =
               shapes("~s/a\\" <> <<0xFF>> <> "b/")
    end

    test "a sigil `\\`-newline keeps both chars and still advances the line counter" do
      # content matches the oracle (`a\<LF>b`), and `foo` on line 2 gets the right position
      assert [
               {:sigil_start, 1, 1, _, _, "s"},
               {:string_fragment, 1, 4, 2, 2, "a\\\nb"},
               {:sigil_end, 2, 2, 2, 3, ""},
               {:eol, _, _, _, _, _},
               {:identifier, 3, 1, 3, 4, "foo"}
             ] = tokens("~s/a\\\nb/\nfoo")
    end

    test "heredocs strip the closing delimiter's indentation (lexically)" do
      assert shapes("\"\"\"\n  a\n  b\n  \"\"\"") == [
               {:string_start, nil},
               {:string_fragment, "a\nb\n"},
               {:string_end, nil}
             ]
    end

    test "a `}` inside a heredoc interpolation does not terminate the heredoc early" do
      kinds = "\"\"\"\n#{"x\#{ %{a: 1} }y"}\n\"\"\"" |> tokens() |> Enum.map(&Token.kind/1)
      assert :string_start == hd(kinds)
      assert :string_end == List.last(kinds)
    end

    test "`\\`-newline inside a heredoc is a line continuation (newline dropped, `\"\"\"` still closes)" do
      assert shapes("\"\"\"\nfoo\\\n\"\"\"") == [
               {:string_start, nil},
               {:string_fragment, "foo"},
               {:string_end, nil}
             ]

      # the continuation joins the two lines
      assert shapes("\"\"\"\nfoo\\\nbar\n\"\"\"") == [
               {:string_start, nil},
               {:string_fragment, "foobar\n"},
               {:string_end, nil}
             ]
    end

    test "a sigil name at EOF with no delimiter is dropped wholesale (matches the reference)" do
      assert shapes("~x") == []
      assert shapes("~X123") == []
      # a trailing incomplete sigil drops without disturbing earlier tokens
      assert shapes("1\n~x") == [{:int, 1}, {:eol, 1}]
    end

    test "a sigil with a non-EOF invalid delimiter still errors (only the EOF case is dropped)" do
      assert [{:sigil_start, "x"}, {:error, %Toxic2.LexError{code: :invalid_sigil_delimiter}}] =
               shapes("~x ")
    end

    test "the indentation pre-scan treats a `\\`-newline as a line boundary (finds the closer)" do
      # closing `"""` is indented 6; content lines use `\`-continuation, indentation still stripped
      assert shapes("      \"\"\"\n      a \\\n      b\n      \"\"\"") == [
               {:string_start, nil},
               {:string_fragment, "a b\n"},
               {:string_end, nil}
             ]
    end

    test "a raw heredoc unescapes `\\` before the full delimiter (`\\\"\"\"` => `\"\"\"`)" do
      assert [{:sigil_start, "S"}, {:string_fragment, "foo\"\"\"\n"}, {:sigil_end, ""}] =
               shapes("~S\"\"\"\nfoo\\\"\"\"\n\"\"\"")
    end

    test "a heredoc opening with an interpolation keeps a leading empty fragment" do
      assert [
               {:string_start, nil},
               {:string_fragment, ""},
               {:begin_interpolation, nil},
               {:identifier, "x"},
               {:end_interpolation, nil},
               {:string_fragment, "\n"},
               {:string_end, nil}
             ] = shapes("\"\"\"\n\#{x}\n\"\"\"")
    end

    test "charlists share the linear form with charlist_* token kinds" do
      assert shapes(~S('ab')) == [
               {:charlist_start, nil},
               {:charlist_fragment, "ab"},
               {:charlist_end, nil}
             ]

      assert shapes("'x\#{y}'") == [
               {:charlist_start, nil},
               {:charlist_fragment, "x"},
               {:begin_interpolation, nil},
               {:identifier, "y"},
               {:end_interpolation, nil},
               {:charlist_end, nil}
             ]
    end
  end

  describe "batch / source-order invariants" do
    test "empty source yields no tokens" do
      assert tokens("") == []
    end

    test "token start positions are non-decreasing in source order" do
      toks = tokens("foo bar\nbaz = 1\n\nqux 0xAB ?z :sym")
      starts = Enum.map(toks, &{Token.start_line(&1), Token.start_col(&1)})
      assert starts == Enum.sort(starts)
    end
  end
end
