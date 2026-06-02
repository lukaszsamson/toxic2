defmodule Toxic2.RangeMarkingTest do
  use ExUnit.Case, async: true

  # AST-NODE ranges: `Toxic2.RangeMark.mark/1` reads `meta[:range]` off the lowered AST
  # (`parse_to_ast(src, range: true)` + a literal encoder). This is the COARSER view — it only sees
  # what survives lowering, so it canNOT mark parenthesised groups, string/atom content,
  # interpolation bodies, operator tokens, or interpolated keyword keys. For those (the LSP
  # "selection range" set) see `source_ranges_test.exs` / `Toxic2.SourceRanges`, which walks the CST.
  #
  # `«…»` brackets one node's source extent (end-exclusive); nesting `«« »»` shows parent ⊇ child.

  defp m(code), do: Toxic2.RangeMark.mark(code)

  describe "literals" do
    test "numbers" do
      assert m("1") == "«1»"
      assert m("1_000") == "«1_000»"
      assert m("1.1e10") == "«1.1e10»"
      assert m("0x1F") == "«0x1F»"
      assert m("?a") == "«?a»"
    end

    test "atoms, booleans, nil" do
      assert m(":hello") == "«:hello»"
      assert m(~S(:"with space")) == ~S(«:"with space"»)
      assert m("true") == "«true»"
      assert m("nil") == "«nil»"
    end

    test "strings, charlists, sigils" do
      assert m(~S("hello")) == ~S(«"hello"»)
      assert m(~S("a#{b}c")) == ~S(«"a#{«b»}c"»)
      assert m("'chars'") == "«'chars'»"
      assert m("~r/re/i") == "«~r/re/i»"
    end

    test "variables and attributes" do
      assert m("foo") == "«foo»"
      assert m("_x") == "«_x»"
      assert m("@attr") == "«@«attr»»"
    end
  end

  describe "operators" do
    test "precedence nests tighter operands inside looser ones" do
      assert m("1 + 2 * 3") == "««1» + ««2» * «3»»»"
      assert m("a and b or c") == "«««a» and «b»» or «c»»"
      assert m("a = b = c") == "««a» = ««b» = «c»»»"
      assert m("a <> b <> c") == "««a» <> ««b» <> «c»»»"
    end

    test "unary" do
      assert m("-x") == "«-«x»»"
      assert m("not a") == "«not «a»»"
    end

    test "ranges and membership" do
      assert m("a .. b") == "««a» .. «b»»"
      assert m("a..b//c") == "««a»..«b»//«c»»"
      assert m("x in [1, 2]") == "««x» in «[«1», «2»]»»"
    end
  end

  describe "calls" do
    test "paren and no-parens" do
      assert m("foo(a, b)") == "«foo(«a», «b»)»"
      assert m("foo bar, baz") == "«foo «bar», «baz»»"
    end

    test "qualified, dot chains, anon, captures" do
      assert m("Mod.fun(x)") == "««Mod».fun(«x»)»"
      assert m("a.b.c") == "«««a».b».c»"
      assert m("foo.()") == "««foo».()»"
      assert m("&foo/1") == "«&««foo»/«1»»»"
      assert m("& &1") == "«& «&1»»"
    end
  end

  describe "containers and access" do
    test "lists and tuples" do
      assert m("[1, 2, 3]") == "«[«1», «2», «3»]»"
      assert m("[a | b]") == "«[««a» | «b»»]»"
      assert m("{a, b}") == "«{«a», «b»}»"
      assert m("{1, 2, 3}") == "«{«1», «2», «3»}»"
    end

    test "maps and structs" do
      assert m("%{a: 1, b: c}") == "«%{«a:» «1», «b:» «c»}»"
      assert m("%{x => y}") == "«%{«x» => «y»}»"
      assert m("%Foo{a: 1}") == "«%«Foo»«{«a:» «1»}»»"
      assert m("%Foo{m | a: 1}") == "«%«Foo»«{«m» | «a:» «1»}»»"
    end

    test "access" do
      assert m("foo[bar]") == "««foo»[«bar»]»"
      assert m("a[b][c]") == "«««a»[«b»]»[«c»]»"
    end

    test "bitstrings" do
      assert m("<<x::8, rest::binary>>") == "«<<««x»::«8»», ««rest»::«binary»»>>»"
    end
  end

  describe "blocks (do/end span through end, across lines)" do
    test "if/else" do
      assert m("if x do\n  y\nelse\n  z\nend") ==
               "«if «x» «do»\n  «y»\n«else»\n  «z»\nend»"
    end

    test "case" do
      assert m("case v do\n  1 -> :a\n  _ -> :b\nend") ==
               "«case «v» «do»\n  ««1» -> «:a»»\n  ««_» -> «:b»»\nend»"
    end

    test "with" do
      assert m("with {:ok, x} <- f() do\n  x\nend") ==
               "«with ««{«:ok», «x»}» <- «f()»» «do»\n  «x»\nend»"
    end

    test "for one-liner" do
      assert m("for i <- list, do: i") == "«for ««i» <- «list»», «do:» «i»»"
    end

    test "anonymous functions" do
      assert m("fn x -> x end") == "«fn ««x» -> «x»» end»"
      assert m("fn\n  1 -> :a\n  _ -> :b\nend") == "«fn\n  ««1» -> «:a»»\n  ««_» -> «:b»»\nend»"
    end

    test "def with default arg" do
      assert m("def f(a, b \\\\ 1) do\n  a + b\nend") ==
               "«def «f(«a», ««b» \\\\ «1»»)» «do»\n  ««a» + «b»»\nend»"
    end
  end

  describe "multi-line layout" do
    test "pipe chain across lines" do
      assert m("a |>\n  b() |>\n  c()") == "«««a» |>\n  «b()»» |>\n  «c()»»"
    end

    test "assignment to a multi-line block" do
      assert m("x =\n  if a do\n    1\n  end") == "««x» =\n  «if «a» «do»\n    «1»\n  end»»"
    end

    test "a multi-line list literal" do
      assert m("[\n  1,\n  foo(2),\n  {a, b}\n]") ==
               "«[\n  «1»,\n  «foo(«2»)»,\n  «{«a», «b»}»\n]»"
    end
  end

  # `ast_utils_test.exs` checked one node's outer range via a reconstructing `node_range/1`; here
  # it's read off the root node. Values match ast_show's (its `range(l,c,l,c)` is 0-based; toxic2's
  # is 1-based with an exclusive end — e.g. `true` is ast_show `range(0,0,0,4)` ↔ `{{1,1},{1,5}}`).
  describe "node_range/1 (root node outer range)" do
    test "scalar root" do
      assert Toxic2.RangeMark.node_range("true") == {{1, 1}, {1, 5}}
      assert Toxic2.RangeMark.node_range("1234") == {{1, 1}, {1, 5}}
    end

    test "anonymous function spans through end, across lines" do
      assert Toxic2.RangeMark.node_range("fn a, b -> 1 end") == {{1, 1}, {1, 17}}
      assert Toxic2.RangeMark.node_range("fn\n  1 -> 1\n  _ -> 2\nend") == {{1, 1}, {4, 4}}
    end

    test "with spans through end" do
      assert Toxic2.RangeMark.node_range("with {:ok, x} <- foo() do\n  x\nend") ==
               {{1, 1}, {3, 4}}
    end
  end

  describe "the engine returns sorted, de-duplicated ranges" do
    test "ranges/1 lists every node range, sorted" do
      ranges = Toxic2.RangeMark.ranges("1 + 2")
      assert ranges == Enum.sort([{{1, 1}, {1, 6}}, {{1, 1}, {1, 2}}, {{1, 5}, {1, 6}}])
      assert ranges == Enum.sort(ranges)
    end
  end
end
