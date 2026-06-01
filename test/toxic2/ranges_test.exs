defmodule Toxic2.RangesTest do
  use ExUnit.Case, async: true

  # Source ranges (opt-in via `range: true`). Every AST node that corresponds to source carries
  # `range: {{start_line, start_col}, {end_line, end_col}}` (end exclusive — one past the last char,
  # matching the CST span / spitfire convention). The range is the node's full extent, distinct from
  # the `line:`/`column:` anchor (which Elixir places on the operator for infix ops). Two guarantees:
  #   1. exact ranges on grammar primitives (below), and
  #   2. the structural invariant: a parent's range CONTAINS every descendant's range.

  defp ast(src) do
    {ast, diags} = Toxic2.parse_to_ast(src, range: true)
    refute Enum.any?(diags, &(elem(&1, 2) == :error)), "unexpected error diagnostics for #{src}"
    ast
  end

  defp range(node) when is_tuple(node) and tuple_size(node) == 3 do
    {_f, meta, _a} = node
    if is_list(meta), do: Keyword.get(meta, :range)
  end

  defp range(_), do: nil

  describe "grammar primitives carry exact ranges" do
    test "a bare variable" do
      assert range(ast("foo")) == {{1, 1}, {1, 4}}
    end

    test "a binary operator spans both operands, anchored on the operator" do
      {:+, meta, [l, _r]} = ast("ab + c")
      assert Keyword.get(meta, :range) == {{1, 1}, {1, 7}}
      assert Keyword.get(meta, :column) == 4
      assert range(l) == {{1, 1}, {1, 3}}
    end

    test "precedence: outer op range covers the nested op" do
      {:+, pmeta, [_one, {:*, mmeta, _}]} = ast("1 + 2 * 3")
      assert Keyword.get(pmeta, :range) == {{1, 1}, {1, 10}}
      assert Keyword.get(mmeta, :range) == {{1, 5}, {1, 10}}
    end

    test "a paren call spans through the closing paren" do
      assert range(ast("foo(a, b)")) == {{1, 1}, {1, 10}}
    end

    test "a no-parens call spans through the last argument" do
      assert range(ast("foo bar")) == {{1, 1}, {1, 8}}
    end

    test "a map literal spans its braces" do
      assert range(ast("%{a: 1}")) == {{1, 1}, {1, 8}}
    end

    test "a do/end block spans through end" do
      assert range(ast("if x do y end")) == {{1, 1}, {1, 14}}
    end

    test "a multi-line node ranges across lines" do
      {:if, meta, _} = ast("if x do\n  y\nend")
      assert Keyword.get(meta, :range) == {{1, 1}, {3, 4}}
    end

    test "a qualified call ranges over the whole chain" do
      assert range(ast("a.b.c")) == {{1, 1}, {1, 6}}
    end
  end

  describe "the parent-contains-children invariant" do
    @corpus [
      "foo",
      "1 + 2 * 3 - 4 / 5",
      "foo(a, b, c)",
      "foo bar, baz",
      "a.b.c.d(1).e",
      "if x do\n  y\n  z\nelse\n  w\nend",
      "case v do\n  {:ok, x} when is_list(x) -> x\n  _ -> nil\nend",
      "with {:ok, a} <- f(),\n     {:ok, b} <- g(a) do\n  a + b\nend",
      "%{a: 1, b: foo(c)}",
      "%Foo{bar | x: y}",
      "[1, foo(2), {a, b}]",
      "fn x, y -> x + y end",
      "def f(a, b \\\\ 1) when a > 0 do\n  a * b\nend",
      "x = y = foo(1, 2) + bar",
      "for i <- 1..10, j <- 1..i, do: {i, j}",
      "<<len::32, body::binary-size(len)>>",
      "quote do\n  unquote(a) + unquote(b)\nend",
      "a |> b() |> c(1) |> d()",
      "@spec f(integer) :: {:ok, term} | :error",
      "receive do\n  {:msg, m} -> handle(m)\nafter\n  100 -> :timeout\nend"
    ]

    defp leq?({l1, c1}, {l2, c2}), do: l1 < l2 or (l1 == l2 and c1 <= c2)
    defp contains?({ps, pe}, {cs, ce}), do: leq?(ps, cs) and leq?(ce, pe)

    # Walk the AST; whenever a node has a range, every descendant range must sit inside it.
    defp violations(node, enclosing) do
      case node do
        {form, meta, args} when is_list(meta) ->
          r = Keyword.get(meta, :range)

          here =
            if enclosing && r && not contains?(enclosing, r),
              do: [{:escapes, enclosing, r}],
              else: []

          inner = r || enclosing

          here ++
            violations(form, inner) ++ Enum.flat_map(List.wrap(args), &violations(&1, inner))

        {a, b} ->
          violations(a, enclosing) ++ violations(b, enclosing)

        list when is_list(list) ->
          Enum.flat_map(list, &violations(&1, enclosing))

        _ ->
          []
      end
    end

    test "every descendant range is contained by its enclosing node's range" do
      bad =
        Enum.flat_map(@corpus, fn src ->
          case violations(ast(src), nil) do
            [] -> []
            v -> [{src, v}]
          end
        end)

      assert bad == [],
             "range containment violations:\n" <>
               Enum.map_join(bad, "\n", fn {src, v} -> "  #{inspect(src)}: #{inspect(v)}" end)
    end
  end

  describe "ranges are opt-in" do
    test "default lowering carries no :range key" do
      {{:+, meta, _}, _} = Toxic2.parse_to_ast("1 + 2")
      refute Keyword.has_key?(meta, :range)
    end
  end

  describe "literal_encoder (Elixir-compatible) gives bare literals ranges too" do
    defp block_encoder, do: fn v, m -> {:ok, {:__block__, m, [v]}} end

    defp enc_ast(src) do
      {ast, diags} = Toxic2.parse_to_ast(src, literal_encoder: block_encoder(), range: true)
      refute Enum.any?(diags, &(elem(&1, 2) == :error)), "unexpected errors for #{src}"
      ast
    end

    test "scalar literals are wrapped and carry a range" do
      assert {:__block__, m, [123]} = enc_ast("123")
      assert Keyword.get(m, :range) == {{1, 1}, {1, 4}}
      assert {:__block__, am, [:foo]} = enc_ast(":foo")
      assert Keyword.get(am, :range) == {{1, 1}, {1, 5}}
      assert {:__block__, sm, ["hi"]} = enc_ast(~S("hi"))
      assert Keyword.get(sm, :range) == {{1, 1}, {1, 5}}
    end

    test "a list literal wraps the list and every element, each with a range" do
      assert {:__block__, lm, [[{:__block__, em1, [1]}, {:__block__, em2, [2]}]]} =
               enc_ast("[1, 2]")

      assert Keyword.get(lm, :range) == {{1, 1}, {1, 7}}
      assert Keyword.get(em1, :range) == {{1, 2}, {1, 3}}
      assert Keyword.get(em2, :range) == {{1, 5}, {1, 6}}
    end

    test "keyword shorthand expands to explicit encoded pairs" do
      assert {:%{}, _, [{{:__block__, km, [:a]}, {:__block__, _, [1]}}]} = enc_ast("%{a: 1}")
      assert Keyword.get(km, :format) == :keyword
      assert Keyword.get(km, :range) == {{1, 3}, {1, 5}}
    end

    test "default lowering (no encoder) leaves literals bare" do
      assert {123, _} = Toxic2.parse_to_ast("123")
      assert {[1, 2], _} = Toxic2.parse_to_ast("[1, 2]")
    end

    test "an error-returning encoder yields a diagnostic, never a crash" do
      {_ast, diags} = Toxic2.parse_to_ast("123", literal_encoder: fn _v, _m -> {:error, :no} end)
      assert Enum.any?(diags, &(elem(&1, 2) == :error))
    end

    test "containment invariant holds with literals encoded (every node now ranged)" do
      bad =
        Enum.flat_map(@corpus, fn src ->
          case violations(enc_ast(src), nil) do
            [] -> []
            v -> [{src, v}]
          end
        end)

      assert bad == []
    end
  end
end
