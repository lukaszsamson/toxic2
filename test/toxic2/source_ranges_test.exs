defmodule Toxic2.SourceRangesTest do
  use ExUnit.Case, async: true

  # Selection / source ranges over the green CST (`Toxic2.SourceRanges`) — the basis for editor
  # "expand selection". Unlike the lowered-AST ranges (`Toxic2.RangeMark`, see
  # `range_marking_test.exs`), these surface CST-only structure that lowering discards:
  # parenthesised groups, string/atom content + interpolation bodies, operator tokens, sigil parts,
  # dot-member names, and quoted/INTERPOLATED keyword keys.
  #
  # `«…»` brackets one selectable range (end-exclusive); nesting `«« »»` is parent ⊇ child. The set
  # is every CST node span + every semantic leaf-token span, so it is a strict superset of the
  # AST-node ranges. (Comments aren't retained by the lexer yet, so comment ranges are out of scope.)

  alias Toxic2.SourceRanges, as: SR

  defp m(code), do: Toxic2.RangeMark.render(code, SR.ranges(code))

  describe "the gaps a lowered-AST walk cannot see (the point of this engine)" do
    test "parenthesised groups are their own selectable range" do
      assert m("(1 + 2)") == "«(««1» «+» «2»»)»"
      assert m("((1 + 2))") == "«(«(««1» «+» «2»»)»)»"
      assert m("(foo)") == "«(«foo»)»"
      assert m("foo(bar, (baz))") == "««foo»(«bar», «(«baz»)»)»"
    end

    test "string content fragments and interpolation bodies are selectable" do
      assert m(~S("a#{b}c")) == ~S(«"«a»«#{«b»}»«c»"»)
      assert m(~S(:"x#{y}")) == ~S(«:«"«x»«#{«y»}»"»»)
    end

    test "interpolated keyword keys keep a range (the binary_to_atom AST loses it)" do
      assert m(~S(["a#{x}b": 1])) == ~S(«[««"«a»«#{«x»}»«b»"»: «1»»]»)
    end

    test "operator tokens are selectable" do
      assert m("1 + 2 * 3") == "««1» «+» ««2» «*» «3»»»"
      assert m("a = b = c") == "««a» «=» ««b» «=» «c»»»"
    end
  end

  describe "literals and names" do
    test "scalars, strings, charlists, sigils" do
      assert m("1") == "«1»"
      assert m(":hello") == "«:hello»"
      assert m("true") == "«true»"
      assert m(~S("hello")) == ~S(«"«hello»"»)
      assert m("'chars'") == "«'«chars»'»"
      assert m("~r/re/i") == "««~r»/«re»«/i»»"
    end

    test "variables and attributes" do
      assert m("foo") == "«foo»"
      assert m("@attr") == "««@»«attr»»"
    end
  end

  describe "operators, ranges, membership" do
    test "unary and precedence" do
      assert m("-x") == "««-»«x»»"
      assert m("not a") == "««not» «a»»"
    end

    test "stepped range and membership" do
      assert m("a..b//c") == "«««a»«..»«b»»«//»«c»»"
      assert m("x in [1, 2]") == "««x» «in» «[«1», «2»]»»"
    end
  end

  describe "calls and access" do
    test "paren / no-parens / qualified / dot chains" do
      assert m("foo(a, b)") == "««foo»(«a», «b»)»"
      assert m("foo bar, baz") == "««foo» «bar», «baz»»"
      assert m("Mod.fun(x)") == "««Mod».«fun»(«x»)»"
      assert m("a.b.c") == "«««a».«b»».«c»»"
    end

    test "captures and access" do
      assert m("&foo/1") == "««&»««foo»«/»«1»»»"
      assert m("& &1") == "««&» «&1»»"
      assert m("foo[bar]") == "««foo»[«bar»]»"
    end
  end

  describe "containers, maps, structs" do
    test "lists and tuples" do
      assert m("[1, 2]") == "«[«1», «2»]»"
      assert m("[a | b]") == "«[««a» «|» «b»»]»"
      assert m("{a, b}") == "«{«a», «b»}»"
    end

    test "maps, structs, keyword pairs" do
      assert m("%{a: 1, b: c}") == "«%{««a:» «1»», ««b:» «c»»}»"
      assert m("%{x => y}") == "«%{««x» => «y»»}»"
      assert m("%Foo{a: 1}") == "«%«Foo»«{««a:» «1»»}»»"
      assert m("[a: 1]") == "«[««a:» «1»»]»"
    end

    test "bitstrings" do
      assert m("<<x::8, rest::binary>>") == "«<<««x»«::»«8»», ««rest»«::»«binary»»>>»"
    end
  end

  describe "blocks span through end across lines" do
    test "if/else, case, with, for, fn" do
      assert m("if x do\n  y\nelse\n  z\nend") ==
               "««if» «x» «««do»\n  «y»»\n««else»\n  «z»»\nend»»"

      assert m("case v do\n  1 -> :a\nend") ==
               "««case» «v» «««do»\n  ««1» -> «:a»»»\nend»»"

      assert m("with {:ok, x} <- f() do\n  x\nend") ==
               "««with» ««{«:ok», «x»}» «<-» ««f»()»» «««do»\n  «x»»\nend»»"

      assert m("for i <- l, do: i") == "««for» ««i» «<-» «l»», ««do:» «i»»»"
      assert m("fn x -> x end") == "«fn ««x» -> «x»» end»"
    end
  end

  describe "LSP selection-range invariants" do
    @corpus [
      "foo(a, b) + c.d[e]",
      "(1 + 2) * 3",
      ~S("pre #{x + y} post"),
      "[a: 1, b: foo(2)]",
      "%Foo{m | x: bar(y)}",
      "if a do\n  b\nelse\n  c\nend",
      "case v do\n  {:ok, x} when x > 0 -> x\n  _ -> nil\nend",
      "with {:ok, a} <- f(), {:ok, b} <- g(a) do\n  a + b\nend",
      "fn\n  1 -> :a\n  n when n > 0 -> :b\nend",
      "<<len::32, body::binary-size(len)>>",
      "a |> b() |> c(1, 2)",
      ~S(["k#{i}": v, plain: 2])
    ]

    defp leq?({l1, c1}, {l2, c2}), do: l1 < l2 or (l1 == l2 and c1 <= c2)

    defp disjoint?({_a1, a2}, {b1, _b2}), do: leq?(a2, b1)

    defp nested?({a1, a2}, {b1, b2}),
      do: (leq?(a1, b1) and leq?(b2, a2)) or (leq?(b1, a1) and leq?(a2, b2))

    test "ranges are sorted, well-formed, and never CROSS (always nest or are disjoint)" do
      for src <- @corpus do
        ranges = SR.ranges(src)

        assert ranges == Enum.sort(ranges), "ranges not sorted for #{inspect(src)}"
        assert Enum.all?(ranges, fn {from, to} -> leq?(from, to) end), "ill-formed range #{src}"

        crossing =
          for a <- ranges, b <- ranges, a < b, not disjoint?(a, b), not nested?(a, b), do: {a, b}

        assert crossing == [], "crossing ranges in #{inspect(src)}: #{inspect(crossing)}"
      end
    end

    test "chain_at returns an ordered, strictly-nested parent chain" do
      # cursor on the `y` inside the interpolation of `"pre #{x + y} post"`
      chain = SR.chain_at(~S("pre #{x + y} post"), {1, 11})
      assert chain != []

      assert chain ==
               Enum.sort_by(chain, fn {from, to} -> {from, {-elem(to, 0), -elem(to, 1)}} end)

      # each range in the chain contains the next (outermost first)
      assert Enum.chunk_every(chain, 2, 1, :discard)
             |> Enum.all?(fn [outer, inner] -> nested?(outer, inner) end)

      # the innermost contains the cursor; the outermost is the whole string
      {from, _to} = List.last(chain)
      assert leq?(from, {1, 11})
      # outermost selection is the whole string literal `"pre #{x + y} post"` (19 chars)
      assert List.first(chain) == {{1, 1}, {1, 20}}
    end
  end

  describe "outer_range/1" do
    test "is the whole-program extent" do
      assert SR.outer_range("foo(bar)") == {{1, 1}, {1, 9}}
      assert SR.outer_range("a\n+ b") == {{1, 1}, {2, 4}}
    end
  end
end
