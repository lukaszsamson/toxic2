defmodule Toxic2.ParserTest do
  use ExUnit.Case, async: true

  alias Toxic2.{CST, Parser, Tokens}

  defp parse(src) do
    {view, []} = Tokens.from_source(src)
    {cst, diags} = Parser.parse_tokens(view)
    {view, cst, diags}
  end

  defp exprs(src) do
    {view, cst, diags} = parse(src)
    assert CST.node_kind(cst) == :expr_list
    {view, CST.children(cst), diags}
  end

  defp child(node, n), do: Enum.at(CST.children(node), n)
  defp opv(view, node, at), do: Tokens.value(view, CST.token_index(child(node, at)))
  defp leaf_val(view, node), do: Tokens.value(view, CST.token_index(node))

  describe "atoms of the grammar" do
    test "a single literal is one leaf" do
      {view, [e], diags} = exprs("42")
      assert CST.tag(e) == :token
      assert leaf_val(view, e) == 42
      assert diags == []
    end

    test "identifier/atom are leaves; an alias is a 1-segment alias node" do
      {_view, [id, alias_node, atom], []} = exprs("foo Bar :sym")
      assert CST.tag(id) == :token
      assert CST.tag(atom) == :token
      assert CST.node_kind(alias_node) == :alias
    end
  end

  describe "infix operators + precedence (pinned to elixir_parser.yrl)" do
    test "1 + 2 builds a binary_op with [lhs, op, rhs]" do
      {view, [e], []} = exprs("1 + 2")
      assert CST.node_kind(e) == :binary_op
      assert opv(view, e, 1) == :+
      assert leaf_val(view, child(e, 0)) == 1
      assert leaf_val(view, child(e, 2)) == 2
      assert CST.span(e) == {1, 1, 1, 6}
    end

    test "* binds tighter than +" do
      {view, [e], []} = exprs("1 + 2 * 3")
      assert opv(view, e, 1) == :+
      right = child(e, 2)
      assert CST.node_kind(right) == :binary_op
      assert opv(view, right, 1) == :*
    end

    test "+/- are left associative: 1 - 2 - 3 == (1 - 2) - 3" do
      {view, [e], []} = exprs("1 - 2 - 3")
      assert opv(view, e, 1) == :-
      assert CST.node_kind(child(e, 0)) == :binary_op, "left child is the nested subtraction"
      assert leaf_val(view, child(e, 2)) == 3
    end

    test "concat is right associative: 1 ++ 2 ++ 3 == 1 ++ (2 ++ 3)" do
      {view, [e], []} = exprs("1 ++ 2 ++ 3")
      assert opv(view, e, 1) == :++
      assert leaf_val(view, child(e, 0)) == 1
      assert CST.node_kind(child(e, 2)) == :binary_op, "right child is the nested concat"
    end
  end

  describe "prefix operators" do
    test "unary minus" do
      {view, [e], []} = exprs("-1")
      assert CST.node_kind(e) == :unary_op
      assert leaf_val(view, child(e, 0)) == :-
    end

    test "@ attribute and not bind as prefix" do
      {view, [at], []} = exprs("@foo")
      assert CST.node_kind(at) == :unary_op
      assert leaf_val(view, child(at, 0)) == :@

      {view2, [n], []} = exprs("not a")
      assert CST.node_kind(n) == :unary_op
      assert leaf_val(view2, child(n, 0)) == :not
    end

    test "unary binds tighter than binary: -1 + 2 == (-1) + 2" do
      {_view, [e], []} = exprs("-1 + 2")
      assert CST.node_kind(e) == :binary_op
      assert CST.node_kind(child(e, 0)) == :unary_op
    end
  end

  describe "parentheses" do
    test "parens override precedence: (1 + 2) * 3" do
      {_view, [e], []} = exprs("(1 + 2) * 3")
      assert CST.node_kind(e) == :binary_op
      left = child(e, 0)
      assert CST.node_kind(left) == :paren
      assert CST.node_kind(child(left, 0)) == :binary_op
    end
  end

  describe "expression list + layout" do
    test "newlines and semicolons separate top-level expressions" do
      {_v, a, []} = exprs("a\nb")
      assert length(a) == 2

      {_v, b, []} = exprs("a; b; c")
      assert length(b) == 3
    end

    test "a newline AFTER a binary operator continues the expression" do
      {_view, es, []} = exprs("1 +\n2")
      assert length(es) == 1
      assert CST.node_kind(hd(es)) == :binary_op
    end

    test "a newline BEFORE an operator ends the expression (Elixir semantics)" do
      {_view, es, []} = exprs("1\n+ 2")
      assert length(es) == 2
      assert CST.node_kind(Enum.at(es, 1)) == :unary_op
    end
  end

  describe "containers and paren calls (phase 7 slice)" do
    test "list, tuple, and empty forms" do
      assert {_v, [list], []} = exprs("[1, 2, 3]")
      assert CST.node_kind(list) == :list
      assert length(CST.children(list)) == 3

      assert {_v, [tup], []} = exprs("{1, 2}")
      assert CST.node_kind(tup) == :tuple

      assert {_v, [empty], []} = exprs("[]")
      assert CST.children(empty) == []
    end

    test "paren call only when ( is adjacent to the callee" do
      {_v, [call], []} = exprs("f(1, 2)")
      assert CST.node_kind(call) == :call
      # children = [callee | args]
      assert length(CST.children(call)) == 3
    end

    test "nested calls" do
      {_v, [call], []} = exprs("foo(bar(1))")
      assert CST.node_kind(call) == :call
      arg = Enum.at(CST.children(call), 1)
      assert CST.node_kind(arg) == :call
    end

    test "AST conformance for the slice" do
      assert {[1, 2, 3], []} = Toxic2.parse_to_ast("[1, 2, 3]")
      assert {{1, 2}, []} = Toxic2.parse_to_ast("{1, 2}")
      assert {{:{}, _, [1, 2, 3]}, []} = Toxic2.parse_to_ast("{1, 2, 3}")
      assert {{:f, _, [1, 2]}, []} = Toxic2.parse_to_ast("f(1, 2)")
      assert {{:foo, _, [{:bar, _, [1]}]}, []} = Toxic2.parse_to_ast("foo(bar(1))")
    end

    test "missing closer is tolerant, not a crash" do
      {_v, _es, diags} = exprs("[1, 2")
      assert Enum.any?(diags, fn d -> elem(d, 3) == :expected_comma_or_close end)
    end
  end

  describe "dot / alias chains / keywords (phase 7 slice 2)" do
    test "AST conformance for dot forms" do
      assert {{{:., _, [{:a, _, nil}, :b]}, _, []}, []} = Toxic2.parse_to_ast("a.b")
      assert {{{:., _, [{:a, _, nil}, :b]}, _, [1, 2]}, []} = Toxic2.parse_to_ast("a.b(1, 2)")
      assert {{{:., _, [{:a, _, nil}]}, _, [1]}, []} = Toxic2.parse_to_ast("a.(1)")
      assert {{:__aliases__, _, [:Foo, :Bar]}, []} = Toxic2.parse_to_ast("Foo.Bar")

      assert {{{:., _, [{:__aliases__, _, [:Foo]}, :bar]}, _, [1]}, []} =
               Toxic2.parse_to_ast("Foo.bar(1)")
    end

    test "dot chains nest left-associatively" do
      assert {{{:., _, [{{:., _, [{:a, _, nil}, :b]}, _, []}, :c]}, _, []}, []} =
               Toxic2.parse_to_ast("a.b.c")
    end

    test "keyword pairs: inline in lists, collected as a trailing list in calls" do
      assert {[a: 1, b: 2], []} = Toxic2.parse_to_ast("[a: 1, b: 2]")
      assert {[1, {:a, 2}], []} = Toxic2.parse_to_ast("[1, a: 2]")
      assert {{:f, _, [[a: 1]]}, []} = Toxic2.parse_to_ast("f(a: 1)")
      assert {{:f, _, [1, [a: 2]]}, []} = Toxic2.parse_to_ast("f(1, a: 2)")
    end
  end

  describe "maps, structs, bitstrings, access (phase 7 slice 3)" do
    test "maps: assoc, keyword, and update" do
      assert {{:%{}, _, [{{:a, _, nil}, {:b, _, nil}}]}, []} = Toxic2.parse_to_ast("%{a => b}")
      assert {{:%{}, _, [a: 1, b: 2]}, []} = Toxic2.parse_to_ast("%{a: 1, b: 2}")
      assert {{:%{}, _, []}, []} = Toxic2.parse_to_ast("%{}")

      assert {{:%{}, _, [{:|, _, [{:m, _, nil}, [{{:k, _, nil}, {:v, _, nil}}]]}]}, []} =
               Toxic2.parse_to_ast("%{m | k => v}")
    end

    test "structs (incl. update)" do
      assert {{:%, _, [{:__aliases__, _, [:Foo]}, {:%{}, _, [a: 1]}]}, []} =
               Toxic2.parse_to_ast("%Foo{a: 1}")

      assert {{:%, _, [{:__MODULE__, _, nil}, {:%{}, _, []}]}, []} =
               Toxic2.parse_to_ast("%__MODULE__{}")
    end

    test "bitstrings (segments via ::)" do
      assert {{:<<>>, _, [1, 2]}, []} = Toxic2.parse_to_ast("<<1, 2>>")
      assert {{:<<>>, _, []}, []} = Toxic2.parse_to_ast("<<>>")
      assert {{:<<>>, _, [{:"::", _, [1, 8]}]}, []} = Toxic2.parse_to_ast("<<1::8>>")
    end

    test "access lowers to Access.get and nests" do
      assert {{{:., _, [Access, :get]}, _, [{:a, _, nil}, {:b, _, nil}]}, []} =
               Toxic2.parse_to_ast("a[b]")

      assert {{{:., _, [Access, :get]}, _, [{{:., _, [Access, :get]}, _, _}, {:c, _, nil}]}, []} =
               Toxic2.parse_to_ast("a[b][c]")
    end
  end

  describe "tolerant behavior (P1: never crash; one diagnostic per error)" do
    test "a trailing operator yields a binary_op with a missing RHS + one diagnostic" do
      {_view, [e], diags} = exprs("1 +")
      assert CST.node_kind(e) == :binary_op
      assert CST.has_error?(e)
      assert [{_id, :parser, :error, :expected_expression, _, _, _, _, _}] = diags
    end

    test "a stray closer becomes an error leaf + diagnostic, parsing continues" do
      {_view, es, diags} = exprs(") 1")
      assert CST.has_error?(hd(es))
      assert [{_, :parser, :error, :unexpected_token, _, _, _, _, _} | _] = diags
      assert length(es) == 2, "the 1 after the stray closer still parses"
    end

    test "a lexer :error token becomes one :lexer diagnostic (sole transport, no double-report)" do
      {_view, es, diags} = exprs("1 ~ 2")
      assert length(es) == 3
      assert Enum.any?(es, &CST.has_error?/1)
      assert [{_, :lexer, :error, :unexpected_char, _, _, _, _, _}] = diags
    end

    test "missing close paren is recovered, not raised" do
      {_view, _es, diags} = exprs("(1 + 2")
      assert Enum.any?(diags, fn d -> elem(d, 3) == :expected_rparen end)
    end

    test "`=>` is NOT a generic top-level operator (Elixir rejects it outside maps)" do
      {_view, es, diags} = exprs("a => b")
      # must not be a clean binary_op with no diagnostics
      refute match?([{:node, :binary_op, _, _, _, _}], es) and diags == []
      assert Enum.any?(diags, fn d -> elem(d, 3) == :unexpected_token end)
    end
  end
end
