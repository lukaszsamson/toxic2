# Fuzzer-corpus gap catalogue

**Scope:** this is a `toxic_parser` *corpus* divergence catalogue — toxic2 vs the live Elixir oracle
over every `assert_conforms` / `assert_error_conforms` / `assert_warning_conforms` input in the
`toxic_parser` test suite (2232 unique inputs across 33 files). It is NOT a full inventory of every
upstream `elixir_tokenizer` / `elixir_interpolation` / `elixir_parser` diagnostic — those that the
corpus doesn't exercise (e.g. lexical/security diagnostics) are tracked separately; see "Upstream
diagnostics addressed outside the corpus" below.

> **Validish-reachability re-audit (2026-06-12).** The buckets below were re-tested after the
> grammar-gaps fixes (commit `f8dbc2f`) and probed for *realistic* (not fuzzer-soup) embodiments.
> Most buckets are confirmed fuzzer-only, but **four findings are reachable from plausible
> human-written code** and are promoted to the new "## Validish-reachable (NOT fuzzer-only)"
> section. Some "False ERRORS" rows are also now **stale** — `%{//A}` and `<<a::l."" u>>` agree
> with the oracle post-`f8dbc2f`. See that section for details and per-finding status.

**Method note (important):** an earlier sweep harness wrote `ds!=[]` without spaces, which Elixir
parses as `ds! = []` (assign to a var named `ds!`, always truthy) — the very ambiguity toxic2 now
warns about — so it classified almost everything as `:warning`. All numbers below use `ds != []`.
(This footgun recurred several times in throwaway scripts; always space `!=`.)

## Headline (post-fixes)

| bucket | count | meaning |
|---|---:|---|
| crashes | **0** | toxic2 never raises (P5 totality holds) |
| false errors (oracle ok/warn, toxic2 error) | 83† | toxic2 too strict on operator-soup |
| missed errors (oracle error, toxic2 ok/warn) | 47† | strict-mode detection gaps |
| missed warnings (oracle warn, toxic2 ok) | 16 | edge variants of warnings we DO emit |
| **extra warnings (oracle ok, toxic2 warn)** | **0** | no false-positive warnings |

† Counts predate the grammar-gaps fixes (`f8dbc2f`) and are overstated — at least `%{//A}` and
`<<a::l."" u>>` now agree with the oracle; needs a re-sweep. And four buckets within these counts are
**not** fuzzer-only — see "Validish-reachable (NOT fuzzer-only)" below.

On the 2632-file **real-world** corpus (elixir/lib, deps, absinthe, bitcoinex, dialyxir): **0 false
errors, 0 extra warnings, 0 crashes.** The remaining corpus divergences below are synthetic fuzzer
operator-soup that does not occur in real code.

## Upstream diagnostics addressed outside the corpus

A review noted the corpus catalogue is not a full upstream inventory; these clean
lexer/interpolation/security diagnostics were missing and are now implemented (with conformance
tests in `diagnostics_conformance_test.exs`):

- **comment `?break` chars → ERROR** — VT/FF/NEL/U+2028/U+2029 in a `#` comment
  (`elixir_tokenizer` `tokenize_comment`). Code `:invalid_break` (bidi in comments was already
  `:invalid_bidi`).
- **string/sigil/heredoc `?break` chars → WARNING** — `:unsupported_break` (`elixir_interpolation`
  `extract_char`). Bidi in strings was already an error.
- **single-quoted charlist with a non-UTF-8 byte → ERROR** — `'\xFF'` yields the raw byte (not
  codepoint U+00FF) and a charlist is decoded as UTF-8, so it is invalid. Code
  `:invalid_charlist_encoding`. NB the earlier catalogue wrongly grouped `"\xFF"` here — a
  *double-quoted* `"\xFF"` is valid binary syntax (`<<255>>`) and is NOT an error; only charlists.
