# Fuzzer-corpus gap catalogue

Cataloguing toxic2's remaining divergences from the live Elixir oracle, measured by extracting every
`assert_conforms` / `assert_error_conforms` / `assert_warning_conforms` input from the
`toxic_parser` test suite (2232 unique inputs across 33 files) and classifying each (`:ok | :warning
| :error`) against `Code.with_diagnostics(&Code.string_to_quoted/1)`.

**Method note (important):** an earlier sweep harness wrote `ds!=[]` without spaces, which Elixir
parses as `ds! = []` (assign to a var named `ds!`, always truthy) — the very ambiguity toxic2 now
warns about — so it classified almost everything as `:warning`. All numbers below use `ds != []`.

## Headline (post-fixes)

| bucket | count | meaning |
|---|---:|---|
| crashes | **0** | toxic2 never raises (P5 totality holds) |
| false errors (oracle ok/warn, toxic2 error) | 83 | toxic2 too strict on operator-soup |
| missed errors (oracle error, toxic2 ok/warn) | 50 | strict-mode detection gaps |
| missed warnings (oracle warn, toxic2 ok) | 16 | edge variants of warnings we DO emit |
| **extra warnings (oracle ok, toxic2 warn)** | **0** | no false-positive warnings |

On the 2632-file **real-world** corpus (elixir/lib, deps, absinthe, bitcoinex, dialyxir): **0 false
errors, 0 extra warnings, 0 crashes.** Every divergence below is synthetic fuzzer operator-soup that
does not occur in real code — except the two bugs in "Fixed", which the fuzzer *did* surface on real
code and which are now fixed.

## Fixed (were real false positives)

1. **`:nested_no_parens_keyword` on kw-only no-parens calls.** `defmodule Foo, do: defstruct a: 1,
   b: 2` (extremely common) warned, because each keyword pair counted as a separate argument. A
   trailing run of keyword pairs is ONE argument (`call_args_no_parens_kw`); fixed in both
   `parser.ex no_parens_expr?` and `lower.ex no_parens_call_cst?`. Hit real earmark code (3 files).
2. **`:empty_paren` on `(;)`.** `()` warns (the `empty_paren` rule) but `(;)` is a `;`-block (a
   different production) and does NOT — and `fn () -> …` parens are a clause-head arg list, not an
   expression. Fixed by scoping to paren *expressions* (in `lower_paren`) and checking the source
   between the delimiters for a `;`.

Both are covered by regressions in `diagnostics_conformance_test.exs`.

## Missed ERRORS (50) — oracle rejects, toxic2 builds a best-effort tree

By oracle message:

- **[42] `syntax error before:`** — fuzzer operator-soup that hits a grammar production toxic2
  tolerates. Sub-categories (curated examples):
  - map/struct entry that isn't `key => value` / `key: value` (a bare expression):
    `%{foo bar, baz}`, `%{0*0}`, `%Foo{o=t}`, `%{&x}`
  - map-UPDATE (`%{x | …}`) with a non-entry: `%{x | &b}`, `%{x | e>n,}`
  - `fn (a, …)` parenthesised args with newline-comma / kw-guard: `fn (a, l\n,n) -> :ok end`,
    `fn (a, b) when h: e -> :ok end`
  - newline-then-comma in brackets/access/bitstring: `[d\n,]`, `{s\n,}`, `foo[l\n,]`,
    `foo(0\n,a)`, `<<a::n\n,>>`
- **[4] `unexpected comma. Parentheses are required…`** — ambiguous no-parens with a following comma
  past an operator: `foo 1, 2 + bar 3, 4`.
- **[2] `invalid line break character in comment:`** — U+2028 / U+2029 inside a `#` comment:
  `# This is a  `. (Lexical — a clean candidate if ever wanted.)
- **[1] `invalid encoding starting at <<255>>`** — a quoted literal whose bytes aren't valid UTF-8
  via `\xFF`: `'\xFF'`, `"\xFF"`. (Lexical — clean candidate.)
- **[1] bidi in a string** — `"this is a ‪"` (a bidi control char inside a string; toxic2
  already rejects bidi as a bare token but not inside a string escaped this way).

## False ERRORS (83) — oracle accepts (with a warning), toxic2 rejects

All synthetic operator-soup; none occur in the 2632-file real corpus. By toxic2 code:

- **[32] `:unexpected_token`**, **[25/6] `:expected_comma_or_close`+`:unexpected_token`** — toxic2 is
  stricter than the oracle on garbage like `["foo#{l.s^h}": 1]` (interpolation containing `l.s^h`),
  `<<a::l."" u>>`, `%{//A}`.
- **[~10] `:expected_map_or_struct` / `:expected_struct_body` / `:misplaced_step_op`** — `%//foo{}`,
  `%...{}`, `%fn -a -> 1 end{}` — `%` followed by operator-soup before `{`.
- **[3] access + trailing-comma soup** — `foo[[e?i]=e,]`.
- **[1 each] mixed** — a few giant multi-line soup inputs that also (correctly) trip warnings.

The one structural theme worth noting (still fuzzer-only): a no-parens call with keyword args as a
**parenthesised**-call kw value (`foo(x: defstruct a: 1, b: 2)`) raises `:no_parens_kw_not_last`
because the inner kw args don't get absorbed by the inner call. Real code writes `defstruct` at the
module level, not as a paren-call kw value, so this never hits the corpus.

## Missed WARNINGS (16) — oracle warns, toxic2 stays clean

Edge variants of warnings toxic2 already emits in the common case:

- **[7] `:nested_no_parens_keyword`** where the kw VALUE is a `when`-with-keyword-guards expression
  (`a foo: x when y: z, z: w`) — toxic2 detects no-parens *calls* as kw values but not this `when`
  shape.
- **[5] `:no_parens_after_do_op`** buried in long operator chains — toxic2 detects the direct
  `<do-block> <op> <multi-arg no-parens>` shape but not these nested fuzzer forms.
- **[4] `:empty_stab_clause`** with a `;` in the body (`fn x when e->;e -> 1 end`, `fn 1 -> ;fs
  end`) — toxic2 detects a truly empty `->` body but treats a leading `;` as a (non-empty) statement.

(The `?\<newline>` char-literal warning that previously sat here is now emitted —
`:unusual_char_literal`, same as any named-escape special char.)

## Verdict

Per the tolerant-parser design and the "don't chase fuzzer correctness" guidance, the remaining
gaps are left as-is: they are all synthetic, produce a best-effort tree, never crash, and never
false-positive on real code. The clean candidates if ever wanted (all lexical, low risk): invalid
UTF-8 in a quoted literal (`'\xFF'`) and U+2028/2029 in a comment.
