# Grammar audit findings — toxic2 vs `elixir_parser.yrl`

> **STATUS (2026-06-10): all 13 findings in the original audit section are FIXED.** Regression tests live in
> `test/toxic2/yrl_edge_cases_test.exs` (§1–§3) and the parity corpus in
> `test/toxic2/token_metadata_test.exs` (§4). The audit harness (`mix run grammar_audit.exs`)
> now reports exactly the 14 known FUZZER_GAPS residuals listed at the bottom (7 cases × 2 modes)
> and nothing else; `mix toxic2.check` green. Fix notes:
> §1.1 ternary_op as Nonassoc-300 prefix (precedence.ex) + dedicated `//` clause in `lower_unary`;
> §1.2 `parse_struct` skips one eol before `{`; §2.1 `:range_op`/`:ellipsis_op` added to
> `@op_ref_kinds` (standalone `..`/`...` keep nullary `[]`); §2.2 `unwrap_splice_head/1` post-pass
> in `lower_stab_args`; §3.1 `not_in?/2` no longer fuses across an eol; §3.2 map entries reuse the
> container `:ambiguous_no_parens` check; §4.1–4.7 in lower.ex per the table.

> **FOLLOW-UP (2026-07-18): the original 13 findings remain fixed, but a broader audit found seven
> additional gaps; F1, F5, and F6 are now FIXED.** The old 527-case harness still reports only its 14
> catalogued residuals; it simply did not exercise the adjacency, dot-tokenization, and
> multiline-metadata families below.
> The follow-up used the exact parser built from the current `~/elixir` tree (Elixir 1.21.0-dev,
> commit `34abdd436`), an additional 273 rule-derived source forms, and both default and
> `token_metadata` modes. The default suite remained green (1055 tests), as did the imported parser
> and lexer gates (7510 and 774 frozen cases). These are coverage gaps rather than known failing
> regressions. No crashes occurred.

## Follow-up findings (2026-07-18)

### F1. False errors on adjacent no-parens calls — FIXED 2026-07-18

The yrl's no-parens productions do not require whitespace once the tokenizer has produced a callee
and a separate argument token:

```erlang
no_parens_one_expr -> dot_op_identifier call_args_no_parens_one
no_parens_one_expr -> dot_identifier call_args_no_parens_one
```

Toxic2's former `np_same_line_arg?/3` instead allowed an adjacent argument only when it was a string,
charlist, or operator reference. This rejects a broad family of valid calls:

```elixir
f{1}         # oracle: f({1})
f<<1>>       # oracle: f(<<1>>)
f%{}         # oracle: f(%{})
f%Foo{}      # oracle: f(%Foo{})
f~s(x)       # oracle: f(~s(x))
f&1          # oracle: f(&1)
f^x          # oracle: f(^x)
f~~~x        # oracle: f(~~~x)
f...x        # oracle: f(...x)
f!x          # oracle: f!(x)
f?x          # oracle: f?(x)
Kernel.+1    # oracle: Kernel.+(1)
Bitwise.~~~x # oracle: Bitwise.~~~(x)
```

Toxic2 tokenizes these into the necessary separate tokens, then leaves the argument as a second
top-level expression and emits `:unexpected_token`. Parenthesized and space-separated equivalents
work. This is a parser admission bug, not an AST-lowering difference.

Fixed in `np_arg_start?/4`: once lexing has produced a separate primary/prefix token, adjacency is
accepted for local and remote no-parens calls. The admission rule preserves the tokenizer's special
boundaries: adjacent `+`/`-` remain infix, `(`/`[` remain postfix delimiters, `{` remains the struct
body delimiter while parsing a struct name (including unary names), and invalid bare `foo@bar`
still reports an error. Parser and token-metadata oracle regressions cover every family above plus
remote operator callees and the ambiguous-boundary counterexamples.

**Real-code likelihood: medium, highest of the new syntax gaps.** Elixir's formatter normally adds
spaces or parentheses, so these forms are uncommon in formatted projects. They are nevertheless
ordinary valid syntax and can occur in macro DSLs, generated code, or unformatted editor buffers;
`f!x`/`f?x` and adjacent sigil/map arguments are considerably less fuzzer-like than the old `%` soup.

### F2. False errors from missing dot-context operator tokenization

The upstream tokenizer has a dedicated `handle_dot` path: only operators legal as remote member
names are emitted as one `op_identifier`; excluded multi-character sequences are split and then
parsed by the ordinary operator grammar. Toxic2 always applies context-free longest operator match.

```elixir
foo.//1
# oracle: (foo./()) / 1
# toxic2: one :ternary_op (`//`) after dot, then :nonexistent_atom / parser errors

