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
    # keyword-last / trailing-comma / update / kw-in-tuple violations (oracle rejects)
    {"f(1,)", [:recovery]},
    {"f(a: 1, 2)", [:keyword]},
    {"f(1, a: 2, 3)", [:keyword]},
    {"[a: 1, 2]", [:keyword]},
    {"[1, a: 2, 3]", [:keyword]},
    {"%{a: 1, b => 2}", [:keyword]},
    {"%{m |}", [:map]},
    {"%Foo{m |}", [:struct]},
    {"{a: 1}", [:keyword]}
  ]

  @spec valid() :: [entry()]
  def valid, do: Enum.map(@valid, fn {s, t} -> %{source: s, tags: t} end)

  @spec invalid() :: [entry()]
  def invalid, do: Enum.map(@invalid, fn {s, t} -> %{source: s, tags: t} end)

  @spec all() :: [entry()]
  def all, do: Enum.concat(valid(), invalid())
end
