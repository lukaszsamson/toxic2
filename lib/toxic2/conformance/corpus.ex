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
    {"0x", [:recovery]}
  ]

  @spec valid() :: [entry()]
  def valid, do: Enum.map(@valid, fn {s, t} -> %{source: s, tags: t} end)

  @spec invalid() :: [entry()]
  def invalid, do: Enum.map(@invalid, fn {s, t} -> %{source: s, tags: t} end)

  @spec all() :: [entry()]
  def all, do: Enum.concat(valid(), invalid())
end
