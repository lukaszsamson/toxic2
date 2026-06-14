defmodule Toxic2.TokenMetadataTest do
  use ExUnit.Case, async: true

  # `parse_to_ast(src, token_metadata: true)` reproduces Elixir's `token_metadata: true` meta —
  # the keys the oracle (`Code.string_to_quoted`) attaches beyond `line:`/`column:`: `closing:`,
  # `do:`/`end:`, `delimiter:`, `token:`, `format: :keyword`, `assoc:`, `last:`, `from_brackets:`,
  # `from_interpolation:`, `indentation:`, `no_parens:`, `parens:`, `ambiguous_op:`, `newlines:`, and
  # `end_of_expression: [newlines:, line:, column:]`. We assert equality (meta-key order normalised)
  # against the live oracle (same `literal_encoder`, so bare literals carry meta too).
  #
  # Coverage: parity is complete across the full Elixir distribution (all 6 apps) and a ~2500-file
  # OSS sweep — every previously-excluded edge case (deprecated `a not in b`, `ambiguous_op:`,
  # multi-clause `fn` / comment-in-gap `newlines:`, quoted/dot/anon calls, parenthesised stab heads,
  # empty parens, …) is now covered, here and in the regression blocks below.

  @encoder &__MODULE__.encode/2
  def encode(value, meta), do: {:ok, {:__block__, meta, [value]}}

  defp oracle!(src), do: Toxic2.Test.Oracle.quoted_with_token_metadata(src, @encoder)

  defp mine(src) do
    {ast, _diags} = Toxic2.parse_to_ast(src, token_metadata: true, literal_encoder: @encoder)
    ast
  end

  # Compare with meta-key ORDER normalised: meta is a keyword list read via `Keyword.get`, so the
  # internal key order is not semantically meaningful — same keys + same values is the parity that
  # matters. (Toxic2 already orders keys like Elixir; this just keeps the test robust.)
  defp assert_parity(src) do
    assert norm(mine(src)) == norm(oracle!(src)), """
    token_metadata mismatch for #{inspect(src)}
    oracle: #{inspect(oracle!(src))}
    mine:   #{inspect(mine(src))}
    """
  end

  defp norm(ast) do
    Macro.prewalk(ast, fn
      {f, meta, args} when is_list(meta) -> {f, norm_meta(meta), args}
      other -> other
    end)
  end

  defp norm_meta(meta), do: meta |> Enum.map(fn {k, v} -> {k, norm_val(v)} end) |> Enum.sort()

  defp norm_val([{_, _} | _] = kw) do
    if Keyword.keyword?(kw), do: norm_meta(kw), else: kw
  end

  defp norm_val(v), do: v

  describe "closing: / do: / end:" do
    test "paren calls, containers, fn, bitstrings",
      do: Enum.each(~w/foo(a,b) foo() {1,2,3} <<x::8>>/, &assert_parity/1)

    test "list / tuple containers",
      do: Enum.each(["[1, 2]", "{1, 2}", "%{a: 1}"], &assert_parity/1)

    test "fn closing", do: assert_parity("fn x -> x end")

    test "do/end blocks" do
      assert_parity("if x do\n  y\nelse\n  z\nend")
      assert_parity("case v do\n  1 -> :a\nend")
      assert_parity("def f(a) do\n  a\nend")
      assert_parity("try do\n  a\nrescue\n  _ -> b\nend")
    end
  end

  describe "delimiter: / token: / indentation:" do
    test "numbers and chars carry token:",
      do: Enum.each(["1", "0x1F", "1_000", "1.5e10", "?a"], &assert_parity/1)

    test "strings / charlists / quoted atoms carry delimiter:",
      do: Enum.each([~S("hello"), "'cl'", ~S(:"a b")], &assert_parity/1)

    test "sigils carry delimiter:",
      do: Enum.each(["~r/re/i", "~s(x)", "~S(raw)"], &assert_parity/1)

    test "heredocs carry delimiter: + indentation:" do
      assert_parity("\"\"\"\nhi\n\"\"\"")
      assert_parity("  \"\"\"\n  indented\n  \"\"\"")
      assert_parity("~s\"\"\"\nabc\n\"\"\"")
    end
  end

  describe "assoc: / last: / format:" do
    test "map => association", do: assert_parity("%{x => y}")

    test "alias last segment",
      do: Enum.each(["Foo.Bar.Baz", "Mod.fun(x)", "%Foo{a: 1}"], &assert_parity/1)

    test "keyword key format",
      do: Enum.each(["[a: 1, b: 2]", "for i <- list, do: i"], &assert_parity/1)
  end

  describe "from_brackets: / from_interpolation:" do
    test "access uses from_brackets:", do: Enum.each(["foo[bar]", "a[b][c]"], &assert_parity/1)

    test "string interpolation uses from_interpolation:",
      do: Enum.each([~S("a#{b}c"), ~S(:"x#{y}")], &assert_parity/1)
  end

  describe "no_parens: / parens:" do
    test "paren-less remote call", do: assert_parity("a.b.c")

    test "parenthesised expressions",
      do: Enum.each(["(a + b)", "((a))", "(\n\n a + b)"], &assert_parity/1)
  end

  describe "end_of_expression: (newlines, incl. comments / semicolons / blank lines)" do
    test "newlines and semicolons",
      do: Enum.each(["a\nb\nc", "a; b", "a;b;c", "a\n\n\nb"], &assert_parity/1)

    test "comment lines reset the newline run" do
      assert_parity("a\n# comment\nb")
      assert_parity("a # trailing\nb")
      assert_parity("a\n\n# c\n\nb")
      assert_parity("def a do\n  1\nend\n\n## section\n\ndef b, do: 2")
    end
  end

  describe "standalone newlines: (operators, ->, containers, calls)" do
    test "binary operators",
      do: Enum.each(["a |>\n b", "a\n|> b", "a +\n\n b", "a = \n b"], &assert_parity/1)

    test "stab clauses",
      do: Enum.each(["fn a ->\n b end", "case x do\n a ->\n b\nend"], &assert_parity/1)

    test "containers and calls",
      do: Enum.each(["foo(\n a, b)", "{\n a, b}", "%{\n a: 1}", "<<\n a>>"], &assert_parity/1)
  end

  describe "anonymous calls, qualified calls, guards" do
    test "anon call closing + dot anchor",
      do: Enum.each(["next.(x)", "foo.bar.(x)"], &assert_parity/1)

    test "clause-head when guard",
      do:
        Enum.each(
          ["fn x when x > 0 -> x end", "case v do\n  x when x > 0 -> x\nend"],
          &assert_parity/1
        )
  end

  describe "regressions (reviewer findings)" do
    test "stab/clause arrow is not matched inside a pattern string" do
      assert_parity(~S|fn "->" -> x end|)
      assert_parity(~S|case x do
 "->" -> y
end|)
    end

    test "CRLF line endings still produce end_of_expression" do
      assert_parity("a\r\nb")
      assert_parity("a\r\n\r\nb")
    end

    test "ambiguous_op: on a no-parens call with a leading unary +/-" do
      assert_parity("foo -1")
      assert_parity("foo -x")
      assert_parity("@spec -float :: float")
      assert_parity("foo -1, 2")
    end

    test "deprecated and modern not-in anchor not/in keywords" do
      assert_parity("x not in [1, 2]")
      assert_parity("not x in y")
    end

    test "parenthesised multi-statement blocks carry closing: + anchor" do
      assert_parity("(\n a\n b\n)")
      assert_parity("(a; b)")
    end

    test "quoted remote-call names and dot-tuples" do
      assert_parity(~S|foo."bar"(x)|)
      assert_parity("alias Foo.{A, B}")
    end

    test "newlines: is comment-aware (operators / when / containers)" do
      assert_parity("a |>\n # c\n b")
      assert_parity("case x do\n %{} = a\n when b -> c\nend")
      assert_parity("foo.(\n a)")
      assert_parity("[\n # c\n a]")
    end

    test "struct inner map newline counts only the brace, not the %" do
      assert_parity("%CondClauseError{}")
      assert_parity("%Foo{\n a: 1}")
    end

    test "tolerant/invalid input never attaches an impossible end: position" do
      # `if x do\n y` is unterminated — Code.string_to_quoted errors, so there is no oracle. The
      # tolerant pipeline must still parse and must NOT invent an `end:` with column < 1.
      {ast, _} = Toxic2.parse_to_ast("if x do\n y", token_metadata: true)

      bad =
        ast
        |> Macro.prewalk([], fn
          {_, meta, _} = node, acc when is_list(meta) ->
            cols =
              for {_k, [_ | _] = v} <- meta, is_integer(v[:column]) and v[:column] < 1, do: v

            {node, cols ++ acc}

          node, acc ->
            {node, acc}
        end)
        |> elem(1)

      assert bad == [], "impossible (column < 1) positions: #{inspect(bad)}"
    end

    test "Lower.to_ast keeps its pre-token_metadata arities" do
      {cst, _} = Toxic2.parse("a + b")
      {view, _} = Toxic2.Tokens.from_source("a + b", [])
      # arity-4 (old shape: cst, view, opts, start_id) and arity-3 must still work.
      assert {{:+, _, _}, _} = Toxic2.Lower.to_ast(cst, view, [], 1)
      assert {{:+, _, _}, _} = Toxic2.Lower.to_ast(cst, view, [])
    end
  end

  describe "regressions (broad OSS corpus)" do
    test "no_parens only on a ZERO-arity paren-less remote call" do
      assert_parity("a.b")
      assert_parity("a.b.c")
      assert_parity("IO.puts foo(x)")
      assert_parity("Foo.bar a, b")
    end

    test "parenthesised stab heads carry parens: on the ->" do
      assert_parity("fn (a, b) -> a end")
      assert_parity("fn () -> 1 end")
      assert_parity("fn({a, b}) -> x end")
    end

    test "stab -> newlines count before OR after the arrow" do
      assert_parity("case n do\n x when is_number(x)\n   -> x\nend")
      assert_parity("case x do\n a ->\n b\nend")
    end

    test "paren call with a do-block carries closing: for the )" do
      assert_parity("quote(x) do\n y\nend")
      assert_parity("quote(location: :keep) do\n :ok\nend")
    end

    test "parens on encoder-wrapped literals and nested blocks" do
      assert_parity("({a, b})")
      assert_parity("((a))")
      assert_parity("((a; b))")
      assert_parity("(not x)")
    end

    test "multi-line dot-tuples and qualified calls" do
      assert_parity("alias Foo.{\n A,\n B\n}")
      assert_parity("a.unquote(b)(c)")
    end

    test "heredoc sigils with trailing modifiers (indentation discounts them)" do
      assert_parity("~r'''\n  re\n  '''x")
    end

    test "alias with a non-alias base anchors at the dot" do
      assert_parity("__MODULE__.Any")
    end

    test "empty parens: () carries parens:, (;) carries closing: + anchor" do
      assert_parity("()")
      assert_parity("( )")
      assert_parity("(\n)")
      assert_parity("(;)")
      assert_parity("( ; )")
    end

    test "guarded parenthesised stab heads carry parens: on the ->" do
      assert_parity("fn () when x -> y end")
      assert_parity("fn (a, b) when g -> y end")
      assert_parity("fn (a, b, c: 1) when g -> y end")
    end

    test "uppercase sigil names with digits scan the delimiter past the digits" do
      assert_parity("~A1(foo)")
      assert_parity("~HTML(x)")
    end

    test "escaped-newline char literal spans the newline (token: + no extra eoe)" do
      assert_parity("?\\\n")
      assert_parity("?\\\n+ 1")
    end
  end

  describe "GRAMMAR_GAPS §4 (token_metadata / literal_encoder fidelity)" do
    test "4.1 fn -> end implicit nil body is literal-encoded at the -> position" do
      assert_parity("fn -> end")
      assert_parity("fn x -> end")
    end

    test "4.1 fn -> end with a literal_encoder but NO token_metadata encodes the nil body" do
      # The implicit nil body is `handle_literal(nil, ->)` upstream, so it is encoded even in
      # default mode when an encoder is set. (Toxic2 always carries column; the structural shape and
      # the encoded-nil wrapper are what matters here.)
      {ast, _} = Toxic2.parse_to_ast("fn -> end", literal_encoder: @encoder)

      assert {:fn, [], [{:->, [], [[], {:__block__, [line: 1, column: 4], [nil]}]}]} = ast
    end

    test "4.2 bracket-access kw args are passed RAW (not over-encoded)" do
      assert_parity("a[b: 1]")
      assert_parity("x[a: 1, b: 2]")
      # A non-kw list bracket arg IS a list literal and stays encoded.
      assert_parity("a[[1]]")
      assert_parity("a[[]]")
    end

    test "4.3 (1..2)//3 inherits parens: from the parenthesised .." do
      assert_parity("(1..2)//3")
      assert_parity("1..2//3")
    end

    test "4.4 f.(1) do end closing: is the ) of the arg list" do
      assert_parity("f.(1) do end")
      assert_parity("f.(1)")
      assert_parity("f.() do end")
    end

    test "4.5 interpolated charlist dot node carries the opening quote position" do
      assert_parity("'a" <> "\#{" <> "x}b'")
      assert_parity("'" <> "\#{" <> "y}'")
    end

    test "4.6 a\\n.b anchors the dot at the . when it starts a line" do
      assert_parity("a\n.b")
      assert_parity("a.\nb")
      assert_parity("a\n. b")
      assert_parity("a . b")
    end

    test "4.7 %{:a\\n=> 1} keeps assoc: when an eol precedes =>" do
      assert_parity("%{:a\n=> 1}")
      assert_parity("%{x\n=> y}")
    end
  end

  describe "real-world snippets (full meta parity)" do
    @snippets [
      "defmodule Foo do\n  @moduledoc \"hi\"\n  def bar(x), do: x + 1\nend",
      "with {:ok, a} <- f(),\n     {:ok, b} <- g(a) do\n  a + b\nend",
      "list\n|> Enum.map(fn x -> x * 2 end)\n|> Enum.sum()",
      "%Range{first: f, last: l, step: s} = range",
      "case x do\n  1 -> :a\n  n when n > 1 -> :b\n  _ -> :c\nend"
    ]

    test "exact parity" do
      for src <- @snippets, do: assert_parity(src)
    end
  end

  describe "meta key ORDER (order-sensitive, vs oracle)" do
    # `assert_parity` normalises key order, so it cannot catch an ordering regression. The oracle's
    # encoder emits keys in a fixed order and downstream tools (formatter / Sourceror) consume the
    # keyword list positionally, so the order is part of true parity. These cases pin it directly.
    defp assert_key_order(src) do
      {_, mine, _} = mine(src)
      {_, oracle, _} = oracle!(src)
      assert Keyword.keys(mine) == Keyword.keys(oracle), """
      meta key ORDER mismatch for #{inspect(src)}
      oracle: #{inspect(Keyword.keys(oracle))}
      mine:   #{inspect(Keyword.keys(mine))}
      """
    end

    test "multi-line call + do-block: do/end precede newlines precede closing" do
      # Regression: a call with BOTH a multi-line open delimiter and a do-block must order keys
      # `do, end, newlines, closing` (not `newlines, do, end, closing`).
      assert_key_order("foo(\n  a,\n  b\n) do\n  c\nend\n")
    end

    test "multi-line call without a do-block: newlines precedes closing" do
      assert_key_order("foo(\n  a\n)\n")
    end

    test "single-line call with a do-block: no spurious newlines key" do
      assert_key_order("foo(a) do\n  b\nend\n")
    end
  end
end
