defmodule Toxic2.Conformance.Corpus do
  @moduledoc """
  Curated conformance corpus (see `TOXIC_2.md` → Agent Development Harness).

  Pure data — no oracle calls (those live in the guard-exempt mix task). Each entry is
  `%{source: String.t(), tags: [atom()]}`. The corpus tracks the **currently supported grammar**
  (phase 5/6: literals, names, operators, parens, layout) and grows as later phases add grammar.
  Tags are the harness buckets so an agent can work one construct at a time.

  Valid entries assert AST equality vs the oracle; invalid entries (oracle rejects) assert the
  tolerant invariants (no crash, an `:error` diagnostic).
  """

  @type entry :: %{source: String.t(), tags: [atom()]}

  @valid [
    # literals
    {"42", [:literal]},
    {"1_000_000", [:literal]},
    {"0xFF", [:literal]},
    {"3.14", [:literal]},
    {"1.0e10", [:literal]},
    {"?a", [:literal]},
    # strings (phase 10 slice 1: no interpolation)
    {~S("abc"), [:string]},
    {~S(""), [:string]},
    {~S("hello world"), [:string]},
    {~S("a\nb"), [:string]},
    {~S("a\tb\\c\""), [:string]},
    {~S(["a", "b"]), [:string]},
    {"foo(\"x\")", [:string]},
    {~S("a" <> "b"), [:string]},
    # interpolation
    {"\"a\#{b}c\"", [:interpolation]},
    {"\"\#{x}\"", [:interpolation]},
    {"\"\#{1 + 2}\"", [:interpolation]},
    {"\"pre\#{a}mid\#{b}post\"", [:interpolation]},
    {"\"\#{a; b}\"", [:interpolation]},
    {"\"\#{}\"", [:interpolation]},
    {"\"x\#{ %{a: 1} }y\"", [:interpolation]},
    {"\"\#{f(a, b)}\"", [:interpolation]},
    {"\"\#{ \"i\#{j}k\" }\"", [:interpolation]},
    {"\"\#{if x do y else z end}\"", [:interpolation]},
    {"[\"\#{a}\", \"\#{b}\"]", [:interpolation]},
    {":foo", [:literal]},
    {"true", [:literal]},
    {"false", [:literal]},
    {"nil", [:literal]},
    # names
    {"foo", [:identifier]},
    {"foo?", [:identifier]},
    {"Foo", [:alias]},
    # operators
    {"1 + 2", [:operator]},
    {"1 + 2 * 3", [:operator]},
    {"1 * 2 + 3", [:operator]},
    {"1 - 2 - 3", [:operator]},
    {"2 ** 3 ** 4", [:operator]},
    {"1 ++ 2 ++ 3", [:operator]},
    {"a = b = c", [:operator]},
    {"a and b or c", [:operator]},
    {"a == b", [:operator]},
    {"a <= b", [:operator]},
    {"a <> b", [:operator]},
    {"a when b", [:operator]},
    {"a | b", [:operator]},
    {"a :: b", [:operator]},
    {"a <- b", [:operator]},
    {"a in b", [:operator]},
    # prefix
    {"-1", [:operator]},
    {"+1", [:operator]},
    {"-x", [:operator]},
    {"not a", [:operator]},
    {"!a", [:operator]},
    {"@foo", [:operator]},
    {"-1 + 2", [:operator]},
    # parens
    {"(1 + 2) * 3", [:operator]},
    {"(a)", [:operator]},
    # lists
    {"[1, 2, 3]", [:container]},
    {"[]", [:container]},
    {"[1]", [:container]},
    {"[a | b]", [:container]},
    {"[1, 2 | t]", [:container]},
    {"[1 + 2, foo(3)]", [:container]},
    # tuples
    {"{1, 2}", [:container]},
    {"{}", [:container]},
    {"{1}", [:container]},
    {"{1, 2, 3}", [:container]},
    # paren calls
    {"f()", [:call]},
    {"f(1, 2)", [:call]},
    {"foo(bar(1))", [:call]},
    {"foo(1 + 2, 3)", [:call]},
    # dot / remote / anon / alias chains
    {"a.b", [:dot]},
    {"a.b.c", [:dot]},
    {"a.b()", [:dot]},
    {"a.b(1, 2)", [:dot]},
    {"Foo.Bar", [:dot]},
    {"Foo.Bar.Baz", [:dot]},
    {"Foo.bar", [:dot]},
    {"Foo.bar(1, 2)", [:dot]},
    {"foo.Bar", [:dot]},
    {"a.b(1).c", [:dot]},
    {"foo().bar", [:dot]},
    {"a.(1)", [:dot]},
    # keyword lists
    {"[a: 1, b: 2]", [:keyword]},
    {"[1, a: 2]", [:keyword]},
    {"[do: 1]", [:keyword]},
    {"f(a: 1)", [:keyword]},
    {"f(1, a: 2)", [:keyword]},
    {"f(x, y, a: 1, b: 2)", [:keyword]},
    # maps
    {"%{a => b}", [:map]},
    {"%{}", [:map]},
    {"%{a => b, c => d}", [:map]},
    {"%{a: 1, b: 2}", [:map]},
    {"%{1 => 2}", [:map]},
    {"%{m | k => v}", [:map]},
    {"%{m | a: 1}", [:map]},
    # structs
    {"%Foo{a: 1}", [:struct]},
    {"%Foo{}", [:struct]},
    {"%Foo{m | a: 1}", [:struct]},
    {"%Foo.Bar{x: 1}", [:struct]},
    {"%__MODULE__{}", [:struct]},
    # bitstrings
    {"<<1, 2>>", [:bitstring]},
    {"<<>>", [:bitstring]},
    {"<<1::8>>", [:bitstring]},
    {"<<x::binary>>", [:bitstring]},
    {"<<1, 2::8>>", [:bitstring]},
    # access
    {"a[b]", [:access]},
    {"a[b][c]", [:access]},
    {"m[:k]", [:access]},
    # permissive edges (valid)
    {"[1,]", [:trailing_comma]},
    {"{1,}", [:trailing_comma]},
    {"<<1,>>", [:trailing_comma]},
    {"[1, 2,]", [:trailing_comma]},
    {"%{a => 1, b: 2}", [:keyword]},
    {"[1, 2, a: 1, b: 2]", [:keyword]},
    {"a\n.b", [:dot]},
    {"a\n.b.c", [:dot]},
    # no-parens calls (phase 8)
    {"f a", [:no_parens]},
    {"f a, b", [:no_parens]},
    {"f a, b, c", [:no_parens]},
    {"foo bar baz", [:no_parens]},
    {"f a + b", [:no_parens]},
    {"f a == b", [:no_parens]},
    {"f -1", [:no_parens]},
    {"f - 1", [:no_parens]},
    {"1 + f a", [:no_parens]},
    {"g f a", [:no_parens]},
    {"f g a, b", [:no_parens]},
    {"x = f a", [:no_parens]},
    {"f a, b: 1", [:no_parens]},
    {"foo a, b: 1, c: 2", [:no_parens]},
    {"not f a", [:no_parens]},
    {"a |> f b", [:no_parens]},
    {"rem 5, 2", [:no_parens]},
    {"[f a]", [:no_parens]},
    {"f(g a, b)", [:no_parens]},
    {"[b, f a]", [:no_parens]},
    {"[a.b c]", [:no_parens]},
    {"a.b c", [:no_parens]},
    {"a.b c, d", [:no_parens]},
    {"Foo.bar a", [:no_parens]},
    {"Foo.bar a, b", [:no_parens]},
    {"x.y z", [:no_parens]},
    {"a.b c.d", [:no_parens]},
    {"a b c d", [:no_parens]},
    {"f a,\n b", [:no_parens]},
    {"f a,\n b: 1", [:no_parens]},
    {"a not in b", [:operator]},
    {"not a in b", [:operator]},
    # fn / stab clauses (phase 9)
    {"fn -> :ok end", [:fn]},
    {"fn x -> x end", [:fn]},
    {"fn x, y -> x + y end", [:fn]},
    {"fn -> end", [:fn]},
    {"fn x when x > 0 -> x end", [:fn]},
    {"fn a -> 1\n b -> 2 end", [:fn]},
    {"fn 1 -> :one\n 2 -> :two end", [:fn]},
    {"f(fn x -> x end)", [:fn]},
    {"fn x -> y = x\n y end", [:fn]},
    # do/end blocks (phase 9)
    {"if x do y end", [:do_block]},
    {"if x do y else z end", [:do_block]},
    {"foo do :ok end", [:do_block]},
    {"foo a, b do x end", [:do_block]},
    {"foo bar do :ok end", [:do_block]},
    {"cond do x -> 1\n true -> 2 end", [:do_block]},
    {"case x do 1 -> :a\n 2 -> :b end", [:do_block]},
    {"receive do msg -> ok end", [:do_block]},
    {"try do x rescue e -> y end", [:do_block]},
    {"try do x after z end", [:do_block]},
    {"if x do\n a\n b\n end", [:do_block]},
    {"1 + if x do y end", [:do_block]},
    # layout
    {"a\nb", [:layout]},
    {"a; b; c", [:layout]},
    {"1 +\n2", [:layout]},
    {"1\n+ 2", [:layout]}
  ]

  # Oracle rejects these; Toxic2 must not crash and must emit an :error diagnostic.
  @invalid [
    {"a => b", [:recovery]},
    {"1 +", [:recovery]},
    {")", [:recovery]},
    {"(1 + 2", [:recovery]},
    {"0x", [:recovery]},
    {"[1, 2", [:recovery]},
    {"f(1, 2", [:recovery]},
    {"{1, ", [:recovery]},
    {"%{a =>", [:recovery]},
    {"<<1, 2", [:recovery]},
    {"a[b", [:recovery]},
    # unterminated string (no crash; emit :error)
    {~S("abc), [:string]},
    {~S("a\n), [:string]},
    # keyword-last / trailing-comma / update / kw-in-tuple violations (oracle rejects)
    {"f(1,)", [:recovery]},
    {"f(a: 1, 2)", [:keyword]},
    {"f(1, a: 2, 3)", [:keyword]},
    {"[a: 1, 2]", [:keyword]},
    {"[1, a: 2, 3]", [:keyword]},
    {"%{a: 1, b => 2}", [:keyword]},
    {"%{m |}", [:map]},
    {"%Foo{m |}", [:struct]},
    {"{a: 1}", [:keyword]},
    # missing `end` / empty fn / leftover tokens in bodies (must not crash; emit diagnostics)
    {"if x do y", [:do_block]},
    {"foo do", [:do_block]},
    {"case x do 1 -> y", [:do_block]},
    {"fn end", [:fn]},
    {"fn -> 1 2 end", [:fn]},
    {"if x do 1 2 end", [:do_block]},
    {"foo do 1 2 end", [:do_block]},
    {"case x do 1 -> 2 3 end", [:do_block]},
    {"cond do true -> 1 2 end", [:do_block]},
    # no-parens call as a non-last container element (oracle rejects; parens required)
    {"[f a, b]", [:no_parens]},
    {"{f a, b}", [:no_parens]},
    {"[f a, g b]", [:no_parens]},
    # leftover same-line tokens (no grammar routine consumed them)
    {"1 2", [:recovery]},
    {"Foo bar", [:recovery]},
    {"Foo.Bar a", [:recovery]},
    {"foo :bar baz", [:recovery]},
    # keyword-last in no-parens calls
    {"f a: 1, b", [:no_parens]},
    {"f a, b: 1, c", [:no_parens]}
  ]

  @spec valid() :: [entry()]
  def valid, do: Enum.map(@valid, fn {s, t} -> %{source: s, tags: t} end)

  @spec invalid() :: [entry()]
  def invalid, do: Enum.map(@invalid, fn {s, t} -> %{source: s, tags: t} end)

  @spec all() :: [entry()]
  def all, do: Enum.concat(valid(), invalid())
end