- **confusable identifiers → WARNING** — UTS-39 (`String.Tokenizer.Security`), e.g. Cyrillic `а`
  vs Latin `a`. Code `:confusable_identifier`. Vendored `confusables.txt` + a port of Elixir's
  `security.ex` under `lib/toxic2/unicode/` (reusing the tokenizer's `dir/1`); run as a whole-file
  pass only when a non-ASCII identifier is present.

## Validish-reachable (NOT fuzzer-only) — 2026-06-12 re-audit

The original verdict ("synthetic fuzzer operator-soup; never false-positives on real code") rests on
the 2632-file corpus not *happening* to contain these shapes. Probing each bucket for the simplest
plausible human-written embodiment found four that are genuinely reachable. Method: doc examples +
~40 hand-built realistic candidates run through both parsers post-`f8dbc2f` (harness left at
`/tmp/fuzzer_gaps_audit.exs` during the audit; not committed).

### V1. FALSE ERROR — `quote(do: defstruct a: 1, b: 2)` (parens-call kw value is a kw-only no-parens call)

This is the "structural theme" already flagged at the bottom of "False ERRORS" — but it is **not**
fuzzer-only. It is the parenthesized twin of the very bug already fixed in "Fixed" §1 (which bit real
earmark code). toxic2 raises `:no_parens_kw_not_last`; the oracle accepts.

```elixir
quote(do: defstruct a: 1, b: 2)          # FALSE ERROR — ordinary macro-writing code
defmodule(Foo, do: defstruct a: 1, b: 2) # FALSE ERROR
foo(x: bar a: 1)                          # OK (single inner kw pair already works)
```

Trigger is narrower than the doc implied: the inner kw-only no-parens call needs **≥2 kw pairs**.
Root cause + fix are the SAME as "Fixed" §1: a trailing run of keyword pairs is ONE argument
(`call_args_no_parens_kw`), but here the inner call sits as a `kw_call`/`kw_data` *value* of an outer
**parens** call, and that absorption path wasn't updated. **Recommend fix** (clean, mirrors §1).

### V2. MISSED ERROR — operator-rooted bare map/struct entries (a `=`/`:` typo class)

The fuzzer exemplars (`%{0*0}`, `%Foo{o=t}`) read as soup, but the bucket is "a bare entry whose root
is a binary operator," and that is a textbook typo:

```elixir
%User{name = "x", age: 1}   # MISSED ERROR — `=` instead of `:` (classic)
%{state | count + 1}        # MISSED ERROR — forgot `count:` in an update
%{count + 1}                # MISSED ERROR
%{key <> "x"}               # MISSED ERROR
```

Key discovery: **bare-identifier / access / update shorthands are grammar-VALID upstream**
(`assoc_expr -> map_base_expr`), so the innocuous-looking typos do NOT hit this gap —

```elixir
%{name}  %{user.id}  %{m | name}  %{compute(x)}  %{state | count}   # all OK on both sides
```

— only **operator-rooted** entries are rejected. That gives the obvious grouped grammar rule the doc
asks for as its promotion bar: a bare map/struct entry (and update entry) must be `map_base_expr`-
shaped (a `sub_matched_expr` under at/unary/ellipsis chains), not an arbitrary `matched_expr`.
**Recommend fix** (one grouped rule covers all the `[42] syntax error before:` map/struct rows).

### V3. MISSED ERROR — ambiguous comma in `assert`-style no-parens code

Bucket `[4]` (`foo 1, 2 + bar 3, 4`) is reachable via ExUnit's `assert msg` idiom:

```elixir
assert x == y, "expected " <> inspect x, label: "x"   # MISSED ERROR
assert valid?, "got " <> describe x, y                # MISSED ERROR
```

Oracle rejects (`unexpected comma. Parentheses are required…`); toxic2 builds a (well-formed)
best-effort tree silently. Borderline: real but rarer, and the tolerant tree is sound.
**Optional fix.**

### V4. FALSE ERROR — `%//x{}` (completeness gap from our own §1.1 // fix)

Not validish itself, but a self-inflicted inconsistency: the grammar-gaps §1.1 fix added `//` as a
unary in expression position, but `struct_base_start?` / the struct-base unary chain weren't updated,
so a struct base disagrees with every other unary base:

```elixir
%!x{}   %not x{}   %-x{}   # OK (oracle + toxic2)
%//x{}                     # FALSE ERROR (toxic2 only) — upstream map_base_expr admits ternary_op
```

**Recommend fix** (one-liner: add `:ternary_op` to `struct_base_start?` and the map_base unary path).

### Confirmed fuzzer-only (no plausible embodiment found)

- **Interpolation / binary-spec soup** (`["foo#{l.s^h}": 1]`): every realistic analog agrees —
  `"#{Map.get map, :key}"`, `"#{f -1}"`, `"#{a.b -1}"`, `["#{prefix}_id": 1]`, `<<x::m.unit 8>>`.
- **Newline-then-comma family** (`[d\n,]`, `foo(0\n,a)`): realistic mid-edit forms with a
  comma-first dangling element (`[\n  ,\n  b\n]`, `foo(\n  ,\n  b\n)`) are **correctly rejected by
  toxic2 too** — the miss needs a *complete element* before the newline-comma, i.e. comma-last
  trailing style split mid-line, which the formatter eliminates.
- **fn parens kw-guard** (`fn (a, b) when h: e`): all valid guard forms agree.
- **`%...{}`, `%fn … end{}`, `foo[[e?i]=e,]`**: stay soup.

### Stale rows (now agree with the oracle post-`f8dbc2f`)

The grammar-gaps commit collaterally fixed two "False ERRORS" exemplars — the `[32] :unexpected_token`
and `[25/6]` counts are overstated:

- `%{//A}` — now **OK** on both sides.
- `<<a::l."" u>>` — now **OK** on both sides.

(These should be re-counted on the next full corpus sweep; the headline table's "83 false errors"
predates `f8dbc2f`.)

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

## Missed ERRORS (47) — oracle rejects, toxic2 builds a best-effort tree

By oracle message (the comment-break-char and charlist-encoding rows from the earlier count of 50
are now FIXED — see "Upstream diagnostics addressed" above — leaving 47):

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
- **[FIXED] comment break char** — U+2028/U+2029/VT/FF/NEL inside a `#` comment, now
  `:invalid_break`. (was: `# This is a  `. (Lexical — a clean candidate if ever wanted.)
- **[FIXED] charlist invalid encoding** — `'\xFF'` now `:invalid_charlist_encoding`. (The earlier
  catalogue wrongly listed `"\xFF"` here; a double-quoted `"\xFF"` is valid binary syntax `<<255>>`
  and is NOT an error — only the charlist is.)
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

The one structural theme worth noting: a no-parens call with keyword args as a **parenthesised**-call
kw value (`foo(x: defstruct a: 1, b: 2)`) raises `:no_parens_kw_not_last` because the inner kw args
don't get absorbed by the inner call. **This is NOT fuzzer-only** — `quote(do: defstruct a: 1, b: 2)`
is ordinary macro code; see "Validish-reachable" §V1 above (promoted 2026-06-12).

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

The clean upstream lexer/interpolation/security diagnostics that this corpus catalogue had missed
are now implemented (see "Upstream diagnostics addressed outside the corpus"). Most of what remains
in the corpus buckets is synthetic fuzzer operator-soup: it produces a best-effort tree, never
crashes, and never false-positives on real code, so — per the tolerant-parser design and the
"don't chase individual fuzzer programs" guidance — it stays catalogued rather than chased.

**But the 2026-06-12 re-audit found four buckets DO have validish embodiments** (see
"Validish-reachable" above): V1 `quote(do: defstruct a: 1, b: 2)` (false error, parens twin of
"Fixed" §1), V2 operator-rooted bare map/struct entries (missed error, `=`/`:` typo class, has an
obvious grouped grammar rule), V3 `assert msg, … x, y` ambiguous comma (missed error), and V4
`%//x{}` (false error, completeness gap from the §1.1 fix). V1/V2/V4 meet this doc's own promotion
bar ("a real corpus example appears or a grouped grammar rule becomes obvious") and are recommended
for fixing; V3 is optional. The headline "83 false errors" count also predates `f8dbc2f` and is
overstated (see "Stale rows"). (This catalogue is scoped to the toxic_parser corpus; it is not a
guarantee that every upstream diagnostic is covered.)