foo.->1
# oracle: (foo.-()) > 1

foo.=>1
# oracle: (foo.=()) > 1
```

The regular operator-member forms with parentheses (`foo.++(1, 2)`) already work; adjacent valid
operator calls such as `Kernel.+1` are F1 rather than this tokenizer-specific split.

**Real-code likelihood: very low.** These are legal parser inputs but highly surprising source
spellings. This is primarily completeness work unless a generated-source corpus demonstrates use.

### F3. Newline-before-comma missed-error family is broader than the original list

The original audit listed lists, calls, tuples, bitstrings, and keyword lists. The same unconditional
`skip_eols/2` before comma detection also silently accepts invalid maps, structs, access arguments,
map updates, and fn heads:

```elixir
%{a: 1
, b: 2}

%{1 => 2
, 3 => 4}

%{m | a: 1
, b: 2}

%Foo{a: 1
, b: 2}

a[b: 1
, c: 2]

fn a
, b -> 1 end
```

All are rejected by the yrl because its eol productions allow newlines after open delimiters,
before close delimiters, or after selected operators/keyword keys—not between a completed element
and its comma. The fn/access variants were already mentioned in `FUZZER_GAPS.md`; the broader family
is recorded here so the grammar gap is not mistaken for five isolated cases.

**Real-code likelihood: low for compilable files, medium for IDE/edit-time correctness.** These
inputs are invalid, so they will not occur in a compiling project, but they are plausible temporary
states while editing comma-last code. The impact is a missed diagnostic, not a false rejection.

### F4. Parenthesized fn keyword-list guards are accepted incorrectly

```elixir
fn (a, b) when c: 1 -> 2 end
# oracle: syntax error before `c`
# toxic2: valid-looking {:fn, ...} with no error diagnostic
```

The yrl production is `stab_parens_many when_op expr`; a bare keyword list is not an `expr` here.
`clause_head_guard/6` explicitly recognizes `kw_data_start?` and calls `when_kw_rhs`, thereby
accepting a grammar form that does not exist. This was already catalogued in `FUZZER_GAPS.md`, but
is included in this rule-by-rule inventory because it remains open.

**Real-code likelihood: low.** It most plausibly appears as a malformed or half-written guard and
therefore affects strict diagnostics more than valid-source parsing.

### F5. Access opening-newline metadata is missing — FIXED 2026-07-18

```elixir
a[
  key
]
```

With `token_metadata: true`, upstream puts `newlines: 1` on both metadata lists of the generated
`Access.get` call. Toxic2's `access_dot_meta/4` emits only `from_brackets`, `closing`, `line`, and
`column`. This affects both expression and keyword access arguments (`a[\nb: 1\n]`). Default AST
shape and error status are correct.

Fixed in `access_dot_meta/4`: it now uses the same comment-aware newline-gap calculation as other
delimiter metadata and preserves upstream key order (`from_brackets`, `newlines`, `closing`, anchor).
Oracle-parity regressions cover expression, keyword, comment-separated, and order-sensitive cases.

**Real-code likelihood: high for token-metadata consumers.** Multiline access syntax is normal
source. The bug does not affect evaluation, but it can affect formatter-grade tools, source maps,
and any consumer claiming `token_metadata` parity.

### F6. Multiline parenthesized stab metadata is wrong — FIXED 2026-07-18

```elixir
fn (
  a, b
) -> 1 end
```

Upstream attaches `parens: [line: 1, column: 4, closing: ...]` to the `->` node. Toxic2 drops that
entry and adds a spurious `newlines: 1`. `patterns_parens_meta/3` only detects `(` immediately before
the first pattern and `)` immediately after the last pattern on their respective lines, so it cannot
find delimiters placed on separate lines. A related case, `fn ()\nwhen x -> 1 end`, adds a spurious
`newlines:` entry to `when` upstream does not emit.

Fixed by recovering the full first/last pattern token boundaries and then the surrounding `(`/`)`
tokens, rather than relying on same-line source adjacency. Arrow scanning now begins after the
closing delimiter for unguarded parenthesized heads, and parenthesized guards suppress only the
newline run between `)` and `when`. Oracle-parity regressions cover multiline, empty, guarded,
keyword-only, and nested-pattern heads.

**Real-code likelihood: medium for token-metadata consumers.** Multiline anonymous-function heads
are less common than multiline access but are reasonable for long patterns or generated code.

### F7. Leading-semicolon stab bodies still miss warning and literal metadata

```elixir
fn x -> ; end
fn x -> ; 1 end
```

Upstream treats the leading semicolon as an empty first stab-body expression: it emits the
empty-clause warning, builds the implicit `nil` through `handle_literal(nil, StabToken)`, and under
`token_metadata` annotates that literal with the `->` position and the semicolon's
`end_of_expression`. Toxic2 builds a bare `nil` and emits no warning. The missed warning was already
listed in `FUZZER_GAPS.md`; the literal-encoder/end-of-expression mismatch was not.

**Real-code likelihood: very low.** Semicolon-prefixed empty bodies are predominantly malformed or
generated edge cases.

### Remaining follow-up priority

| Priority | Finding | Why |
|---|---|---|
| 1 | F3 newline-before-comma | Useful IDE diagnostic parity, but the input is invalid and cannot break compiling code. |
| 2 | F4 keyword-list fn guard | Missed error on malformed source; already catalogued elsewhere. |
| 3 | F2 dot-context operator split | Valid but extremely obscure spellings. |
| 4 | F7 semicolon stab body | Warning/metadata only on an exceptionally rare form. |

Differential audit (2026-06-10) of `Toxic2.parse_to_ast/2` against the official grammar at
`~/elixir/lib/elixir/src/elixir_parser.yrl` (Elixir 1.20.0 oracle, `Code.string_to_quoted/2`).

**Method.** 527 cases derived rule-by-rule from every yrl production family (call shapes,
stab/fn/paren-stab, containers, maps/structs, dot forms, kw lists, access, eol rules, nullary ops,
capture) plus the Erlang helper special-cases (`build_unary_op('//')`, `unwrap_splice`,
`build_paren_stab` `?rearrange_uop`, `build_op` `'//'`/`'not in'` rewrites, `error_*` productions).
Each case is run in two modes:

- **default** — structural AST parity (meta stripped, per the P4 no-meta-parity design) +
  error-status parity (oracle `{:error, _}` ⇒ toxic2 must emit ≥1 `:error` diagnostic; oracle
  `{:ok, _}` ⇒ none).
- **token_metadata** — full-fidelity comparison with `token_metadata: true`, `columns: true`, and
  an identical `literal_encoder` on both sides.

Harness: `grammar_audit.exs` (repo root) — `mix run grammar_audit.exs`.

Everything already catalogued in `test/toxic2/FUZZER_GAPS.md` is excluded (see "Known gaps
re-confirmed" at the bottom). What follows is **new**. Nothing crashed across the run — the
tolerant-parser invariant held everywhere.

## 1. False errors on valid code

Legal, writable Elixir that toxic2 rejects. Worst class — violates "never false-positive on real
code".

### 1.1 `&//2` — capture of the `/` operator

