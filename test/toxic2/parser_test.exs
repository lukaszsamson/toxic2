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
      # newline-separated so each is its own statement (adjacent would be a no-parens call)
      {_view, [id, alias_node, atom], []} = exprs("foo\nBar\n:sym")
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

  describe "permissive-grammar edges" do
    test "trailing commas are valid in lists/tuples/bitstrings, but not calls" do
      assert {[1], []} = Toxic2.parse_to_ast("[1,]")
      assert {{:{}, _, [1]}, []} = Toxic2.parse_to_ast("{1,}")
      assert {{:<<>>, _, [1]}, []} = Toxic2.parse_to_ast("<<1,>>")

      {_v, _es, diags} = exprs("f(1,)")
      assert Enum.any?(diags, &(elem(&1, 3) == :unexpected_trailing_comma))
    end

    test "keyword-last is enforced" do
      for src <- ["f(a: 1, 2)", "[a: 1, 2]", "[1, a: 2, 3]"] do
        {_v, _es, diags} = exprs(src)

        assert Enum.any?(diags, &(elem(&1, 3) == :keyword_not_last)),
               "#{src} must flag keyword_not_last"
      end
    end

    test "keywords are not allowed inside tuples/bitstrings" do
      {_v, _es, diags} = exprs("{a: 1}")
      assert Enum.any?(diags, &(elem(&1, 3) == :keyword_not_allowed))
    end

    test "empty map/struct update is an error" do
      {_v, _es, d1} = exprs("%{m |}")
      assert Enum.any?(d1, &(elem(&1, 3) == :empty_map_update))
    end

    test "a dot may continue on the next line (a\\n.b)" do
      assert {{{:., _, [{:a, _, nil}, :b]}, _, []}, []} = Toxic2.parse_to_ast("a\n.b")
    end

    test "maps allow assoc-then-keyword (keyword last)" do
      assert {{:%{}, _, [{{:a, _, nil}, 1}, {:b, 2}]}, []} =
               Toxic2.parse_to_ast("%{a => 1, b: 2}")
    end
  end

  describe "no-parens calls (phase 8)" do
    test "single and multiple args at statement position" do
      assert {{:f, _, [{:a, _, nil}]}, []} = Toxic2.parse_to_ast("f a")
      assert {{:f, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("f a, b")

      assert {{:f, _, [{:+, _, [{:a, _, nil}, {:b, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("f a + b")
    end

    test "f g a, b makes the inner call absorb the commas (outer arity 1)" do
      assert {{:f, _, [{:g, _, [{:a, _, nil}, {:b, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("f g a, b")

      assert {{:g, _, [{:f, _, [{:a, _, nil}]}]}, []} = Toxic2.parse_to_ast("g f a")
    end

    test "`f -1` is a call with a unary arg; `f - 1` is binary subtraction" do
      assert {{:f, _, [{:-, _, [1]}]}, []} = Toxic2.parse_to_ast("f -1")
      assert {{:-, _, [{:f, _, nil}, 1]}, []} = Toxic2.parse_to_ast("f - 1")
    end

    test "no-parens as an operator operand and after `=`" do
      assert {{:+, _, [1, {:f, _, [{:a, _, nil}]}]}, []} = Toxic2.parse_to_ast("1 + f a")

      assert {{:=, _, [{:x, _, nil}, {:f, _, [{:a, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("x = f a")
    end

    test "trailing keyword args collect into a list; single-arg call as a list element" do
      assert {{:f, _, [{:a, _, nil}, [b: 1]]}, []} = Toxic2.parse_to_ast("f a, b: 1")
      assert {[{:f, _, [{:a, _, nil}]}], []} = Toxic2.parse_to_ast("[f a]")
    end

    test "remote no-parens calls" do
      assert {{{:., _, [{:a, _, nil}, :b]}, _, [{:c, _, nil}]}, []} = Toxic2.parse_to_ast("a.b c")

      assert {{{:., _, [{:a, _, nil}, :b]}, _, [{:c, _, nil}, {:d, _, nil}]}, []} =
               Toxic2.parse_to_ast("a.b c, d")
    end

    test "a no-parens call as a non-last container element is ambiguous (error)" do
      {_v, _es, diags} = exprs("[f a, b]")
      assert Enum.any?(diags, &(elem(&1, 3) == :ambiguous_no_parens))
      # but as the last element it is fine
      assert {[{:b, _, nil}, {:f, _, [{:a, _, nil}]}], []} = Toxic2.parse_to_ast("[b, f a]")
    end

    test "leftover same-line tokens are an error; chained no-parens is fine" do
      assert {{:a, _, [{:b, _, [{:c, _, nil}]}]}, []} = Toxic2.parse_to_ast("a b c")

      for src <- ["1 2", "Foo bar", "Foo.Bar a"] do
        {_v, _es, diags} = exprs(src)
        assert Enum.any?(diags, &(elem(&1, 3) == :unexpected_token)), "#{src} must flag leftover"
      end
    end

    test "newline allowed after a comma; keyword-last enforced in no-parens calls" do
      assert {{:f, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("f a,\n b")

      for src <- ["f a: 1, b", "f a, b: 1, c"] do
        {_v, _es, diags} = exprs(src)
        assert Enum.any?(diags, &(elem(&1, 3) == :keyword_not_last)), "#{src} must flag kw-last"
      end
    end

    test "`a not in b` is the not-in operator (rewritten in lowering, no warning)" do
      assert {{:not, _, [{:in, _, [{:a, _, nil}, {:b, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("a not in b")

      assert {{:f, _, [{:not, _, [{:x, _, nil}]}]}, []} = Toxic2.parse_to_ast("f not x")
    end
  end

  describe "fn / stab clauses (phase 9)" do
    test "single clause, args, body" do
      assert {{:fn, _, [{:->, _, [[], :ok]}]}, []} = Toxic2.parse_to_ast("fn -> :ok end")

      assert {{:fn, _, [{:->, _, [[{:x, _, nil}], {:x, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("fn x -> x end")

      assert {{:fn, _, [{:->, _, [[{:x, _, nil}, {:y, _, nil}], {:+, _, _}]}]}, []} =
               Toxic2.parse_to_ast("fn x, y -> x + y end")
    end

    test "multiple clauses" do
      assert {{:fn, _, [{:->, _, [[1], :one]}, {:->, _, [[2], :two]}]}, []} =
               Toxic2.parse_to_ast("fn 1 -> :one\n 2 -> :two end")
    end

    test "when guard wraps the patterns; empty body is nil" do
      assert {{:fn, _, [{:->, _, [[{:when, _, [{:x, _, nil}, {:>, _, _}]}], {:x, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("fn x when x > 0 -> x end")

      assert {{:fn, _, [{:->, _, [[], nil]}]}, []} = Toxic2.parse_to_ast("fn -> end")
    end

    test "multi-statement body lowers to a block" do
      assert {{:fn, _, [{:->, _, [[{:x, _, nil}], {:__block__, _, [_, _]}]}]}, []} =
               Toxic2.parse_to_ast("fn x -> y = x\n y end")
    end

    test "fn missing end is tolerant" do
      {_v, _es, diags} = exprs("fn x -> x")
      assert Enum.any?(diags, &(elem(&1, 3) == :expected_end))
    end

    test "empty fn is an error" do
      {_v, _es, diags} = exprs("fn end")
      assert Enum.any?(diags, &(elem(&1, 3) == :missing_clauses))
    end

    test "missing end in a do-block does NOT crash lowering (totality, P5)" do
      for src <- ["if x do y", "foo do", "case x do 1 -> y"] do
        {ast, diags} = Toxic2.parse_to_ast(src)
        assert is_tuple(ast) or is_atom(ast)
        assert Enum.any?(diags, &(elem(&1, 3) == :expected_end)), "#{src}"
      end
    end

    test "leftover same-line tokens inside bodies are an error" do
      for src <- ["fn -> 1 2 end", "if x do 1 2 end", "case x do 1 -> 2 3 end"] do
        {_v, _es, diags} = exprs(src)
        assert Enum.any?(diags, &(elem(&1, 3) == :unexpected_token)), "#{src}"
      end
    end
  end

  describe "strings / interpolation (phase 10)" do
    test "a plain string is a :string node of fragment leaves, no diagnostics" do
      {view, [s], diags} = exprs(~S("abc"))
      assert CST.node_kind(s) == :string
      assert [frag] = CST.children(s)
      assert Tokens.value(view, CST.token_index(frag)) == "abc"
      assert diags == []
    end

    test "interpolation parses an :interp child holding the inner expression" do
      {_view, [s], diags} = exprs("\"a\#{b}c\"")
      assert CST.node_kind(s) == :string
      kinds = Enum.map(CST.children(s), fn c -> CST.tag(c) end)
      assert :node in kinds
      interp = Enum.find(CST.children(s), &(CST.tag(&1) == :node))
      assert CST.node_kind(interp) == :interp
      assert diags == []
    end

    test "no-interpolation string lowers to a bare binary" do
      assert {"abc", []} = Toxic2.parse_to_ast(~S("abc"))
      assert {"", []} = Toxic2.parse_to_ast(~S(""))
    end

    test "interpolation lowers to the Kernel.to_string <<>> form" do
      {ast, diags} = Toxic2.parse_to_ast("\"a\#{b}c\"")

      assert {:<<>>, _,
              [
                "a",
                {:"::", _,
                 [{{:., _, [Kernel, :to_string]}, _, [{:b, _, nil}]}, {:binary, _, nil}]},
                "c"
              ]} = ast

      assert diags == []
    end

    test "an unterminated string does not crash and reports one error" do
      {ast, diags} = Toxic2.parse_to_ast(~S("abc))
      assert is_binary(ast) or is_tuple(ast)
      assert Enum.any?(diags, &(elem(&1, 3) == :string_missing_terminator))
    end

    test "charlists: a :charlist node, lowering to a codepoint list or List.to_charlist form" do
      {_view, [c], []} = exprs("'abc'")
      assert CST.node_kind(c) == :charlist

      assert {[97, 98, 99], []} = Toxic2.parse_to_ast("'abc'")
      assert {[], []} = Toxic2.parse_to_ast("''")

      {ast, []} = Toxic2.parse_to_ast("'a\#{b}c'")

      assert {{:., _, [List, :to_charlist]}, _,
              [["a", {{:., _, [Kernel, :to_string]}, _, [{:b, _, nil}]}, "c"]]} = ast
    end

    test "sigils: name, content <<>>, and modifier charlist" do
      {_view, [s], []} = exprs("~r/foo/i")
      assert CST.node_kind(s) == :sigil

      assert {:sigil_r, _, [{:<<>>, _, ["foo"]}, ~c"i"]} =
               elem(Toxic2.parse_to_ast("~r/foo/i"), 0)

      assert {:sigil_w, _, [{:<<>>, _, ["a b c"]}, ~c"a"]} =
               elem(Toxic2.parse_to_ast("~w(a b c)a"), 0)

      assert {:sigil_s, _, [{:<<>>, _, [""]}, []]} = elem(Toxic2.parse_to_ast("~s()"), 0)

      # uppercase sigils are raw: no escape/interpolation processing at parse time
      assert {:sigil_S, _, [{:<<>>, _, ["raw\#{x}"]}, []]} =
               elem(Toxic2.parse_to_ast("~S(raw\#{x})"), 0)

      # lowercase sigils interpolate
      assert {:sigil_s, _, [{:<<>>, _, ["a", {:"::", _, _}]}, []]} =
               elem(Toxic2.parse_to_ast("~s(a\#{b})"), 0)
    end

    test "heredocs: indentation stripped, lowering shared with strings/charlists" do
      assert {"hello\n", []} = Toxic2.parse_to_ast("\"\"\"\nhello\n\"\"\"")
      assert {"a\nb\n", []} = Toxic2.parse_to_ast("\"\"\"\n  a\n  b\n  \"\"\"")
      # a charlist heredoc uses ''' ; ~c""" is a sigil heredoc (:sigil_c)
      assert {~c"c\n", _} = Toxic2.parse_to_ast("'''\nc\n'''")

      assert {{:sigil_c, _, [{:<<>>, _, ["c\n"]}, []]}, _} =
               Toxic2.parse_to_ast("~c\"\"\"\nc\n\"\"\"")

      {ast, []} = Toxic2.parse_to_ast("\"\"\"\nx\#{y}z\n\"\"\"")
      assert {:<<>>, _, ["x", {:"::", _, _}, "z\n"]} = ast
    end

    test "quoted strings/charlists may span newlines (not just heredocs)" do
      assert {"a\nb", []} = Toxic2.parse_to_ast("\"a\nb\"")
      assert {~c"a\nb", []} = Toxic2.parse_to_ast("'a\nb'")
    end

    test "full escape forms decode like Elixir (hex / unicode / line continuation)" do
      assert {"a", []} = Toxic2.parse_to_ast("\"\\x61\"")
      assert {"a", []} = Toxic2.parse_to_ast("\"\\u0061\"")
      assert {"a", []} = Toxic2.parse_to_ast("\"\\u{61}\"")
      # line continuation: backslash-newline is removed entirely
      assert {"ab", []} = Toxic2.parse_to_ast("\"a\\\nb\"")
      # \xHH is a raw byte; \u{..} is a codepoint
      assert {"😀", []} = Toxic2.parse_to_ast("\"\\u{1F600}\"")
    end

    test "an unterminated heredoc does not crash and reports one error" do
      {_ast, diags} = Toxic2.parse_to_ast("\"\"\"\nno end here\n")
      assert Enum.any?(diags, &(elem(&1, 3) == :heredoc_missing_terminator))
    end
  end

  describe "& capture (phase: access_expr island)" do
    test "&N capture argument lowers to {:&, _, [N]}" do
      assert {{:&, _, [1]}, []} = Toxic2.parse_to_ast("&1")
      assert {{:&, _, [0]}, []} = Toxic2.parse_to_ast("&0")
    end

    test "&expr captures the whole following expression (prec 90)" do
      # `&` grabs across `+` (210) but a capture-int operand is atomic
      assert {{:&, _, [{:+, _, [{:&, _, [1]}, {:&, _, [2]}]}]}, []} =
               Toxic2.parse_to_ast("& &1 + &2")

      # ...and across `|>` (160)
      assert {{:&, _, [{:|>, _, [{:/, _, [{:abs, _, nil}, 1]}, {:foo, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("&abs/1 |> foo")
    end

    test "function captures name/arity" do
      assert {{:&, _, [{:/, _, [{:foo, _, nil}, 1]}]}, []} = Toxic2.parse_to_ast("&foo/1")

      assert {{:&, _, [{:/, _, [{{:., _, [{:__aliases__, _, [:Mod]}, :fun]}, _, []}, 2]}]}, []} =
               Toxic2.parse_to_ast("&Mod.fun/2")
    end

    test "& as a call/container arg, and `|` binds looser than capture" do
      assert {{:f, _, [{:&, _, [1]}]}, []} = Toxic2.parse_to_ast("f(&1)")
      # `|` (70) < capture (90): NOT captured -> (&x) | y
      assert {{:|, _, [{:&, _, [{:x, _, nil}]}, {:y, _, nil}]}, []} =
               Toxic2.parse_to_ast("&x | y")
    end
  end

  describe "chained / double-parens calls" do
    test "two paren-call groups per base are allowed and nest left" do
      assert {{{:foo, _, []}, _, []}, []} = Toxic2.parse_to_ast("foo()()")
      assert {{{:foo, _, [1]}, _, [2]}, []} = Toxic2.parse_to_ast("foo(1)(2)")

      assert {{{{:., _, [{:foo, _, nil}, :bar]}, _, []}, _, []}, []} =
               Toxic2.parse_to_ast("foo.bar()()")

      assert {{{{:., _, [{:a, _, nil}]}, _, []}, _, []}, []} = Toxic2.parse_to_ast("a.()()")
    end

    test "a third group is rejected (tolerant), not parsed" do
      {_ast, diags} = Toxic2.parse_to_ast("foo()()()")
      assert Enum.any?(diags, &(elem(&1, 2) == :error))
    end

    test "alias / access callees do not take a paren-call" do
      for src <- ["Foo.Bar()", "foo[0]()"] do
        {_ast, diags} = Toxic2.parse_to_ast(src)
        assert Enum.any?(diags, &(elem(&1, 2) == :error)), src
      end
    end
  end

  describe "not in (lowering rewrite + deprecation)" do
    test "`not a in b` rewrites to not(a in b) with a deprecation warning" do
      {ast, diags} = Toxic2.parse_to_ast("not a in b")
      assert {:not, _, [{:in, _, [{:a, _, nil}, {:b, _, nil}]}]} = ast
      assert Enum.any?(diags, &(elem(&1, 1) == :lowerer and elem(&1, 3) == :deprecated_not_in))
      # warning, not error — valid code still conforms
      refute Enum.any?(diags, &(elem(&1, 2) == :error))
    end
  end

  describe "do/end blocks (phase 9)" do
    test "do-block attaches as a [do: ...] keyword arg" do
      assert {{:if, _, [{:x, _, nil}, [do: {:y, _, nil}]]}, []} =
               Toxic2.parse_to_ast("if x do y end")

      assert {{:foo, _, [[do: :ok]]}, []} = Toxic2.parse_to_ast("foo do :ok end")

      assert {{:foo, _, [{:a, _, nil}, {:b, _, nil}, [do: {:x, _, nil}]]}, []} =
               Toxic2.parse_to_ast("foo a, b do x end")
    end

    test "do attaches to the OUTER call (foo bar do end)" do
      assert {{:foo, _, [{:bar, _, nil}, [do: :ok]]}, []} =
               Toxic2.parse_to_ast("foo bar do :ok end")
    end

    test "block labels (else/rescue/after)" do
      assert {{:if, _, [{:x, _, nil}, [do: {:y, _, nil}, else: {:z, _, nil}]]}, []} =
               Toxic2.parse_to_ast("if x do y else z end")

      assert {{:try, _, [[do: {:x, _, nil}, after: {:z, _, nil}]]}, []} =
               Toxic2.parse_to_ast("try do x after z end")
    end

    test "stab-clause bodies (case/cond)" do
      assert {{:case, _, [{:x, _, nil}, [do: [{:->, _, [[1], :a]}, {:->, _, [[2], :b]}]]]}, []} =
               Toxic2.parse_to_ast("case x do 1 -> :a\n 2 -> :b end")
    end

    test "multi-statement body lowers to a block" do
      assert {{:if, _, [{:x, _, nil}, [do: {:__block__, _, [_, _]}]]}, []} =
               Toxic2.parse_to_ast("if x do\n a\n b\n end")
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
      assert Enum.any?(diags, &(elem(&1, 3) == :unexpected_token))
    end

    test "a lexer :error token surfaces a :lexer diagnostic (sole transport)" do
      {_view, _es, diags} = exprs("1 ~ 2")
      assert Enum.any?(diags, &(elem(&1, 1) == :lexer and elem(&1, 3) == :unexpected_char))
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
