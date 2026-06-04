defmodule Toxic2.ParserTest do
  use ExUnit.Case, async: true

  alias Toxic2.{CST, Parser, Tokens}

  defp parse(src) do
    # `from_source` now also returns lexer warning notices; these unit tests assert on parser diags.
    {view, _notices} = Tokens.from_source(src)
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

    test "`..`/`...` are nullary, and `...` is a low-precedence unary prefix" do
      assert {{:.., _, []}, []} = Toxic2.parse_to_ast("..")
      assert {{:..., _, []}, []} = Toxic2.parse_to_ast("...")
      assert {{:..., _, [{:x, _, nil}]}, []} = Toxic2.parse_to_ast("...x")
      # unary `...` grabs the whole following expression
      assert {{:..., _, [{:+, _, [{:a, _, nil}, {:b, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("...a + b")

      # `..` is never unary: `..-a` is `(..) - a`, and nullary `...` is a normal RHS operand
      assert {{:-, _, [{:.., _, []}, {:a, _, nil}]}, []} = Toxic2.parse_to_ast("..-a")
      assert {{:+, _, [1, {:..., _, []}]}, []} = Toxic2.parse_to_ast("1 + ...")
      # binary range is unaffected
      assert {{:.., _, [1, 10]}, []} = Toxic2.parse_to_ast("1..10")
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

    test "multi-statement parens lower to a block; single is transparent; empty is an empty block" do
      assert {{:__block__, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("(a; b)")
      assert {{:a, _, nil}, []} = Toxic2.parse_to_ast("(a)")
      assert {{:a, _, nil}, []} = Toxic2.parse_to_ast("(a;)")
      # `(;)` is a `;`-block (NOT the `empty_paren` rule), so it does NOT warn — unlike `()`
      assert {{:__block__, _, []}, []} = Toxic2.parse_to_ast("(;)")
      assert {{:__block__, _, []}, [_empty_paren]} = Toxic2.parse_to_ast("()")
      # inner statements are a no-parens context
      assert {{:f, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("(f a, b)")
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

    test "a newline BEFORE +/- ends the expression (they can be unary)" do
      {_view, es, []} = exprs("1\n+ 2")
      assert length(es) == 2
      assert CST.node_kind(Enum.at(es, 1)) == :unary_op
    end

    test "a newline BEFORE a binary-only operator continues it (multi-line pipes)" do
      {_v, es, []} = exprs("a\n|> b")
      assert length(es) == 1
      assert {{:|>, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("a\n|> b")

      assert {{:|>, _, [{:|>, _, [{:foo, _, []}, {:bar, _, []}]}, {:baz, _, []}]}, []} =
               Toxic2.parse_to_ast("foo()\n|> bar()\n|> baz()")
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

    test "a no-parens-call keyword value must be the last element" do
      assert {{:f, _, [[a: {:g, _, [{:b, _, nil}]}]]}, []} = Toxic2.parse_to_ast("f(a: g b)")

      {_a, diags} = Toxic2.parse_to_ast("f(a: g b, c)")
      assert Enum.any?(diags, &(elem(&1, 3) == :no_parens_kw_not_last))
    end

    test "a dangling dot does not crash lowering (totality, P5)" do
      {ast, diags} = Toxic2.parse_to_ast("foo.")
      assert is_tuple(ast) or is_atom(ast)
      assert Enum.any?(diags, &(elem(&1, 2) == :error))
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

    test "dot-quoted remote calls use the string as the function-name atom" do
      # the quotes are unnecessary here, so each call carries a deprecation/unnecessary warning
      assert {{{:., _, [{:a, _, nil}, :foo]}, _, []}, [_]} = Toxic2.parse_to_ast("a.\"foo\"")
      assert {{{:., _, [{:a, _, nil}, :foo]}, _, [1]}, [_]} = Toxic2.parse_to_ast("a.\"foo\"(1)")
      # single-quoted: both the single-quote-call deprecation and the unnecessary-quote note
      assert {{{:., _, [{:a, _, nil}, :foo]}, _, []}, [_, _]} = Toxic2.parse_to_ast("a.'foo'")
      # an interpolated name is rejected (tolerantly)
      {_a, diags} = Toxic2.parse_to_ast("a.\"f\#{x}\"")
      assert Enum.any?(diags, &(elem(&1, 2) == :error))
    end

    test "dot chains nest left-associatively" do
      assert {{{:., _, [{{:., _, [{:a, _, nil}, :b]}, _, []}, :c]}, _, []}, []} =
               Toxic2.parse_to_ast("a.b.c")
    end

    test "quoted keyword keys: \"foo\": v / 'bar': v / interpolated key" do
      # `foo` / `bar` / `k` don't need quotes → an unnecessary-quoted-keyword warning each
      assert {[foo: 1], [_]} = Toxic2.parse_to_ast("[\"foo\": 1]")
      assert {[bar: 2], [_]} = Toxic2.parse_to_ast("['bar': 2]")
      # `"a b"` genuinely needs quotes → no warning
      assert {["a b": 1], []} = Toxic2.parse_to_ast("[\"a b\": 1]")
      assert {{:%{}, _, [k: 1]}, [_]} = Toxic2.parse_to_ast("%{\"k\": 1}")

      {ast, []} = Toxic2.parse_to_ast("[\"f\#{x}\": 1]")
      assert [{{{:., _, [:erlang, :binary_to_atom]}, _, _}, 1}] = ast
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

    test "maps/structs accept bare-expression entries, mixed with => and kw" do
      assert {{:%{}, _, [{:x, _, nil}]}, []} = Toxic2.parse_to_ast("%{x}")
      assert {{:%{}, _, [{:x, _, nil}, {:y, _, nil}]}, []} = Toxic2.parse_to_ast("%{x, y}")

      assert {{:%{}, _, [{{:x, _, nil}, 1}, {:y, _, nil}]}, []} =
               Toxic2.parse_to_ast("%{x => 1, y}")

      assert {{:%{}, _, [{:x, _, nil}, {:a, 1}]}, []} = Toxic2.parse_to_ast("%{x, a: 1}")

      assert {{:%, _, [{:__aliases__, _, [:Foo]}, {:%{}, _, [{:x, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("%Foo{x}")

      # a keyword that isn't last is still rejected
      {_a, diags} = Toxic2.parse_to_ast("%{a: 1, x}")
      assert Enum.any?(diags, &(elem(&1, 2) == :error))
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

    test "a paren call allows a trailing comma only after a keyword arg" do
      # parsed, but Elixir warns that trailing commas aren't allowed in call args
      assert {{:foo, _, [[bar: 1]]}, [_trailing]} = Toxic2.parse_to_ast("foo(bar: 1,)")
      assert {{:foo, _, [1, [a: 2]]}, [_trailing]} = Toxic2.parse_to_ast("foo(1, a: 2,)")

      # a trailing comma after a positional arg is still rejected
      {_v, _es, diags} = exprs("foo(1, 2,)")
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

    test "a string/heredoc adjacent to the callee (no space) is a no-parens argument" do
      assert {{:foo, _, ["bar"]}, []} = Toxic2.parse_to_ast(~S|foo"bar"|)
      assert {{{:., _, [{:a, _, nil}, :b]}, _, ["str"]}, []} = Toxic2.parse_to_ast(~S|a.b"str"|)

      # `f -1` stays a call with a (unary-minus) arg; `f - 1` stays subtraction (no string involved)
      assert {{:f, _, [{:-, _, [1]}]}, []} = Toxic2.parse_to_ast("f -1")
      assert {{:-, _, [{:f, _, nil}, 1]}, []} = Toxic2.parse_to_ast("f - 1")
    end

    test "a `\\`-newline joins a no-parens callee with an arg on the next line" do
      assert {{:@, _, [{:x, _, [{{:., _, [{:__aliases__, _, [:File]}, :foo]}, _, []}]}]}, []} =
               Toxic2.parse_to_ast("@x \\\nFile.foo()")

      # `+`/`-` directly across a (no-space) continuation are binary, not a unary arg
      assert {{:+, _, [{:foo, _, nil}, 1]}, []} = Toxic2.parse_to_ast("foo\\\n+1")
    end

    test "a multi-arg no-parens call ending in `do…end` is a valid container element" do
      assert {[{:for, _, [{:<-, _, _}, {:<-, _, _}, [do: _]]}], []} =
               Toxic2.parse_to_ast("[for x <- a, y <- b do x end]")

      # a bare no-parens call (no do-block) is still ambiguous as a non-last element
      {_a, diags} = Toxic2.parse_to_ast("[f a, b]")
      assert Enum.any?(diags, &(elem(&1, 3) == :ambiguous_no_parens))
    end

    test "remote no-parens calls" do
      assert {{{:., _, [{:a, _, nil}, :b]}, _, [{:c, _, nil}]}, []} = Toxic2.parse_to_ast("a.b c")

      assert {{{:., _, [{:a, _, nil}, :b]}, _, [{:c, _, nil}, {:d, _, nil}]}, []} =
               Toxic2.parse_to_ast("a.b c, d")
    end

    test "a newline is allowed after `[` before the index (`foo[\\n:bar]`)" do
      assert {{{:., _, [Access, :get]}, _, [{:foo, _, nil}, :bar]}, []} =
               Toxic2.parse_to_ast("foo[\n:bar]")
    end

    test "access takes one index, with an optional trailing comma (`foo[1,]`)" do
      assert {{{:., _, [Access, :get]}, _, [{:foo, _, nil}, 1]}, []} =
               Toxic2.parse_to_ast("foo[1,]")

      # a real second index is still rejected
      {_a, diags} = Toxic2.parse_to_ast("foo[a, b]")
      assert diags != []
    end

    test "a no-parens call as a non-last container element is ambiguous (error)" do
      {_v, _es, diags} = exprs("[f a, b]")
      assert Enum.any?(diags, &(elem(&1, 3) == :ambiguous_no_parens))
      # but as the last element it is fine
      assert {[{:b, _, nil}, {:f, _, [{:a, _, nil}]}], []} = Toxic2.parse_to_ast("[b, f a]")
    end

    test "an operator's rightmost operand may be a multi-arg no-parens call (no_parens_op_expr)" do
      assert {{:+, _, [1, {:foo, _, [2, 3]}]}, []} = Toxic2.parse_to_ast("1 + foo 2, 3")

      # piping into a no-parens call is parsed, but carries the ambiguous-pipe warning
      assert {{:|>, _, [{:a, _, nil}, {:foo, _, [1, 2]}]}, [_ambiguous_pipe]} =
               Toxic2.parse_to_ast("a |> foo 1, 2")

      # a do-block still attaches to that rightmost operand
      assert {{:+, _, [1, {:if, _, [{:x, _, nil}, [do: :ok]]}]}, []} =
               Toxic2.parse_to_ast("1 + if x do :ok end")

      # but inside brackets the element stays single-arg (the comma is the delimiter)
      assert {[{:+, _, [1, {:foo, _, [2]}]}, 3], []} = Toxic2.parse_to_ast("[1 + foo 2, 3]")
    end

    test "a unary prefix's rightmost operand may be a multi-arg no-parens call" do
      assert {{:@, _, [{:foo, _, [1, 2]}]}, []} = Toxic2.parse_to_ast("@foo 1, 2")
      assert {{:-, _, [{:foo, _, [1, 2]}]}, []} = Toxic2.parse_to_ast("-foo 1, 2")
      assert {{:not, _, [{:bar, _, [:a, :b]}]}, []} = Toxic2.parse_to_ast("not bar :a, :b")
    end

    test "reserved words and operators are valid remote-call member names" do
      assert {{{:., _, [{:flags, _, nil}, true]}, _, []}, []} = Toxic2.parse_to_ast("flags.true")
      assert {{{:., _, [{:c, _, nil}, nil]}, _, []}, []} = Toxic2.parse_to_ast("c.nil")
      assert {{{:., _, [{:a, _, nil}, :when]}, _, []}, []} = Toxic2.parse_to_ast("a.when")
      assert {{{:., _, [{:a, _, nil}, :do]}, _, []}, []} = Toxic2.parse_to_ast("a.do")

      assert {{{:., _, [{:__aliases__, _, [:Kernel]}, :+]}, _, []}, []} =
               Toxic2.parse_to_ast("Kernel.+")

      assert {{{:., _, [{:foo, _, nil}, :++]}, _, [1, 2]}, []} =
               Toxic2.parse_to_ast("foo.++(1, 2)")

      # `->` / `=>` / `//` are NOT valid members
      {_a, diags} = Toxic2.parse_to_ast("a.->")
      assert Enum.any?(diags, &(elem(&1, 3) == :unexpected_after_dot))
    end

    test "operator function references (`op/arity`) — bare and captured" do
      assert {{:/, _, [{:+, _, nil}, 2]}, []} = Toxic2.parse_to_ast("+/2")
      assert {{:/, _, [{:>=, _, nil}, 2]}, []} = Toxic2.parse_to_ast(">=/2")
      assert {{:&, _, [{:/, _, [{:++, _, nil}, 2]}]}, []} = Toxic2.parse_to_ast("&++/2")
      # ordinary division is unaffected
      assert {{:/, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("a / b")
    end

    test "`when` uniquely takes a bare keyword list on the right" do
      assert {{:when, _, [{:x, _, nil}, [foo: 1]]}, []} = Toxic2.parse_to_ast("x when foo: 1")

      assert {{:when, _, [{:x, _, nil}, [foo: 1, bar: 2]]}, []} =
               Toxic2.parse_to_ast("x when foo: 1, bar: 2")

      # the keyword value is a multi-arg no-parens call → nested-no-parens-keyword warning
      assert {{:when, _, [{:x, _, nil}, [foo: {:bar, _, [1, 2]}]]}, [_nested]} =
               Toxic2.parse_to_ast("x when foo: bar 1, 2")
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

      # an empty `->` body warns (an expression is required after ->) but still lowers to nil
      assert {{:fn, _, [{:->, _, [[], nil]}]}, [_empty_stab]} = Toxic2.parse_to_ast("fn -> end")
    end

    test "multi-statement body lowers to a block" do
      assert {{:fn, _, [{:->, _, [[{:x, _, nil}], {:__block__, _, [_, _]}]}]}, []} =
               Toxic2.parse_to_ast("fn x -> y = x\n y end")
    end

    test "a trailing keyword run in the head groups into one keyword-list arg" do
      assert {{:fn, _, [{:->, _, [[{:x, _, nil}, [a: 1]], {:y, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("fn x, a: 1 -> y end")

      assert {{:fn, _, [{:->, _, [[[a: 1, b: 2]], {:y, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("fn a: 1, b: 2 -> y end")
    end

    test "a parenthesised arg list is a stab head (`(a, b) ->`)" do
      assert {{:fn, _, [{:->, _, [[{:a, _, nil}, {:b, _, nil}], {:c, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("fn (a, b) -> c end")
    end

    test "a clause head takes a keyword-list guard and quoted keyword keys" do
      assert {{:fn, _, [{:->, _, [[{:when, _, [{:a, _, nil}, [foo: 1]]}], {:x, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("fn (a) when foo: 1 -> x end")

      assert {[{:->, _, [[[a: 1]], {:foo, _, []}]}], [_charlist_warning]} =
               Toxic2.parse_to_ast("(('a': 1) -> foo())")
    end

    test "stab clauses inside parens lower to the bare clause list" do
      assert {[{:->, _, [[{:x, _, nil}], {:y, _, nil}]}], []} = Toxic2.parse_to_ast("(x -> y)")

      assert {[{:->, _, [[{:a, _, nil}, {:b, _, nil}], {:c, _, nil}]}], []} =
               Toxic2.parse_to_ast("(a, b -> c)")

      assert {[{:->, _, [[{:a, _, nil}], _]}, {:->, _, [[{:c, _, nil}], _]}], []} =
               Toxic2.parse_to_ast("(a -> b; c -> d)")

      # a paren-wrapped arg list with a keyword pair, and a `when` guard
      assert {[{:->, _, [[{:when, _, [{:x, _, nil}, [a: 1], {:g, _, []}]}], {:y, _, nil}]}], []} =
               Toxic2.parse_to_ast("((x, a: 1) when g() -> y)")
    end

    test "fn missing end is tolerant" do
      {_v, _es, diags} = exprs("fn x -> x")
      assert Enum.any?(diags, &(elem(&1, 3) == :expected_end))
    end

    test "fn is a valid no-parens argument (resolve fn ... end)" do
      assert {{:resolve, _, [{:fn, _, [{:->, _, [[{:x, _, nil}], {:x, _, nil}]}]}]}, []} =
               Toxic2.parse_to_ast("resolve fn x -> x end")

      assert {{{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, [{:x, _, nil}, {:fn, _, _}]}, []} =
               Toxic2.parse_to_ast("Enum.map x, fn i -> i end")
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

      assert {[97, 98, 99], [_charlist_warning]} = Toxic2.parse_to_ast("'abc'")
      assert {[], [_charlist_warning]} = Toxic2.parse_to_ast("''")

      {ast, [_charlist_warning]} = Toxic2.parse_to_ast("'a\#{b}c'")

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
      assert {~c"a\nb", [_charlist_warning]} = Toxic2.parse_to_ast("'a\nb'")
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

  describe "empty bodies / step range" do
    test "an empty do-body lowers to an empty block, not nil" do
      assert {{:foo, _, [[do: {:__block__, _, []}]]}, []} = Toxic2.parse_to_ast("foo do end")

      assert {{:if, _, [true, [do: {:__block__, _, []}]]}, []} =
               Toxic2.parse_to_ast("if true do\nend")
    end

    test "fn with empty parens head has zero args" do
      assert {{:fn, _, [{:->, _, [[], :ok]}]}, []} = Toxic2.parse_to_ast("fn () -> :ok end")
    end

    test "a..b//c is the ternary step range (even parenthesised)" do
      assert {{:..//, _, [1, 10, 2]}, []} = Toxic2.parse_to_ast("1..10//2")
      assert {{:..//, _, [1, 10, {:+, _, [2, 3]}]}, []} = Toxic2.parse_to_ast("1..10//2 + 3")
      assert {{:..//, _, [1, 10, 2]}, []} = Toxic2.parse_to_ast("(1..10)//2")
    end

    test "// is ONLY the range step — a non-range // is an error (not a generic operator)" do
      for src <- ["a // b", "a..b//c//d", "a..(b // c)"] do
        {_ast, diags} = Toxic2.parse_to_ast(src)

        assert Enum.any?(diags, &(elem(&1, 2) == :error and elem(&1, 3) == :misplaced_step_op)),
               src
      end
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

  describe "struct base / @ precedence / no-parens string args" do
    test "struct base may be any primary, not just an alias" do
      assert {{:%, _, [{:mod, _, nil}, {:%{}, _, [a: 1]}]}, []} =
               Toxic2.parse_to_ast("%mod{a: 1}")

      assert {{:%, _, [nil, {:%{}, _, []}]}, []} = Toxic2.parse_to_ast("%nil{}")
    end

    test "@ binds tighter than dot/access: @x.y == (@x).y" do
      assert {{{:., _, [{:@, _, [{:foo, _, nil}]}, :bar]}, _, []}, []} =
               Toxic2.parse_to_ast("@foo.bar")

      # ...but @ still takes a no-parens operand
      assert {{:@, _, [{:moduledoc, _, [false]}]}, []} = Toxic2.parse_to_ast("@moduledoc false")
    end

    test "no-parens calls accept string / sigil arguments" do
      assert {{:@, _, [{:doc, _, ["x"]}]}, []} = Toxic2.parse_to_ast("@doc \"x\"")

      assert {{{:., _, [{:__aliases__, _, [:IO]}, :puts]}, _, ["hello"]}, []} =
               Toxic2.parse_to_ast("IO.puts \"hello\"")
    end

    test "bitstrings carry trailing keywords after a positional element" do
      assert {{:<<>>, _, [{:foo, _, nil}, [bar: {:baz, _, nil}]]}, []} =
               Toxic2.parse_to_ast("<<foo, bar: baz>>")
    end
  end

  describe "quoted atoms (:\"...\")" do
    test "no interpolation lowers to the atom (escapes processed)" do
      # `a` needs no quotes → an unnecessary-quoted-atom warning
      assert {:a, [_unnecessary]} = Toxic2.parse_to_ast(":\"a\"")
      # single-quoted AND unnecessary: both the deprecation and the unnecessary-quote note
      assert {:a, [_deprecated, _unnecessary]} = Toxic2.parse_to_ast(":'a'")
      # `"a b"` / `""` genuinely need quotes → no warning
      assert {:"a b", []} = Toxic2.parse_to_ast(":\"a b\"")
      assert {:"", []} = Toxic2.parse_to_ast(":\"\"")
    end

    test "interpolation lowers to :erlang.binary_to_atom(<<...>>, :utf8)" do
      {ast, []} = Toxic2.parse_to_ast(":\"a\#{x}b\"")

      assert {{:., _, [:erlang, :binary_to_atom]}, _,
              [{:<<>>, _, ["a", {:"::", _, _}, "b"]}, :utf8]} = ast
    end
  end

  describe "keyword positions (newline after key:, tuple/access keywords)" do
    test "a newline is allowed after `key:` before the value" do
      assert {[a: 1], []} = Toxic2.parse_to_ast("[a:\n1]")
      assert {{:f, _, [[a: 1]]}, []} = Toxic2.parse_to_ast("f(a:\n1)")
      assert {{:%{}, _, [a: 1, b: 2]}, []} = Toxic2.parse_to_ast("%{a:\n1,\nb: 2}")
    end

    test "tuples carry trailing keywords after a positional element" do
      assert {{1, [a: 1]}, []} = Toxic2.parse_to_ast("{1, a: 1}")
      assert {{:{}, _, [1, 2, [a: 1]]}, []} = Toxic2.parse_to_ast("{1, 2, a: 1}")
      # but an all-keyword tuple is rejected (tolerantly)
      {_ast, diags} = Toxic2.parse_to_ast("{a: 1}")
      assert Enum.any?(diags, &(elem(&1, 2) == :error))
    end

    test "access takes a keyword-list index" do
      assert {{{:., _, [Access, :get]}, _, [{:foo, _, nil}, [a: 1, b: 2]]}, []} =
               Toxic2.parse_to_ast("foo[a: 1, b: 2]")
    end
  end

  describe "dot-tuple multi-alias (Foo.{A, B})" do
    test "lowers to {{:., _, [base, :{}]}, _, [elems]}" do
      assert {{{:., _, [{:__aliases__, _, [:Foo]}, :{}]}, _,
               [{:__aliases__, _, [:A]}, {:__aliases__, _, [:B]}]}, []} =
               Toxic2.parse_to_ast("Foo.{A, B}")

      assert {{{:., _, [{:__aliases__, _, [:Foo, :Bar]}, :{}]}, _, [{:__aliases__, _, [:Baz]}]},
              []} =
               Toxic2.parse_to_ast("Foo.Bar.{Baz}")

      assert {{{:., _, [{:__aliases__, _, [:Foo]}, :{}]}, _, []}, []} =
               Toxic2.parse_to_ast("Foo.{}")
    end

    test "works as the argument of `alias`" do
      assert {:alias, _, [{{:., _, [{:__aliases__, _, [:Foo]}, :{}]}, _, _}]} =
               elem(Toxic2.parse_to_ast("alias Foo.{Bar, Baz}"), 0)
    end
  end

  describe "membership negation (not/! left of in)" do
    test "`!a in b` rewrites to !(a in b), like `not a in b`" do
      assert {{:!, _, [{:in, _, [{:a, _, nil}, {:b, _, nil}]}]}, _} =
               Toxic2.parse_to_ast("!a in b")

      assert {{:not, _, [{:in, _, [{:a, _, nil}, {:b, _, nil}]}]}, _} =
               Toxic2.parse_to_ast("not a in b")
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

    test "a do-block attaches to an anonymous call (`f.() do … end`)" do
      assert {{{:., _, [{:foo, _, nil}]}, _, [[do: :ok]]}, []} =
               Toxic2.parse_to_ast("foo.() do :ok end")
    end

    test "a `do` block after a `when` guard attaches to the call, not the guard operand" do
      assert {{:def, _, [{:when, _, [{:foo, _, [{:x, _, nil}]}, {:>, _, _}]}, [do: _]]}, []} =
               Toxic2.parse_to_ast("def foo(x) when x > 0 do x end")
    end

    test "a clause head may span lines (pattern, then `when guard ->`)" do
      assert {{:case, _, [{:x, _, nil}, [do: [{:->, _, [[{:when, _, _}], :ok]}]]]}, []} =
               Toxic2.parse_to_ast("case x do\n%{a: y}\nwhen y > 0 -> :ok\nend")
    end

    test "a sole `unquote_splicing` statement in a block is wrapped in a `__block__`" do
      assert {{:__block__, _, [{:unquote_splicing, _, [{:x, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("(unquote_splicing(x))")
    end

    test "`@attr(args)` includes an adjacent paren call in the `@` operand" do
      assert {{:@, _, [{:callback, _, [{:spec, _, nil}]}]}, []} =
               Toxic2.parse_to_ast("@callback(spec)")
    end

    test "a parenthesised boolean negation is wrapped in a `__block__`" do
      assert {{:__block__, _, [{:not, _, [{:x, _, nil}]}]}, []} = Toxic2.parse_to_ast("(not x)")
      assert {{:__block__, _, [{:!, _, [{:x, _, nil}]}]}, []} = Toxic2.parse_to_ast("(! x)")
      # `-`/binary are not wrapped
      assert {{:-, _, [{:x, _, nil}]}, []} = Toxic2.parse_to_ast("(- x)")
    end

    test "a `not in` guard's `do` block attaches to the enclosing call" do
      assert {{:def, _, [{:when, _, [_, {:not, _, _}]}, [do: :ok]]}, []} =
               Toxic2.parse_to_ast("def f(h) when h not in @x do :ok end")
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