```elixir
&//2
# oracle: {:&, [l1 c1], [{:/, [l1 c4], [{:/, [l1 c2], nil}, 2]}]}
# toxic2: :unexpected_token (ternary_op) + :unexpected_token (int)
```

The grammar admits `//` as a *unary* (`unary_op_eol -> ternary_op`), and `build_unary_op` has a
dedicated `'//'` clause rewriting it into nested `{:/, _, [{:/, _, nil}, Expr]}` — this is the
documented way to capture `Kernel.//2` (division). Toxic2's `parse_prefix` doesn't accept
`:ternary_op` as a prefix (it is in `@op_ref_kinds` but that path doesn't fire here), so the parse
fails. Note the column trick upstream: outer `/` gets `column: Column+1`, inner gets `Column`.

### 1.2 `%Foo\n{}` — eol between struct name and body

```elixir
%Foo
{}
# oracle: {:%, …, [{:__aliases__, …, [:Foo]}, {:%{}, …, []}]}
# toxic2: :expected_struct_body; lowers to {:%, [], [Foo, __error__]} + a separate {:{}, [], []}
```

yrl rule: `map -> '%' map_base_expr eol map_args` explicitly allows one eol. `parse_struct`
(parser.ex ~1735) checks `tk(t, j) == :"{"` directly after the base without skipping an eol.

## 2. Wrong AST on valid code

### 2.1 `&../2` / `&.../2` / `& ../2` — operator-as-identifier in capture

```elixir
&../2
# oracle: {:&, …, [{:/, …, [{:.., [l1 c2], nil}, 2]}]}    # args nil
# toxic2: {:&, …, [{:/, …, [{:.., [l1 c2], []}, 2]}]}     # args []
```

Elixir's tokenizer re-emits an operator followed by `/arity` in capture position as an
**identifier** token, so the oracle builds `{:.., _, nil}` via `build_identifier`. Toxic2 keeps
`range_op`/`ellipsis_op` and lowers the nullary-op form `{:.., _, []}`. Standalone `..` / `(..)`
correctly stay `[]` on both sides — only the capture context differs. Same for `...`.

### 2.2 `((unquote_splicing([1, 2])) -> :ok)` — `unwrap_splice` through parens

```elixir
((unquote_splicing([1, 2])) -> :ok)
# oracle: [{:->, …, [[{:unquote_splicing, …, [[1, 2]]}], :ok]}]
# toxic2: [{:->, …, [[{:__block__, …, [{:unquote_splicing, …, [[1, 2]]}]}], :ok]}]
```

A lone `(unquote_splicing(x))` is wrapped in `__block__` by `build_block` (correct, and toxic2
does this — lower.ex ~1353/2210). But in `stab_parens_many` the grammar applies `unwrap_splice`
to the head args, which strips that wrapper again. Toxic2 keeps the block as the clause arg.

## 3. Missed errors

Oracle rejects; toxic2 builds a tree with **no** `:error` diagnostic (`:unexpected_valid` in
conformance terms).

### 3.1 `a not\nin b`

```elixir
a not
in b
# oracle: syntax error before: in (line 2) — `not in` must not be split across lines
# toxic2: {:not, [], [{:in, [], [a, b]}]}, diags: []
```

Toxic2 fuses `not` + `in` into `not in` across the newline.

### 3.2 `%{f(a) => g b, c}` — no-parens-many call as assoc value

```elixir
%{f(a) => g b, c}
# oracle: syntax error before: ',' (assoc_expr only admits matched/unmatched exprs)
# toxic2: %{f(a) => g(b, c)}, diags: []
```

Adjacent to the catalogued FUZZER_GAPS bucket "map entry that isn't `key => value`"
(`%{foo bar, baz}`), but this is the assoc-**value** position, which is plausible in real code —
counted as new.

## 4. token_metadata / literal_encoder fidelity

Only visible in `token_metadata: true` mode (default mode strips meta by design, P4) — but that
mode claims oracle parity, so these are bugs against `test/toxic2/token_metadata_test.exs` scope.

| # | Input | Divergence |
|---|-------|------------|
| 4.1 | `fn -> end`, `fn x -> end` | Implicit clause body is `handle_literal(nil, StabToken)` upstream — i.e. **encoded** via the literal encoder with the `->` position. Toxic2 emits bare `nil`. |
| 4.2 | `a[b: 1]`, `x[a: 1, b: 2]` | `build_access_arg` passes a `kw_data` bracket-arg **raw** (it is not a list literal). Toxic2 over-encodes it: `{:__lit__, [closing: …, line:, column:], [[…kw…]]}`. |
| 4.3 | `(1..2)//3` | Oracle's `..//` node keeps the `parens: [closing: …]` annotation inherited from the parenthesized `..` (build_op reuses the `..` node's meta). Toxic2 drops it. |
| 4.4 | `f.(1) do end` | `closing:` should be the `)` at line 1 col 5; toxic2 emits col 12 (inside `end`). Plain `f.(1)` is correct. |
| 4.5 | `'a#{1}b'` | The `{:., _, [List, :to_charlist]}` dot node carries the charlist's line/column upstream (set unconditionally, even without token_metadata). Toxic2 hardcodes `[]` — lower.ex:1024. |
| 4.6 | `a\n.b` | When the dot starts a line, oracle anchors the `.` node at the **dot** (line 2, col 1); toxic2 anchors at the identifier (col 2). All same-line dot cases match. |
| 4.7 | `%{:a\n=> 1}` | `assoc:` meta on the key is missing when a newline precedes `=>` (the `=>`-position scan around lower.ex:2245 appears to stop at the eol). Same-line `=>` is correct. |

## Known gaps re-confirmed (excluded, already in FUZZER_GAPS.md)

The audit independently re-hit these catalogued items; listed only to show the harness sees them:

- newline-before-comma missed errors: `[1\n,2]`, `f(1\n, 2)`, `{1\n, 2}`, `<<1\n, 2>>`,
  `[a: 1\n, b: 2]` (and `f a\n, b` correctly errors on both sides);
- `%`-soup false errors: `%...{}`, `%fn -> 1 end{}` (`:expected_map_or_struct` /
  `:expected_struct_body` bucket). NB `%Foo\n{}` (§1.2) is **not** in that bucket — the base is a
  plain alias and only the eol trips it.

## Severity summary

- §1.1–1.2 break real code (`&//2` is the documented capture of `/`) — fix first.
- §2–3 are correctness/error-parity on plausible-but-rare constructs.
- §4 matters only to token_metadata consumers (formatter-grade tooling).
