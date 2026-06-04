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
    # multiline quoted literals (NOT heredocs — a raw newline is allowed)
    {"\"a\nb\"", [:string]},
    {"'a\nb'", [:charlist]},
    {"\"line1\nline2\nline3\"", [:string]},
    # full escape forms (hex / unicode / line continuation)
    {"\"\\x61\"", [:string]},
    {"\"\\x41\\x42\"", [:string]},
    {"\"\\u0061\"", [:string]},
    {"\"\\u{61}\"", [:string]},
    {"\"a\\\nb\"", [:string]},
    {"'\\x61'", [:charlist]},
    {"\"\"\"\n\\u0061\n\"\"\"", [:heredoc]},
    # & capture: &N capture args, &expr captures, function captures (name/arity)
    {"&1", [:capture]},
    {"&0", [:capture]},
    {"& &1", [:capture]},
    {"&(&1 + &2)", [:capture]},
    {"&foo/1", [:capture]},
    {"&Mod.fun/2", [:capture]},
    {"&:erlang.abs/1", [:capture]},
    {"&foo(&1, &2)", [:capture]},
    {"&[&1, &2]", [:capture]},
    {"&{&1, &2}", [:capture]},
    {"Enum.map(list, &(&1 * 2))", [:capture]},
    {"f(&1)", [:capture]},
    {"&abs/1 |> foo", [:capture]},
    {"&x = y", [:capture]},
    # chained / double-parens calls (Elixir allows at most two groups per base)
    {"foo()()", [:chained_call]},
    {"foo(1)(2)", [:chained_call]},
    {"foo.bar()()", [:chained_call]},
    {"a.()()", [:chained_call]},
    {"foo().bar()()", [:chained_call]},
    {"a.b.c()()", [:chained_call]},
    # dot-tuple multi-alias (the `alias Foo.{Bar, Baz}` form)
    {"Foo.{A, B}", [:dot_tuple]},
    {"Foo.Bar.{Baz, Qux}", [:dot_tuple]},
    {"Foo.{}", [:dot_tuple]},
    {"alias Foo.{Bar, Baz}", [:dot_tuple]},
    {"a.b.{C, D}", [:dot_tuple]},
    {"__MODULE__.{A, B}", [:dot_tuple]},
    # keyword positions: newline after `key:`, tuple trailing keywords, access keyword index
    {"[a:\n1]", [:keyword]},
    {"f(a:\n1)", [:keyword]},
    {"%{a:\n1,\nb: 2}", [:keyword]},
    {"{1, a: 1}", [:keyword]},
    {"{1, a: 1, b: 2}", [:keyword]},
    {"{1, 2, a: 1}", [:keyword]},
    {"foo[a: 1]", [:keyword]},
    {"foo[a: 1, b: 2]", [:keyword]},
    # quoted atoms (with escapes / interpolation)
    {":\"a\"", [:quoted_atom]},
    {":'a'", [:quoted_atom]},
    {":\"\"", [:quoted_atom]},
    {":\"a b\"", [:quoted_atom]},
    {":\"a\\n\"", [:quoted_atom]},
    {":\"a\#{x}b\"", [:quoted_atom]},
    {":\"\#{x}\"", [:quoted_atom]},
    {"foo(:\"bar\")", [:quoted_atom]},
    # unicode identifiers/atoms (vendored Toxic2.String.Tokenizer: NFC + UTS-39 script checks)
    {"café", [:unicode]},
    {"café = 1", [:unicode]},
    {"módulo()", [:unicode]},
    {"αβγ", [:unicode]},
    {"привет", [:unicode]},
    {"naïve_x", [:unicode]},
    {"_αβ", [:unicode]},
    {"café?", [:unicode]},
    {"café_αβ.foo", [:unicode]},
    {"mod.café", [:unicode]},
    {"µ", [:unicode]},
    {":café", [:unicode]},
    {":αβγ", [:unicode]},
    {":Σ", [:unicode]},
    {":café?", [:unicode]},
    {"[café: 1]", [:unicode]},
    {"%{αβ: 1}", [:unicode]},
    {"def café(x), do: x", [:unicode]},
    # `:::` is the atom `:"::"` (leading `:` taking `::` as its operator-name)
    {":::", [:atom]},
    {"[a: :::]", [:atom]},
    # `\`-newline line continuation inside a heredoc (newline dropped; `\"""` still terminates)
    {"\"\"\"\nfoo\\\n\"\"\"", [:heredoc]},
    {"\"\"\"\nfoo\\\nbar\n\"\"\"", [:heredoc]},
    {"\"\"\"\nfoo \#{x}\\\n\"\"\"", [:heredoc]},
    # `\#{` in a raw (sigil) heredoc suppresses interpolation even AFTER a real `#{...}` — the
    # backslash stays literal content (the `~s` macro unescapes later), not a `\` + interpolation.
    {"~s\"\"\"\nreal \#{a} then \\\#{b} done\n\"\"\"", [:heredoc, :sigil]},
    {"~S\"\"\"\nlit \\\#{b}\n\"\"\"", [:heredoc, :sigil]},
    # a sigil name sitting at EOF with no delimiter is dropped wholesale (empty program)
    {"~x", [:sigil]},
    {"~X123", [:sigil]},
    {"1\n~x", [:sigil]},
    # struct with a non-alias base (dynamic struct)
    {"%mod{a: 1}", [:struct]},
    {"%nil{}", [:struct]},
    {"%var{x | a: 1}", [:struct]},
    # `@` (320) binds tighter than dot/access (310): @x.y == (@x).y; still takes no-parens operands
    {"@foo.bar", [:operator]},
    {"@config.value", [:operator]},
    {"@foo[x]", [:operator]},
    {"@moduledoc false", [:operator]},
    {"@spec foo() :: t", [:operator]},
    {"@callback(unquote(spec))", [:operator]},
    {"@foo(x)", [:operator]},
    # no-parens calls with string / sigil / charlist arguments
    {"@doc \"x\"", [:no_parens]},
    {"IO.puts \"hello\"", [:no_parens]},
    {"raise \"msg\"", [:no_parens]},
    {"foo ~w(a b)", [:no_parens]},
    # the rightmost operand of an operator may be a multi-arg no-parens call (no_parens_op_expr)
    {"1 + foo 2, 3", [:no_parens]},
    {"a |> foo 1, 2", [:no_parens]},
    {"1 < foo 2, 3", [:no_parens]},
    {"a = foo 1, 2", [:no_parens]},
    {"1 + if x do :ok end", [:no_parens]},
    # `when` uniquely takes a bare keyword list on the right
    {"x when foo: 1", [:operator]},
    {"x when foo: 1, bar: 2", [:operator]},
    {"x when foo: bar 1, 2", [:operator]},
    {"x when \"foo\": 1", [:operator]},
    # a unary prefix's operand may be a multi-arg no-parens call
    {"@foo 1, 2", [:operator]},
    {"-foo 1, 2", [:operator]},
    {"not bar :a, :b", [:operator]},
    # a unary op whose operand ends in a `do … end` block becomes GREEDY (Elixir's `unary_op_eol
    # expr` for an unmatched operand): it captures the whole trailing operator chain. A MATCHED
    # operand keeps the tight binding (`not a || b` => `(not a) || b`). See [[toxic2-...]].
    {"not quote do x end || b", [:operator, :do_block]},
    {"not a || b", [:operator]},
    {"@foo try do 1 end..1//2", [:operator, :do_block]},
    {"@x..1//2", [:operator]},
    {"+case 1 do 18.0 -> 49.0 end - foo", [:operator, :do_block]},
    # a single leading `;` in a stab body is an empty (nil) first statement
    {"fn -> ;t end", [:do_block]},
    {"fn -> ; end", [:do_block]},
    {"case z do _ -> ;y end", [:do_block]},
    # a clause guard may be a multi-arg no-parens call / keyword list
    {"case x do y when baz a, b -> :ok end", [:do_block]},
    {"case x do y when baz x: 1, y: 2 -> :ok end", [:do_block]},
    # a `do` block after a `when` guard attaches to the enclosing call, not the guard operand
    {"def foo(x) when x > 0 do x end", [:do_block]},
    {"def foo when bar do 1 end", [:do_block]},
    # a clause head may span lines (pattern, then `when guard ->` on the next line)
    {"case x do\n%{a: y}\nwhen y > 0 -> :ok\nend", [:do_block]},
    {"cond do\n(z = f()) &&\ng in h -> :ok\nend", [:do_block]},
    # `not in` guard whose RHS is an `@`-attribute, then a do-block (attaches to the def)
    {"def f(h) when h not in @x do :ok end", [:do_block]},
    # an atom name may contain `@` (`:nonode@nohost`)
    {":nonode@nohost", [:atom]},
    # a parenthesised boolean negation is wrapped in a `__block__`
    {"(not x)", [:operator]},
    {"(! x)", [:operator]},
    {"&(not f(&1))", [:capture]},
    # reserved words are valid remote-call member names
    {"flags.true", [:operator]},
    {"counters.nil", [:operator]},
    {"a.when", [:operator]},
    {"a.do", [:operator]},
    {"a.else", [:operator]},
    {"conn.when(x)", [:operator]},
    # operators are valid remote-call member names
    {"Kernel.+", [:operator]},
    {"foo.++(1, 2)", [:operator]},
    {"foo.<>", [:operator]},
    # operator function references (`op/arity`), bare and captured
    {"+/2", [:operator]},
    {">=/2", [:operator]},
    {"Enum.reduce(l, &+/2)", [:operator]},
    {"max(e, &>=/2, f)", [:operator]},
    # quoted keyword key as an access index
    {"a[\"foo\": 1]", [:keyword]},
    {"foo['asd': 1, b: 1]", [:keyword]},
    # stab-clause lists combined with `|` (typespec function unions)
    {"(-> 1) | (-> 2)", [:stab]},
    {"(:am | :pm -> 1) | (:am, :pm -> 2)", [:stab]},
    # a stab-head pattern may itself be a multi-arg no-parens call
    {"fn x 1, 2, 3 -> foo() end", [:fn]},
    # access takes one index with an optional trailing comma; `...`/operator struct bases
    {"foo[1,]", [:access]},
    {"foo[\n:bar]", [:access]},
    {"foo.() do\n:ok\nend", [:do_block]},
    # a `do` on the next line after a multi-line head (only for a call that already has args)
    {"def f(x) when g\ndo\n:ok\nend", [:do_block]},
    {"with {:ok, a} <- f()\ndo a end", [:do_block]},
    # `\`-newline joins a no-parens callee with its arg (one logical line). Since Elixir 1.20 a
    # SPACE-preceded `\`-newline is horizontal whitespace, so `foo \⏎+1` => `foo(+1)` (like
    # `foo +1`), distinct from the no-space `foo\⏎+1` => `foo + 1` (below, in `:layout`).
    {"@x \\\nFile.foo()", [:no_parens]},
    {"foo \\\nbar", [:no_parens]},
    {"foo \\\n+1", [:no_parens]},
    # a multi-arg no-parens call ending in `do…end` is a valid container element (do disambiguates)
    {"[for x <- a, y <- b do x end]", [:do_block]},
    {"[z, for x <- xs, into: [] do x end]", [:do_block]},
    # a keyword value / container element that is a `do … end` call may be non-last
    {"f(a: case x do\ny -> z\nend, b: 1)", [:do_block]},
    # a reserved word as a dot member inside a clause guard (`range.end`)
    {"case z do\na when r.end -> x\n_ -> y\nend", [:do_block]},
    # the `->` may sit on the line after the clause head
    {"case h do\nn when is_number(n)\n-> b\n_ -> c\nend", [:do_block]},
    {"%...foo{}", [:struct]},
    {"%...foo{x}", [:struct]},
    # `..` / `...` as nullary (`{:.., [], []}`) and `...` as a low-precedence unary prefix
    {"..", [:operator]},
    {"...", [:operator]},
    {"...x", [:operator]},
    {"...a + b", [:operator]},
    {"..-a", [:operator]},
    {"1 + ...", [:operator]},
    {"%{...x}", [:operator]},
    {"%Foo{...1}", [:operator]},
    {"def foo() when ... do 1 end", [:operator]},
    # trailing keywords in bitstrings / dot-tuples
    {"<<foo, bar: baz>>", [:bitstring]},
    {"Foo.{A, foo: x}", [:dot_tuple]},
    # charlists
    {"'abc'", [:charlist]},
    {"''", [:charlist]},
    {"'hello world'", [:charlist]},
    {"'a\\nb'", [:charlist]},
    {"'a\#{b}c'", [:charlist]},
    {"'\#{x}'", [:charlist]},
    {"[?a | 'bc']", [:charlist]},
    {"'a\#{1 + 2}b'", [:charlist]},
    # sigils
    {"~r/foo/", [:sigil]},
    {"~r/foo/i", [:sigil]},
    {"~w(a b c)", [:sigil]},
    {"~w(a b c)a", [:sigil]},
    {"~s(hello)", [:sigil]},
    {"~s(a\#{b}c)", [:sigil]},
    {"~S(raw\#{x})", [:sigil]},
    {"~c(chars)", [:sigil]},
    {"~D[2020-01-01]", [:sigil]},
    {"~r{x}", [:sigil]},
    {"~r[x]", [:sigil]},
    {"~r<x>", [:sigil]},
    {"~r|x|", [:sigil]},
    {"~s\"abc\"", [:sigil]},
    {"~s()", [:sigil]},
    {"[~w(a b), ~w(c d)]", [:sigil]},
    {"~ABC(x)", [:sigil]},
    # heredocs
    {"\"\"\"\nhello\n\"\"\"", [:heredoc]},
    {"\"\"\"\n  indented\n  text\n  \"\"\"", [:heredoc]},
    {"\"\"\"\nx\#{y}z\n\"\"\"", [:heredoc]},
    {"~c\"\"\"\nchar\n\"\"\"", [:heredoc]},
    {"\"\"\"\n\"\"\"", [:heredoc]},
    {"~s\"\"\"\n  a\#{b}\n  \"\"\"", [:heredoc]},
    {"~S\"\"\"\n  raw\#{x}\n  \"\"\"", [:heredoc]},
    {"foo(\"\"\"\nbar\n\"\"\")", [:heredoc]},
    {":foo", [:literal]},
    # operator-named atoms (bracket/percent ops not in the op table)
    {":<<>>", [:atom]},
    {":%{}", [:atom]},
    {":{}", [:atom]},
    {":%", [:atom]},
    {":..//", [:atom]},
    {"[:<<>>, :%{}]", [:atom]},
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
    # multi-statement parens => block
    {"(a; b)", [:paren]},
    {"(a; b; c)", [:paren]},
    {"(;)", [:paren]},
    {"(a;)", [:paren]},
    {"(f a, b)", [:paren]},
    {"(a = 1; a)", [:paren]},
    {"(1 + 2; 3)", [:paren]},
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
    # dot-quoted remote calls (function name is a quoted string atom)
    {"a.\"foo\"", [:dot]},
    {"a.\"foo\"(1)", [:dot]},
    {"a.'foo'", [:dot]},
    {"a.\"foo\".bar", [:dot]},
    # keyword lists
    {"[a: 1, b: 2]", [:keyword]},
    {"[1, a: 2]", [:keyword]},
    {"[do: 1]", [:keyword]},
    # quoted keyword keys ("foo": v / 'bar': v), incl. interpolated key
    {"[\"foo\": 1]", [:keyword]},
    {"['bar': 2]", [:keyword]},
    {"[\"a b\": 1]", [:keyword]},
    {"%{\"k\": 1}", [:keyword]},
    {"f(\"a\": 1)", [:keyword]},
    {"[\"f\#{x}\": 1]", [:keyword]},
    # operator-named keyword keys (`<<>>:`, `+:`, `&:`, bracket ops, …)
    {"[<<>>: 1]", [:keyword]},
    {"[%{}: 1]", [:keyword]},
    {"[{}: 1]", [:keyword]},
    {"[%: 1]", [:keyword]},
    {"[&: 1]", [:keyword]},
    {"[..//: 1]", [:keyword]},
    {"[.: 1]", [:keyword]},
    {"[+: 1, ++: 2]", [:keyword]},
    {"[&&&: 1]", [:keyword]},
    {"[..: 1]", [:keyword]},
    {"f(<<>>: 1, x: 2)", [:keyword]},
    # `op:name` (no kw separator) is the operator applied to an `:atom`, not a keyword key
    {"[&:foo]", [:keyword]},
    {"[+:foo]", [:keyword]},
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
    # maps/structs with bare expression entries (quoted/macro code), freely mixed with => and kw
    {"%{x}", [:map]},
    {"%{x, y}", [:map]},
    {"%{1, 2}", [:map]},
    {"%{x => 1, y}", [:map]},
    {"%{x, a: 1}", [:map]},
    {"%{&0}", [:map]},
    {"%{x | y}", [:map]},
    {"%Foo{x}", [:struct]},
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
    # a paren call allows a trailing comma only after a keyword arg
    {"foo(bar: 1,)", [:trailing_comma]},
    {"foo(1, a: 2,)", [:trailing_comma]},
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
    {"!a in b", [:operator]},
    # fn / stab clauses (phase 9)
    {"fn -> :ok end", [:fn]},
    {"fn x -> x end", [:fn]},
    {"fn x, y -> x + y end", [:fn]},
    {"fn -> end", [:fn]},
    {"fn x when x > 0 -> x end", [:fn]},
    {"fn a -> 1\n b -> 2 end", [:fn]},
    {"fn 1 -> :one\n 2 -> :two end", [:fn]},
    {"f(fn x -> x end)", [:fn]},
    {"resolve fn x -> x end", [:fn]},
    {"change fn cs, _ -> cs end", [:fn]},
    {"Enum.map x, fn i -> i end", [:fn]},
    {"fn x -> y = x\n y end", [:fn]},
    # keyword args in a stab head (grouped into a trailing keyword list)
    {"fn x, a: 1 -> y end", [:fn]},
    {"fn a: 1 -> y end", [:fn]},
    {"fn x, a: 1, b: 2 -> y end", [:fn]},
    {"fn (a, b) -> a end", [:fn]},
    # stab clauses inside parens (`(args -> body)`), incl. paren-wrapped arg lists + `when`
    {"(x -> y)", [:stab]},
    {"(a, b -> c)", [:stab]},
    {"(a -> b; c -> d)", [:stab]},
    {"(() -> c)", [:stab]},
    {"((a, b, c) -> d)", [:stab]},
    {"((x, a: 1) -> foo())", [:stab]},
    {"((a: 1) -> foo())", [:stab]},
    {"((x, a: 1) when g() -> y)", [:stab]},
    {"(('a': 1) -> foo())", [:stab]},
    {"fn (a) when foo: 1 -> x end", [:fn]},
    {"fn (a, b, 'c': 1, d: 1) when g -> b end", [:fn]},
    {"fn () when x when y: z -> 0 end", [:fn]},
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
    # empty do-bodies => [do: {:__block__, [], []}]
    {"foo do end", [:do_block]},
    {"if true do\nend", [:do_block]},
    {"foo() do end", [:do_block]},
    # fn with an empty parenthesised head => zero args
    {"fn () -> :ok end", [:fn]},
    {"fn (x) -> x end", [:fn]},
    # ternary step range a..b//c
    {"1..10//2", [:operator]},
    {"a..b//c", [:operator]},
    {"1..10//2 + 3", [:operator]},
    {"(1..10)//2", [:operator]},
    # layout
    {"a\nb", [:layout]},
    {"a; b; c", [:layout]},
    {"1 +\n2", [:layout]},
    {"1\n+ 2", [:layout]},
    # newline before a binary-only operator continues the expression (multi-line pipe idiom)
    {"a\n|> b", [:layout]},
    {"foo()\n|> bar()\n|> baz()", [:layout]},
    {"x = a\n|> b\n|> c", [:layout]},
    {"a\nwhen b", [:layout]},
    {"a\n* b", [:layout]},
    # backslash-newline line continuation in code (joins the lines, no statement break)
    {"foo\\\n+1", [:layout]},
    {"\\\n0x123", [:layout]},
    {"x = 1\\\n+ 2", [:layout]}
  ]

  # Oracle rejects these; Toxic2 must not crash and must emit an :error diagnostic.
  @invalid [
    # unicode-uppercase word is valid only as an atom name, not standalone; mixed scripts banned
    {"Σ", [:unicode]},
    {"Σ = 1", [:unicode]},
    {"aαb", [:unicode]},
    # `::` / `//` are never keyword keys; `op:name` (no separator) is an `:atom`, not a kw key
    {"[::: 1]", [:keyword]},
    {"[+:1]", [:keyword]},
    {"[<<>>:foo]", [:keyword]},
    # over-chained / ineligible paren-call callees (the double-parens rule allows at most two)
    {"foo()()()", [:chained_call]},
    {"foo(1)(2)(3)", [:chained_call]},
    {"foo.bar()()()", [:chained_call]},
    {"Foo.Bar()", [:chained_call]},
    {"foo[0]()", [:chained_call]},
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
    {"foo(1, 2,)", [:recovery]},
    {"f(a: 1, 2)", [:keyword]},
    {"f(1, a: 2, 3)", [:keyword]},
    {"[a: 1, 2]", [:keyword]},
    {"[1, a: 2, 3]", [:keyword]},
    {"%{a: 1, b => 2}", [:keyword]},
    {"%{m |}", [:map]},
    {"%Foo{m |}", [:struct]},
    {"%{a: 1, x}", [:map]},
    {"{a: 1}", [:keyword]},
    {"{a: 1, b: 2}", [:keyword]},
    # `//` is only the range step: a non-range `//` is rejected (tolerant: an :error diagnostic)
    {"a // b", [:operator]},
    {"a..b//c//d", [:operator]},
    {"a..(b // c)", [:operator]},
    # commas/semicolons not allowed where they would need a tuple/call
    {"(a, b)", [:paren]},
    {"foo(a; b)", [:paren]},
    {"://", [:atom]},
    # a no-parens-call keyword value must be the last element
    {"f(a: g b, c)", [:keyword]},
    {"function(arg, one: if expr, do: :this, else: :that)", [:keyword]},
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
