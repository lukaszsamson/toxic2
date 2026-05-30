defmodule Toxic2.CSTTest do
  use ExUnit.Case, async: true

  alias Toxic2.CST

  @span {1, 1, 1, 4}

  describe "leaves" do
    test "plain token leaf" do
      leaf = CST.token(0)
      assert CST.tag(leaf) == :token
      assert CST.token_index(leaf) == 0
      assert CST.node_kind(leaf) == :token
      refute CST.has_error?(leaf)
      refute CST.synthetic?(leaf)
      assert CST.diag_ids(leaf) == []
      assert CST.children(leaf) == []
      assert CST.span(leaf) == nil
    end

    test "error token leaf carries has_error and a diagnostic id" do
      leaf = CST.token(7, error: true, diag: 3)
      assert CST.has_error?(leaf)
      assert CST.diag_ids(leaf) == [3]
    end

    test "missing node is always synthetic + has_error" do
      m = CST.missing(:")", 5, diag: 2)
      assert CST.tag(m) == :missing
      assert CST.node_kind(m) == :")"
      assert CST.anchor_index(m) == 5
      assert CST.has_error?(m)
      assert CST.synthetic?(m)
      assert CST.diag_ids(m) == [2]
    end
  end

  describe "node flag inheritance (P9: computed at construction, never re-walked)" do
    test "has_error propagates up from any child" do
      children = [CST.token(0), CST.token(1, error: true), CST.token(2)]
      n = CST.node(:call, @span, children)
      assert CST.has_error?(n)
      assert CST.children(n) == children
    end

    test "a deep missing child still marks the ancestor has_error" do
      inner = CST.node(:args, @span, [CST.missing(:")", 9)])
      outer = CST.node(:call, @span, [CST.token(0), inner])
      assert CST.has_error?(outer)
    end

    test "no error child → no has_error" do
      refute CST.has_error?(CST.node(:tuple, @span, [CST.token(0), CST.token(1)]))
    end

    test "contains_eol is inherited" do
      n = CST.node(:block, @span, [CST.token(0, contains_eol: true)])
      assert CST.contains_eol?(n)
    end

    test "synthetic is NOT inherited (node-local)" do
      # child is synthetic (missing) but the parent node is a real construct
      n = CST.node(:call, @span, [CST.missing(:")", 0)])
      refute CST.synthetic?(n)
      assert CST.has_error?(n), "but has_error still propagates"
    end
  end

  describe "expression category (node-local, not inherited)" do
    test "set and read each category" do
      assert CST.category(CST.node(:e, @span, [], category: :matched)) == :matched
      assert CST.category(CST.node(:e, @span, [], category: :unmatched)) == :unmatched
      assert CST.category(CST.node(:e, @span, [], category: :no_parens)) == :no_parens
    end

    test "unclassified node has nil category" do
      assert CST.category(CST.node(:e, @span, [])) == nil
    end

    test "a matched node with an unmatched child stays matched (no inheritance)" do
      child = CST.node(:inner, @span, [], category: :unmatched)
      assert CST.category(CST.node(:outer, @span, [child], category: :matched)) == :matched
    end
  end

  describe "diag_ids normalization" do
    test "nil / single / list all read back as a list" do
      assert CST.diag_ids(CST.node(:e, @span, [])) == []
      assert CST.diag_ids(CST.node(:e, @span, [], diag: 4)) == [4]
      assert CST.diag_ids(CST.node(:e, @span, [], diags: [1, 2, 3])) == [1, 2, 3]
    end
  end

  describe "accessors" do
    test "node span and kind" do
      n = CST.node(:list, {2, 3, 2, 9}, [])
      assert CST.span(n) == {2, 3, 2, 9}
      assert CST.node_kind(n) == :list
    end

    test "flags is a non-negative integer bitset" do
      f = CST.flags(CST.token(0, error: true))
      assert is_integer(f) and f >= 0
    end
  end
end
