defmodule Toxic2.TokensTest do
  use ExUnit.Case, async: true

  alias Toxic2.Tokens

  defp view(src) do
    {t, []} = Tokens.from_source(src)
    t
  end

  describe "indexed access (cursor = integer index)" do
    test "kind/value/token by index" do
      t = view("foo + 1")
      assert Tokens.size(t) == 3

      assert Tokens.kind(t, 0) == :identifier
      assert Tokens.value(t, 0) == "foo"
      assert Tokens.kind(t, 1) == :dual_op
      assert Tokens.value(t, 1) == :+
      assert Tokens.kind(t, 2) == :int
      assert Tokens.value(t, 2) == 1

      assert {:identifier, 1, 1, 1, 4, "foo"} = Tokens.token(t, 0)
      assert Tokens.span(t, 2) == {1, 7, 1, 8}
    end

    test "out-of-range reads as :eof / nil, never crashes" do
      t = view("foo")
      assert Tokens.at_eof?(t, 1)
      assert Tokens.kind(t, 1) == :eof
      assert Tokens.kind(t, 99) == :eof
      assert Tokens.kind(t, -1) == :eof
      assert Tokens.value(t, 1) == nil
      assert Tokens.token(t, 1) == :eof
      assert Tokens.span(t, 1) == nil
      refute Tokens.at_eof?(t, 0)
    end

    test "peek_kind looks ahead (and tolerates running off either end)" do
      t = view("a = b")
      assert Tokens.peek_kind(t, 0, 0) == :identifier
      assert Tokens.peek_kind(t, 0, 1) == :match_op
      assert Tokens.peek_kind(t, 0, 2) == :identifier
      assert Tokens.peek_kind(t, 0, 3) == :eof
      assert Tokens.peek_kind(t, 0, -1) == :eof
    end

    test "empty source" do
      t = view("")
      assert Tokens.size(t) == 0
      assert Tokens.at_eof?(t, 0)
      assert Tokens.kind(t, 0) == :eof
    end
  end

  describe "eol_between?/3 (O(1) prefix index — the anti-O(n²) guardrail)" do
    test "detects a newline strictly across a real-token anchor" do
      # tokens: a(0) eol(1) b(2)
      t = view("a\nb")
      assert Tokens.eol_between?(t, 0, 2)
      refute Tokens.eol_between?(t, 0, 1)
      refute Tokens.eol_between?(t, 2, 3)
    end

    test "no newline between tokens on one line" do
      t = view("a b c")
      refute Tokens.eol_between?(t, 0, 1)
      refute Tokens.eol_between?(t, 0, 3)
    end

    test "counts across coalesced blank lines too" do
      # a(0) eol(count 3)(1) b(2)
      t = view("a\n\n\nb")
      assert Tokens.eol_between?(t, 0, 2)
    end

    test "ranges up to and including size are valid" do
      t = view("a\nb")
      assert Tokens.eol_between?(t, 0, Tokens.size(t))
    end

    test "is total: out-of-range / negative / i > j return false, never crash (review #3)" do
      t = view("a\nb")
      refute Tokens.eol_between?(t, 0, 999)
      refute Tokens.eol_between?(t, -1, 2)
      refute Tokens.eol_between?(t, 2, 0)
      refute Tokens.eol_between?(view(""), 0, 5)
    end
  end

  describe "index-based spacing wrappers (drive call / `a -1` decisions)" do
    test "adjacent? distinguishes foo( from foo (" do
      assert Tokens.adjacent?(view("foo(x)"), 0, 1)
      refute Tokens.adjacent?(view("foo (x)"), 0, 1)
    end

    test "separated_on_same_line?" do
      assert Tokens.separated_on_same_line?(view("foo (x)"), 0, 1)
      refute Tokens.separated_on_same_line?(view("foo(x)"), 0, 1)
    end

    test "same_line? is false across an eol and at eof" do
      t = view("a\nb")
      refute Tokens.same_line?(t, 0, 2)
      refute Tokens.adjacent?(t, 0, 99)
    end
  end
end
