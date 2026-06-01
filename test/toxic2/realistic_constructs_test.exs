defmodule Toxic2.RealisticConstructsTest do
  use ExUnit.Case, async: true

  # A broad sweep of REAL-WORLD Elixir constructs — the kind that actually appear in production
  # code (as opposed to the adversarial fuzzer programs in the imported backlog corpora). Each
  # source must lower to an AST byte-identical (after meta-stripping) to the live oracle, with NO
  # `:error` diagnostics. This pins the "toxic2 handles all validish code" guarantee against
  # regression — it was established empirically (a 34k-file home scan + the OSS corpus all matched);
  # this is the curated, fast subset that runs in CI.
  #
  # If you add a construct here and it fails, that's a genuine grammar gap to fix — start here.

  @constructs [
    # bitstrings / binary specifiers
    "<<x::size(8)-unit(1)>>",
    "<<x::integer-signed-little>>",
    "<<len::32, body::binary-size(len)>>",
    "<<r::8, g::8, b::8>>",
    "<<x::float-size(64)>>",
    "<<x::big-integer-size(16)>>",
    "<<a, b::binary>> = data",
    "<<>> = bin",
    "<<1, 2, 3>> <> rest",
    # captures
    "&Mod.fun/2",
    "&(&1 + &2)",
    "&foo/1",
    "& &1",
    "&match?({:ok, _}, &1)",
    "&{&1, &2, &3}",
    "Enum.map(list, & &1.field)",
    "&Kernel.+/2",
    # operators as names / qualified
    "Kernel.+(1, 2)",
    "Kernel.++(a, b)",
    "a.b.c.d",
    "foo.bar.baz(1).qux",
    "Foo.\"bar\"()",
    "foo.\"bar baz\"(1)",
    # ranges
    "1..10//2",
    "lo..hi//step",
    "x in 1..10",
    "for i <- 1..10//2, do: i",
    # structs / maps
    "%Foo{bar | a: 1}",
    "%{m | a: 1, b: 2}",
    "%{\"key\" => val, atom: 1}",
    "%{^key => val}",
    "%{1 => :a, :b => 2, c: 3}",
    "defstruct [:a, :b, c: 1]",
    "@enforce_keys [:a]",
    "defp do_it(%__MODULE__{} = s), do: s",
    # comprehensions
    "for x <- a, y <- b, x > 0, into: %{}, do: {x, y}",
    "for x <- a, reduce: 0 do\n  acc -> acc + x\nend",
    "for <<byte <- bin>>, do: byte",
    "for <<r::8, g::8, b::8 <- pixels>>, do: {r, g, b}",
    # with / try / receive / cond
    "with {:ok, a} <- f(),\n     {:ok, b} <- g(a) do\n  {a, b}\nelse\n  {:error, e} -> e\nend",
    "try do\n  f()\nrescue\n  e in [A, B] -> e\ncatch\n  :exit, r -> r\nelse\n  v -> v\nafter\n  cleanup()\nend",
    "receive do\n  {:msg, m} -> m\nafter\n  timeout() -> :timeout\nend",
    "cond do\n  a -> 1\n  b -> 2\n  true -> 3\nend",
    # anonymous fns
    "fn\n  0 -> :zero\n  n when n > 0 and is_integer(n) -> :pos\n  _ -> :other\nend",
    "fn () -> 1 end",
    "fn {a, b}, [c | d] -> a end",
    "(fn -> 1 end).()",
    "f.(1, 2)",
    # typespecs / attributes
    "@type t(a) :: {a, list(a)}",
    "@opaque q :: %{required(atom) => term}",
    "@callback foo(integer) :: {:ok, term} | :error",
    "@spec f() :: :ok when var: term",
    "@spec f(a :: integer) :: boolean",
    "@derive {Jason.Encoder, only: [:a]}",
    # defs / guards / defaults
    "def f(a, b \\\\ 1, c \\\\ 2), do: a",
    "def f(x) when x in [1, 2, 3], do: x",
    "defp f(%{a: a} = m, [h | t]), do: {a, h, t}",
    "defmacro x do\n  quote do: unquote(y)\nend",
    "def unquote(name)(arg), do: arg",
    # directives
    "alias A.{B, C}",
    "import Foo, only: [f: 1]",
    "import Foo, except: [bar: 1]",
    "use GenServer, restart: :temporary",
    "@behaviour GenServer",
    "@impl true",
    "defoverridable foo: 1",
    # strings / sigils / heredocs
    "~s\"\"\"\nhi \#{x} bye\n\"\"\"",
    "'''\nchars\n'''",
    "~S(no \#{interp})",
    "x = \"a\#{b}c\#{d}e\"",
    "\"\#{\"nested \#{x}\"}\"",
    "~r/(?<name>\\w+)/iu",
    "~D[2020-01-01]",
    "~w[a b c]a",
    # misc real idioms
    "x = y || raise(\"err\")",
    "a |>\n  b() |>\n  c()",
    "not (a and b)",
    "x not in [1, 2]",
    "\"prefix\" <> rest = s",
    "send(pid, {:msg, data})",
    "x = [a: 1] ++ [b: 2]"
  ]

  # `Conformance.evaluate/1` is the single sanctioned oracle path (it owns the
  # `Code.string_to_quoted` comparison + normalization); `:pass` = AST matches AND no `:error`
  # diagnostics. Routing through it keeps the reward-hack guard happy.
  test "every realistic construct conforms to the oracle (`:pass`)" do
    failures =
      for src <- @constructs,
          result = Mix.Tasks.Toxic2.Conformance.evaluate(src),
          result != :pass,
          do: {src, result}

    assert failures == [],
           "realistic-construct gaps:\n" <>
             Enum.map_join(failures, "\n", fn {src, result} ->
               "  #{inspect(src)} -> #{inspect(result)}"
             end)
  end
end
