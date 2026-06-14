defmodule Toxic2.SemanticTokensTest do
  use ExUnit.Case, async: true

  alias Toxic2.SemanticTokens

  # {type, text} pairs for the single line `src`, in source order — the slice each span covers.
  defp marks(src) do
    line = src |> String.split("\n") |> List.first()

    for {sl, sc, _el, ec, type, _mods} <- SemanticTokens.tokens(src), sl == 1 do
      {type, String.slice(line, sc - 1, ec - sc)}
    end
  end

  defp full(src), do: SemanticTokens.tokens(src)

  describe "lexical defaults" do
    test "atoms, numbers, keyword keys, captures, sigil heads" do
      assert {:atom, ":ok"} in marks(":ok")
      assert {:number, "42"} in marks("42")
      assert {:number, "3.14"} in marks("3.14")
      assert {:property, "key"} in marks("[key: 1]")
      assert {:capture, "&1"} in marks("&1")
      assert {:sigil, "~r"} in marks("~r/ab/")
    end

    test "keyword key span excludes the trailing colon" do
      assert [{:property, "foo"} | _] = marks("foo: 1")
    end
  end

  describe "calls vs variables" do
    test "local call callee is function, bare identifier is variable" do
      assert {:function, "foo"} in marks("foo(1)")
      assert {:variable, "x"} in marks("x + 1")
    end

    test "remote member is method with a call shape, property otherwise" do
      assert {:method, "bar"} in marks("Foo.bar(1)")
      assert {:method, "map"} in marks("Enum.map(l, f)")
      assert {:property, "assigns"} in marks("conn.assigns")
    end
  end

  describe "the control/def stop-list (must NOT become function or variable)" do
    test "control forms are left to TextMate (not emitted)" do
      for kw <- ~w(if unless case cond for with) do
        types = full("#{kw} x do 1 end") |> Enum.map(&elem(&1, 4))
        refute :function in types
        # the keyword itself is never emitted as a variable
        kw_marks = marks("#{kw} x do 1 end") |> Enum.filter(fn {_t, txt} -> txt == kw end)
        assert kw_marks == []
      end
    end

    test "def/defp/defmacro names are definitions, the keyword is not emitted" do
      assert {:function, "foo"} in marks("def foo(x), do: x")
      assert {:function, "foo"} in marks("defp foo(x), do: x")
      assert {:macro, "m"} in marks("defmacro m(x), do: x")
      refute Enum.any?(marks("def foo(x), do: x"), fn {_t, txt} -> txt == "def" end)
    end

    test "def target carries the :definition modifier" do
      assert Enum.any?(full("def foo(x), do: x"), fn {_, _, _, _, t, m} ->
               t == :function and :definition in m
             end)
    end

    test "guarded heads keep the definition role (def/defp/defmacro/defguard)" do
      assert {:function, "foo"} in marks("def foo(x) when is_atom(x), do: x")
      assert {:function, "foo"} in marks("defp foo(x) when is_atom(x), do: x")
      assert {:macro, "m"} in marks("defmacro m(x) when is_atom(x), do: x")
      assert {:function, "is_foo"} in marks("defguard is_foo(x) when is_atom(x)")
      assert {:function, "is_foo"} in marks("defguardp is_foo(x) when is_atom(x)")

      assert Enum.any?(full("def foo(x) when is_atom(x), do: x"), fn {_, _, _, _, t, m} ->
               t == :function and :definition in m
             end)
    end
  end

  describe "control/block option keys are left to TextMate" do
    test "inline do:/else: option keys are not emitted as property" do
      m = marks("if x, do: y, else: z")
      refute {:property, "do"} in m
      refute {:property, "else"} in m
      # the key is skipped entirely, not relabelled
      refute Enum.any?(m, fn {_t, txt} -> txt in ["do", "else"] end)
    end

    test "def foo, do: :ok — the do: option key is skipped" do
      refute {:property, "do"} in marks("def foo, do: :ok")
    end

    test "but a literal keyword list `[do: 1]` keeps property" do
      assert {:property, "do"} in marks("[do: 1]")
    end

    test "ordinary keyword keys are still property" do
      assert {:property, "key"} in marks("[key: 1]")
      assert {:property, "name"} in marks("foo(name: 1)")
    end
  end

  describe "modules" do
    test "alias chain: prefix segments namespace, final class" do
      assert marks("Foo.Bar.Baz") == [
               {:namespace, "Foo"},
               {:namespace, "Bar"},
               {:class, "Baz"}
             ]
    end

    test "defmodule target is class + definition" do
      assert Enum.any?(full("defmodule My.App do end"), fn {_, _, _, _, t, m} ->
               t == :class and :definition in m
             end)
    end
  end

  describe "attributes and typespecs" do
    test "doc attributes carry the documentation modifier" do
      assert Enum.any?(full(~s(@moduledoc "x")), fn {_, _, _, _, t, m} ->
               t == :attribute and :documentation in m
             end)
    end

    test "@spec function name is typespec, @type name is type" do
      assert {:typespec, "foo"} in marks("@spec foo() :: t")
      assert {:type, "t"} in marks("@type t :: integer")
    end

    test "plain attribute name is an attribute" do
      assert {:attribute, "my_attr"} in marks("@my_attr 1")
    end

    test "the `@` is part of the attribute token (colors as one unit with the name)" do
      m = marks("@my_attr 1")
      assert {:attribute, "@"} in m
      assert {:attribute, "my_attr"} in m
    end

    test "the `@` of a doc attribute carries the documentation modifier too" do
      assert Enum.any?(full(~s(@moduledoc "x")), fn {_, sc, _, _, t, mods} ->
               t == :attribute and :documentation in mods and sc == 1
             end)
    end

    test "for @spec/@type the `@` and the attr word are attribute; the subject is typespec/type" do
      assert {:attribute, "@"} in marks("@spec foo() :: t")
      assert {:attribute, "spec"} in marks("@spec foo() :: t")
      assert {:typespec, "foo"} in marks("@spec foo() :: t")
      assert {:attribute, "@"} in marks("@type t :: integer")
      assert {:type, "t"} in marks("@type t :: integer")
    end
  end

  describe "captures" do
    test "&fun/arity name is a capture" do
      assert {:capture, "baz"} in marks("&baz/1")
    end
  end

  describe "the variable gate (mid-edit safety)" do
    test "identifiers in a clean statement become variables" do
      assert {:variable, "x"} in marks("x = 1")
    end

    test "an error in the statement suppresses variable highlighting" do
      # `x = ` is an incomplete assignment (error subtree) — `x` must not be emitted as variable.
      refute {:variable, "x"} in marks("x = ")
      refute {:variable, "foo"} in marks("foo(")
    end
  end

  describe "totality and invariants" do
    test "never raises on malformed input" do
      for src <- ["", "(((", "@", "def", "~", "%{", "fn ->", "\"unterminated"] do
        assert is_list(SemanticTokens.tokens(src))
      end
    end

    test "every emitted span is single-line and spans are ordered, non-overlapping" do
      src = """
      defmodule M do
        @doc "d"
        def f(a), do: Enum.map(a, &g/1)
      end
      """

      spans = SemanticTokens.tokens(src)

      assert Enum.all?(spans, fn {sl, _sc, el, _ec, _t, _m} -> sl == el end)

      coords = Enum.map(spans, fn {sl, sc, _el, ec, _t, _m} -> {sl, sc, ec} end)

      assert coords ==
               Enum.sort(coords),
             "spans must be in source order"

      coords
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{l1, _s1, e1}, {l2, s2, _e2}] ->
        assert l1 < l2 or e1 <= s2, "spans must not overlap"
      end)
    end
  end
end
