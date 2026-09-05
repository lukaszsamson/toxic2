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

> **AUDITS MERGED (2026-09-05):** two further independent audits are appended at the bottom of this
> file — the OX audit (2026-08-23, OX1–OX4), the KIMI audit (2026-08-24, K1–K15), and the GPT
> review (2026-09-05, R1–R20; reproducer harness in `grammar_review_20260905.exs`). All of their
> findings were verified against the tree at the date each was merged.

## Consolidated priority (2026-09-05, all open findings)

Ranked by how likely the input is to occur in valid or close-to-valid code as it is being
edited (the IDE/LSP use case). Silent corruption of valid code outranks false errors, which
outrank missed diagnostics; fuzzer token soup is bottom-tier regardless of class.

**P0 — silently corrupts ordinary valid code:**

| Rank | Finding | Why first |
|---|---|---|
| 1 | R3 heredoc indentation vs `#{`/braces | Changes string VALUES. `~S"""` bodies mentioning `#{` (docs about interpolation!) and `#{"{"}`-style braces in interpolated heredocs are normal code. |
| 2 | R18 grapheme-cluster column drift | Any emoji/combining char in a string shifts every later column on the line — silently poisons ranges and semantic tokens; emoji in strings are everywhere. |
| 3 | R1 + R2 spaced access / empty-remote-call re-call | `f() [0]`, `Foo [0]` falsely rejected; `a.b() [0]` and `a.b() 1` silently misparse. Space before `[` and just-completed `()` calls are routine typing states. Fix together (see R2 note). |

**P1 — valid but less common code: false errors or silent wrong AST:**

| Rank | Finding | Notes |
|---|---|---|
| 4 | K1 `unwrap_when` (`fn a when b, c -> d end`) | Ordinary valid syntax, 16 confirmed shapes, all false errors. |
| 5 | R4 `not in` keyword ownership / strictness | Silent wrong AST (`y: 2` leaves the inner call) plus missed ambiguity errors. |
| 6 | R5 keyword keys `[Foo!: 1]` / `[foo@bar: 1]` | Valid keys falsely rejected by the ASCII fast paths. |
| 7 | OX4 column drift after multi-byte escapes | Same corruption class as R18, but needs a written `\é`-style escape. |
| 8 | R17 `unquote_splicing` block wrapper | The wrong-AST arms are rare, but the arity-one metadata mismatch hits `quote do unquote_splicing(x) end` — an extremely common macro idiom. |

**P2 — close-to-valid mid-edit states an IDE must diagnose correctly:**

| Rank | Finding | Notes |
|---|---|---|
| 9 | OX1 doubled `->` splits clauses silently | Classic one-line typo; clean-looking wrong tree plus a misleading warning. |
| 10 | R6 malformed `\u{…` accepted | Half-typed escape yields a silently wrong string value. |
| 11 | R14 trailing `\` at EOF accepted | Explicitly an incomplete-buffer shape. |
| 12 | K4 do-block calls as clause heads | Plausible while wrapping a body in `if … do … end`; silent nonsense tree. |
| 13 | F3 + K8 newline-before-comma family (incl. comment-interleaved) | Comma-first editing states; fix must be comment-aware per K8. |
| 14 | K7 kw-then-positional fn heads | Half-typed heads accepted silently. |
| 15 | R16 postfix after unary-wrapped do-block | Admission inconsistency, mid-edit shape. |
| 16 | OX2 uppercase radix `0XFF` | C-habit typo, clear-cut missed error. |
| 17 | K6 + extension (`when` kw guards in restricted positions) | Missed ambiguity errors across containers/associations. |

**P3 — comment-poisoned metadata anchors (formatter/LSP-grade, common comments):**

| Rank | Finding | Notes |
|---|---|---|
| 18 | K14 `->` inside a comment hijacks the arrow anchor | Comments like `# maps a -> b` are common. |
| 19 | K10 `not`/`in` inside a comment hijacks `not in` anchor (+ missing `newlines:`) | Same root: `:binary.match` source scans; a token-driven scan fixes both. |

**P4 — rare valid spellings, metadata/warning parity:** R8/R9 (attribute `@f()(1)`, `@@f[x]`
grouping), R11 (ellipsis newline/`not in` boundaries), R12 (`f +..`), R13 (`&0x0A`/`&1_0`),
K3 (`?\é`), R7 (escaped raw bidi/forbidden chars), R15 (`é@bar`/`not@bar` identifiers),
OX3 (`%{a not in b}`), K5 (`%<do-block>{}`), F4 (parenthesised fn kw guard), K13 (encoder
suppressing nested-no-parens warning), K15 (duplicate outdent warnings), K11 (`fn\n-> 1 end`
newlines placement), K9 (`not x in y` meta without token_metadata), K12 (`:true` `format: :atom`),
R19 (stab-parens meta attribution).

**P5 — fuzzer token soup, completeness only:** K2 (`%&1{}`/`%..{}`), R20 (`+//2`),
F2 (`foo.//1` dot-context operator split), F7 (`fn x -> ; end`), the `%+&f/1{}`-style
struct-base soup, and the 14 catalogued FUZZER_GAPS residuals.

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

---------------------------------------------------------------------------

## OX audit — independent parser/lexer audit (2026-08-23)

Scope: full review of `lib/toxic2/lexer.ex`, `parser.ex`, `lower.ex`, `precedence.ex`,
`tokens.ex` against the reference implementation in `~/elixir/lib/elixir/src`
(`elixir_tokenizer.erl`, `elixir_parser.yrl`, `elixir_interpolation.erl`), Elixir
1.21.0-dev. Every finding below was **verified empirically against the live oracle**
(`Code.string_to_quoted/2` built from `~/elixir`) and against toxic2 itself;
nothing here is speculation from reading alone.

Excluded (already tracked): everything in `GRAMMAR_GAPS.md` (§1–§4, F1–F7) and
`test/toxic2/FUZZER_GAPS.md` (V1–V4 and the corpus buckets). Items below were
checked against both documents and are new.

Candidates investigated and found CORRECT (no finding, recorded so they aren't
re-litigated):

- `a | b` as a general infix operator (`pipe_op`, Right 70) — valid upstream
  (typespec unions); toxic2's table matches. `|>` correctly maps to `arrow_op`.
- Prefix `..` is nullary-only upstream (`..5` is a syntax error); toxic2 agrees.
- Keyword tails in bitstrings/tuples (`<<1, a: 2>>`, `{1, a: 1}` => `[…, [a: 2]]`)
  are valid upstream (`container_args -> container_args_base ',' kw_data`);
  only the ALL-keyword lead is rejected, which `check_container_lead` does.
- Expression-level `when` with a bare keyword RHS (`x = y when a: 1`) and bare
  fn-head keyword guards (`fn a when c: 1 -> 2 end`) are BOTH valid upstream;
  toxic2's `when_kw_rhs` admissions match. (F4 remains specific to the
  parenthesised head form.)
- Consecutive newlines collapse into ONE merged `eol` token upstream
  (`eol/3` counts into the previous `,`/`;`/eol token), so multi-blank-line gaps
  (`%Foo\n\n{}`, `[1,\n\n2]`) are grammatical upstream; toxic2's coalescing and
  single-`skip_eols` usage match. No over/under-acceptance family exists there.
- Sigil delimiter set (`/ < " ' [ ( { |`), modifier charset, name rules,
  heredoc `indentation:` arithmetic — all match `tokenize_sigil*`.
- Heredoc blank lines (empty or over-indented) produce no outdent warning on
  either side; `outdented_notice`'s exemptions hold for the probed shapes.
- `(1)` / `({1})` under `literal_encoder` — `parens:` meta placement and key
  order match the oracle exactly.
- `fn -> 1 end.x` and paren-wrapped do-blocks followed by `.member` — valid
  upstream, identical AST on both sides.
- Operator/identifier keyword keys, `foo:`-at-EOF, `\v`/`\f` after a key colon,
  bare CR/VT/FF/backslash in code, `f(+:)`, `%{}` space rule, uppercase-sigil
  alias rejection, quoted-call warnings — all agree (error-status level).
- Number splits (`1e3`, `1.5e_3`, `0b12`, trailing `1_`) diverge only in
  diagnostic code, never in error status; tolerated per design.

---------------------------------------------------------------------------

## OX1. MISSED ERROR + WRONG AST — a second `->` on a clause's body line
        silently starts a new clause

    fn x -> y -> z end
    case x do 1 -> 2 -> 3 end
    cond do true -> 1 -> 2 end
    receive do msg -> msg -> :other end

Oracle: `syntax error before: '->'` (all four). There is no production that
continues a completed `stab_expr` with another arrow.

Toxic2: **zero `:error` diagnostics**; the input splits into multiple clauses
with a misleading `empty_stab_clause` WARNING at the FIRST `->`:

    fn x -> y -> z end
    => clauses [{x} -> nil] ++ [{y} -> z]     # note the phantom empty-body clause

`fn x -> y -> z -> w end` yields three clauses plus two phantom warnings. The
AST is structurally wrong, not just under-diagnosed.

Root cause: `parser.ex` `clause_head_ahead?/5` unconditionally reports
`true` for a depth-0 `:stab_op` ("k == :stab_op -> true"), so after a body
statement completes on the same line, `parse_clause_body` ends the body at the
second `->` and `parse_clauses`/`parse_block_clauses` happily parse a
zero-pattern clause from it without any recovery diagnostic. Newline-separated
clause lists are unaffected (the `:eol` boundary wins), which is why the OSS
corpus never trips this; it takes a doubled `->` on one line — a classic
mid-edit typo. Any fix must keep multi-line heads working
(`n when is_number(n)\n-> …`) while requiring an EOE boundary (or a genuinely
incomplete head per `head_expects_more?`) before a same-line second arrow.

Severity: high for an editor/LSP consumer — a real typo class produces a clean
looking tree and a warning about the wrong thing.

## OX2. MISSED ERROR — uppercase radix prefixes `0X` / `0O` / `0B` accepted

    0XFF   => 255, no diagnostics      (oracle: lexer error "invalid character \"X\" after number 0")
    0O17   => 15                       (same)
    0B101  => 5                        (same)
    x = 0XFF + 1                      (parses cleanly)

Upstream handles only lowercase `x`/`o`/`b` radix prefixes; an uppercase letter
after a number hits the hard "invalid character ... after number" error in
`elixir_tokenizer.erl` (the post-`tokenize_number` letter check — note its
cursor-completion exception covers only lowercase `$x/$o/$b`). Toxic2's
`Lexer.radix/1` accepts `[?x, ?X, ?o, ?O, ?b, ?B]`.

Fix: reject the uppercase forms in the radix clause (emit the number error for
the `0` + letter run, mirroring upstream's "invalid character" class).
Real-code likelihood: low but nonzero (C-hex habit `0xFF` vs `0XFF` typos);
strict-diagnostics impact is clear-cut.

## OX3. MISSED ERROR — bare/update map entries rooted at the fused `not in`

    %{a not in b}       # toxic2: clean {:%{}, [], [not(a in b)]}, NO diagnostics
    %{m | a not in b}   # update entries too
    # oracle: syntax error before: b

The FUZZER_GAPS V2 fix (`check_bare_map_entry`/`map_base_entry?`) rejects
entries rooted at `:binary_op`, `:np_call`, capture-op unary chains, and
do-block calls — but the two-token `not in` comparison lowers through its own
CST kind `:not_in_op`, which falls into the catch-all "allowed" clause of
`map_base_entry?/2`. Every neighbouring shape IS caught (`%{+/2}`,
`%{not a in b}`, `%{&1 in &2}` all emit `:invalid_map_entry`), so this is a
one-kind hole in an otherwise complete grouped rule. Fix: add `:not_in_op` to
the rejected roots in `map_base_entry?/2` (both the bare-entry and update-entry
paths flow through the same predicate).

## OX4. INVALID METADATA — columns drift right after a multi-byte escape
        sequence inside strings / charlists / heredocs

    s = "a\é" ; x
    # oracle: x anchored at column 13
    # toxic2: identifier x @ 1:14  (everything after the escape shifted +1)

    "\u{1F600}" ; y   # ASCII-only escape: both sides agree (y @ 14) — control case

`Lexer.decode_escape/3` advances the column by
`1 + byte_size(consumed)` (`col + 1 + (byte_size(rest) - byte_size(rest2))`).
For escapes decoded through `esc(<<e::utf8, rest>>)` (any unknown-escape
codepoint kept literally — `"\é"`, `"\日"`, …) the consumed length is counted in
BYTES, so each multi-byte codepoint inflates the cursor by `bytes - 1` extra
columns. The drift applies to:

- every token AFTER the string on that line (verified: `;` at 12 vs 11, `x`
  at 14 vs 13),
- the enclosing fragment token's own end span, hence `closing:` /
  `end_of_expression:` / `newlines:` computations in lowering that read source
  positions off those spans (`scan_eoe`, `gap_newlines`, delimiter scans),
- charlists and heredocs, which share `decode_escape` via `read_heredoc`.

Not affected: `read_quoted`'s plain-codepoint path (+1 per codepoint, correct),
comments (`cp_width`), and `read_sigil`'s `\<char>` handling (+2, correct even
for multi-byte chars — the sigil path counts codepoints).

Fix: advance by the CODEPOINT width of the consumed slice (e.g. reuse the
existing `cp_width/2`) instead of the byte size, in `decode_escape`'s
`:sameline` branch. Real-code likelihood: low-moderate — requires a non-ASCII
character written as a literal escape in a string, but the corruption is silent
and poisons all downstream metadata consumers (formatter-grade ranges, semantic
token positions) for the rest of the physical line.

---------------------------------------------------------------------------

## Priority summary

| # | Finding | Class | Suggested order |
|---|---------|-------|-----------------|
| OX1 | doubled `->` splits clauses silently | missed error + wrong AST | 1 |
| OX4 | column drift after multi-byte escapes | invalid spans/metadata | 2 |
| OX2 | `0X`/`0O`/`0B` radix prefixes | missed error | 3 |
| OX3 | `not in`-rooted bare map entries | missed error | 4 |

Method note: probes were run in default and `token_metadata: true` +
`columns: true` + identical `literal_encoder` modes; oracle invocations used the
unmodified `~/elixir/bin/elixir`. No crashes were observed in either
implementation across the probe set.

---------------------------------------------------------------------------

## KIMI audit — independent parser/lexer/lowerer audit (2026-08-24)

Scope: `lib/toxic2/lexer.ex`, `parser.ex`, `lower.ex` vs the reference in
`~/elixir/lib/elixir/src` (`elixir_tokenizer.erl`, `elixir_parser.yrl` grammar +
Erlang helpers, `elixir_interpolation.erl`), Elixir 1.21.0-dev (commit
`30af9521c`, built and used as the live oracle).

**Method.** Rule-by-rule review of both sides, then every candidate was probed
against the **live oracle** (`Code.string_to_quoted/2` from `~/elixir`) and
toxic2 (`Toxic2.parse_to_ast/2`) in BOTH modes: default and
`token_metadata: true, columns: true` with an identical `literal_encoder`.
Every finding below reproduced empirically; nothing is inferred from reading
alone. ~350 probe inputs were run; agreements are not listed.

**Excluded (already tracked):** everything in `GRAMMAR_GAPS.md` (§1–§4, F1–F7),
the OX audit above (OX1–OX4), and `test/toxic2/FUZZER_GAPS.md` (V1–V4, the
corpus buckets, the three catalogued missed-warning families). Notably the OX
"%-soup" bucket (`%...{}`, `%fn -> 1 end{}`) is treated as tracked — but two
**additional** struct-base kinds from the same grammar rule are NOT mentioned
there and are §K2 below.

Candidates investigated and found CORRECT (recorded so they aren't
re-litigated): `a[1](2)`, `Foo(2)`, `a.\nb: c` (all error on both sides);
`^(a -> b)`; `% (){}` / `% [1]{}` spaced paren/list struct bases; `%a..b{}`;
interpolation node anchors with inner whitespace (`"a#{  b  }c"`); heredoc-sigil
`indentation:` with modifiers (`~r'''\nab\n'''xyz`); `(Foo).Bar` `last:`; `f do
a end |> g`-family postfix on do-blocks; `fn a when b: 1, c -> d end` (guarded +
extra arg IS the valid `unwrap_when` shape); `f a, do: b -> c` and every
do-block stab-keyword variant probed; `with`/`for`/`try`/`receive`/`cond` block
lists (50+ shapes); operator adjacency matrix (`a -1`/`a - 1`/`a--b`/`a**b`
…); `:<<"`-style op atoms; `&f/01`, `&f/x` error parity; quoted kw keys;
`1._5`; `%{%{} | a: 1}`; mixed assoc/kw map-update error parity.

---------------------------------------------------------------------------

## A. FALSE ERRORS on valid code (worst class)

### K1. `unwrap_when` missing — a comma after a `when` guard in an
        unparenthesised stab head is a FALSE ERROR

    fn a when b, c -> d end
    # oracle: fn with ONE clause, head args [when(a, b), c]
    #   {:fn, _, [{:->, _, [[{:when, _, [a, b]}, {:c, _, nil}], d]}]}
    # toxic2: :expected_stab + :unexpected_token(",") + :expected_stab

Upstream, an unparenthesised stab head is `call_args_no_parens_all`, so
`a when b, c` parses as two args `[when(a, b), c]`; `unwrap_when/1`
(yrl:1152-1158) then lifts the LEADING `when`'s args into
`{:when, meta, [a, b]}` kept as the first arg. Toxic2 instead treats the
post-`when` comma as a clause separator and fails to find `->`.

Confirmed embodiments (all FALSE ERRORS on valid code):

    fn a when b, c -> d end
    fn a when b, c, d -> e end
    fn a when f(b), c -> d end
    fn a, b when c, d -> e end        # guard attaches to LAST pattern (b)
    fn a when b when c, d -> e end    # nested when inside the guard itself
    fn a when b, c when d, e -> f end # two guard segments
    fn a when b, c: 1 -> d end        # trailing keyword guard arg
    fn (a) when b, c -> d end         # single PARENTHESISED pattern + extras
    fn (a when b, c) -> d end         # guard+extra inside stab parens
    case x do a when b, c -> d end
    cond do a when b, c -> d end
    receive do a when b, c -> d end
    try do x rescue e when b, c -> d end
    try do x catch k, v when g, h -> i end
    for a <- b, reduce: 0 do acc when g, h -> acc end
    (a when b, c -> d)                # paren-stab, unparenthesised args

The grammar root: a stab head is `call_args_no_parens_all` (or, for
parenthesised heads, `call_args_no_parens_many`), so a comma-separated guard
sequence `a when b, c` is simply two args `[when(a, b), c]`; the yrl's
`unwrap_when/1` (yrl:1152-1158) then lifts the leading `when` in-place so the
guard node keeps the last pre-`when` pattern as its first arg. Toxic2 treats
any comma after a `when` segment as "next clause" and fails to find `->`.

Controls that already work: `fn (a, b) when c -> d end` (guard with no
following comma), `fn (a, b) when c, d -> e end` — INVALID on BOTH sides
(`stab_parens_many when_op expr` admits no comma in the guard; status parity,
different recovery), `f(a when b, c -> d)` / `[a when b, c -> d]` (stab in
call/list args works), `fn a when b: 1, c -> d end` (keyword guard + extra
arg), `fn a, b when c -> d end` (no comma after guard).

Any fix must reproduce BOTH the `unwrap_when` lift and the
trailing-args-after-guard-segment behavior, across both the no-parens head
path and the `stab_parens_many` path (the `(a) when b, c` and
`(a when b, c)` variants).

Real-code likelihood: medium. Multi-pattern heads with guards almost always
put the guard last, so this is rare — but it is ordinary valid syntax,
reachable by anyone who writes `fn x when is_integer(x), y -> … end` style
"guard then more patterns" or refactors a guard to the middle of a head.

### K2. Two more struct-base kinds rejected (the OX "%-soup" bucket is
        under-specified): `%&1{}` and `%..{}`

GRAMMAR_GAPS.md lists `%...{}` and `%fn -> 1 end{}` as catalogued fuzzer-soup.
The same probe shows the bucket is TWO kinds wider:

    %&1{}          # oracle: {:%, _, [{:&, _, [1]}, {:%{}, _, []}]}
                   # toxic2: :expected_map_or_struct + 2× :unexpected_token
    %..{}          # oracle: {:%, _, [{:.., _, []}, {:%{}, _, []}]}
                   # toxic2: :expected_map_or_struct (then a binary `..` node
                   #         with an __error__ lhs and {:{}, [], []} rhs)

Upstream `map_base_expr` admits `capture_int` (via `access_expr`) and
nullary `..` (`ellipsis_op`/range nullary). Toxic2's `struct_base_start?`
(parser.ex ~1870) omits both `:capture_int` and `:range_op` (it has
`:ellipsis_op` but not `:range_op`, hence `%...{}` and `%..{}` fail through
DIFFERENT diagnostics). `%..5{}` (range with rhs) already works, which makes
the nullary omission look accidental. `% &1{}` (spaced) fails identically.

Fix shape: add `:capture_int` and `:range_op` to `struct_base_start?` (the
expression parser already handles both as primaries).

Real-code likelihood: very low (soup-class), but these are *valid* inputs and
the fix is the same one-liner family as the already-tracked V4/`%//x{}`.

### K3. `?\é` — `?\` followed by a non-ASCII codepoint is rejected as
        :invalid_byte (also wrong value + column drift)

    ?\é     # oracle: 233 (é), no diagnostics
            # toxic2: :invalid_byte error, value 195 (first byte of UTF-8 é),
            #         and the second byte is parsed as a separate char token —
            #         `?\é + 1` loses the `+ 1` entirely (wrapped in a block
            #         with the trailing byte), `?\é ; x` shifts x's column +1

`lexer.ex ~457`: the `?\<e>` escape clause matches `e` as a BYTE
(`<<??, ?\\, e, rest::binary>>`), unlike the plain `?<cp>` clause right below
it which matches `cp::utf8`. Upstream (`elixir_tokenizer.erl` tokenize_char /
`elixir_interpolation.erl` `escape/1`…`esc/1`) decodes `\<c>` as "c itself"
for any non-special char, codepoint-wise. `?\é`, `?\日` are the natural
embodiments (`?\e`/`?\a` ASCII escapes already work).

Fix: match `e::utf8` in that clause and advance the column by 2 (the `\` plus
one codepoint) instead of `col + 3` bytes… note the current span math
(`col + 3`) is also only right for 1-byte escapes, so the end column for
`?\é` is wrong even before the value error.

Real-code likelihood: low (writing `?\é` instead of `?é` is unusual), but
this is valid code that both errors AND corrupts the rest of the line.

---------------------------------------------------------------------------

## B. MISSED ERRORS (invalid code silently accepted, wrong AST built)

### K4. Do-block calls accepted as stab clause heads / patterns

    fn if x do y end -> z end            # oracle: syntax error before: '->'
    case x do if y do z end -> w end     # oracle: syntax error before: '->'
    receive do a after foo do b end -> c end
    fn foo a, b do c end -> d end        # no-parens-many head with do-block
    # toxic2: parses cleanly, e.g. first case becomes
    #   fn (if x do y end) -> z  — a clause whose PATTERN is an if-block

Upstream derives stab heads only from `expr`/`call_args_no_parens_all`/
`stab_parens_many`; a `block_expr` (do-block call) is unmatched-only and can
never be a head element, so the `->` after `end` is rejected. Toxic2's
`parse_clause_head` runs the general expression parser, which happily attaches
do-blocks (`maybe_do_block`) to head "patterns"; `clause_head_ahead?` then
scans past `end` to the `->`. No diagnostic of any kind is emitted.

Real-code likelihood: low-to-medium — this is a plausible mid-edit state
(wrapping a clause body expression in `if … do … end` before the arrow is in
place), and it silently produces a well-formed-looking but nonsensical tree.

### K5. Do-block calls accepted as struct bases: `%<do-block>{}`

    %if a do b end{}      # oracle: syntax error before: do
    %case a do b -> b end{}
    %x do y end{}
    %f a do b end{}
    # toxic2: {:%, _, [if-block, %{…}]} with NO diagnostics

Same grammar root as K4 (`map_base_expr` has no block member), separate code
path: `struct_base_start?` admits `:identifier`/`:fn`-less call starts and the
struct-name expression parser attaches a do-block to the base. This is the
*mirror image* of the already-tracked `%fn -> 1 end{}` false error — here
toxic2 is too LENIENT on the same `%<base>{}` production. Any fix should
reject do-block attachment while parsing the struct base (but keep
`map_base_expr`'s matched operands like `%f(x){}`, `%x.y{}`).

### K6. `when` with a keyword guard in a non-first no-parens call argument:
        `f a, b when c: d` — silent, no `:ambiguous_no_parens`

    f a, b when c: d
    f a,\nb when c: d
    # oracle: "unexpected comma. Parentheses are required to solve ambiguity
    #          in nested calls." (error)
    # toxic2: f(a, when(b, c: d)) with ZERO diagnostics

Upstream: the second arg forces `no_parens_expr` in a non-first position,
whose `when_op_eol call_args_no_parens_kw` form hits
`error_no_parens_many_strict`. This is a hole in the V3 `rightmost_operand`
descent (GRAMMAR_GAPS "Fixed" §6): the strict check follows the rightmost
operand of operator chains but a `when`-rooted binary op whose rightmost
operand is a plain keyword-guard call slips through. Note the FUZZER_GAPS
missed-warning bucket only covers the *warning* side of `when`-with-kw as a
kw VALUE (`a foo: x when y: z`); this one is a missed ERROR at argument
position.

Real-code likelihood: low-medium — `assert x, y when z: w`-ish shapes are
conceivable while drafting guards into `assert` calls.

### K7. `fn a: 1, b -> c end` — keyword-then-positional in an
        unparenthesised stab head is silently accepted

    fn a: 1, b -> c end       # oracle: "unexpected expression after keyword
    fn a: 1, b, c -> d end    #          list… must always come as the last
    fn a, b: 1, c -> d end    #          argument" (error)
    fn a: 1, b: 2, c -> d end
    fn x, a: 1, b -> c end
    (a: 1, b -> c)            # paren-stab variant
    case x do a: 1, b -> c end
    # toxic2: clean fn/case ASTs with kw pairs mixed before positionals,
    #         ZERO diagnostics

Upstream `call_args_no_parens_many` requires a keyword run to be LAST; the
strictness is enforced for calls (`f(a: 1, b)` errors on both sides) but
toxic2's clause-head path skips the `keyword_not_last`/last-kw check.
Controls: `fn a: 1 -> b end`, `fn a, b: 2 -> c end` (kw run last — valid
both sides), `fn a when b: 1, c -> d end` (guard kw then arg — valid, see
K1). Note the parenthesised-head form `fn (a: 1, b) -> c end` is rejected by
the oracle for a different reason and by toxic2 too (not this gap).

Real-code likelihood: low (kw in fn heads is macro-DSL territory), medium for
an editor showing a half-typed head.

### K8. Newline-then-comma after a trailing COMMENT: `%{a: 1 # ,\n, b: 2}`

    %{a: 1 # ,
    , b: 2}
    [1 # ,
    , 2]
    # oracle: syntax error before: ',' (line 2) for both
    # toxic2: %{a: 1, b: 2} / [1, 2] with NO diagnostics

GRAMMAR_GAPS F3 tracks the newline-before-comma missed-error family
(`[1\n, 2]`, `%{a: 1\n, b: 2}`, …). What F3 does not record is that the
comment-interleaved variant is also accepted — i.e. toxic2's comma scan skips
over eol AND comment tokens alike, so the fix for F3 must be comment-aware,
not just "stop at eol". (Verified the pure-eol forms are still missed too;
the comment form is the new datum.) `f(1 # )\n)` (comment before close) is
fine on both sides.

Real-code likelihood: low, same as F3 (mid-edit comma-last style), but it
pins down the shape of the eventual F3 fix.

---------------------------------------------------------------------------

## C. Metadata fidelity (token_metadata mode, or `columns: true`)

### K9. Deprecated `not x in y` / `!x in y`: the rewritten node's meta is
        dropped unless `token_metadata: true`

    not a in b
    # oracle (columns: true, NO token_metadata):
    #   {:not, [line: 1, column: 1],
    #    [{:in, [line: 1, column: 7], [a, b]}]}
    # toxic2 (columns: true): {:not, [], [{:in, [], [a, b]}]}

Upstream `build_op`'s `rearrange_uop` clause (yrl:749-756) keeps the `not`/`!`
token meta and the `in` location UNCONDITIONALLY (line always, column when
`columns: true`). Toxic2's `lower_deprecated_not_in` (lower.ex:1925-1927)
gates both metas on `tm?(opts)` — `[]` in default/columns-only mode, unlike
every neighbouring lowering (`lower_unary`, `lower_binary` use `op_meta`
unconditionally). The deprecation warning itself IS emitted (agrees); only
the node anchors diverge.

### K10. Fused `not in` after a newline/comment: missing `newlines:` and a
         comment-poisoned anchor

    x
    not in y
    # oracle: {:not, [newlines: 1, line: 2, column: 1], [{:in, …}]}
    # toxic2: {:not, [line: 2, column: 1], [{:in, …}]}        (no newlines:)

    a # not
    not in b
    # oracle: not anchored at line 2 col 1 (the real `not`), newlines: 1
    # toxic2: not anchored at LINE 1 COL 5 — the word "not" inside the COMMENT

Two bugs in `not_in_meta` (lower.ex:2763-2774): (1) it never computes the
`newlines:` count that upstream derives from the tokenizer's fused-token
`previous_was_eol` (yrl:758-761 — `NotMeta = newlines_op(…) ++ …`; a newline
BEFORE `not` is allowed and recorded); (2) `scan_op("not")` does a plain
`:binary.match` forward from the lhs end, so a comment containing the literal
word `not` (also `in`, and plausibly `when`/`->` scans with comment-borne
words) hijacks the anchor. Default-mode AST shape is unaffected.

### K11. `fn\n-> 1 end` — zero-pattern head on a later line: `newlines:` lands
         on `fn` instead of `->`

    fn
    -> 1
    end
    # oracle: fn meta [closing: …, line: 1, column: 1]   (no newlines:)
    #         -> meta [newlines: 1, line: 2, column: 1]
    # toxic2: fn meta [newlines: 1, closing: …, line: 1, column: 1]
    #         -> meta [line: 2, column: 1]               (no newlines:)

Also: `fn # c\n-> 1 end` (comment between), `fn\n\n-> 1 end`
(`newlines: 2`), `a = fn\n-> 1\nend`, `f(fn\n-> 1\nend)`. Upstream attaches
the eol to the stab arrow (`stab_op_eol`); toxic2 attaches it to the `fn`
keyword. Controls that already agree: `fn x\n-> 1 end`, `fn ()\n-> 1 end`,
`fn x ->\n1 end` — the divergence is specific to the EMPTY head scanning
forward past eol/comments to the `->`.

### K12. `:true` / `:false` / `:nil` under `literal_encoder` miss
         `format: :atom`

    :true
    # oracle (token_metadata + columns + encoder):
    #   {:__lit__, [format: :atom, line: 1, column: 1], [true]}
    # toxic2: {:__lit__, [line: 1, column: 1], [true]}

Upstream routes the colon-atom of the boolean/nil literals through
`handle_literal(…, atom_colon_meta(Token))` where `atom_colon_meta` adds
`format: :atom` for exactly `true`/`false`/`nil` (yrl:296, 1049-1052). Toxic2
lowers `:atom` tokens uniformly without it (lower.ex:434-446). Also fires in
kw-value position (`[k: :true]`). Bare `true`/`false`/`nil` (no colon) match.

### K13. `nested_no_parens_keyword` warning fires under `literal_encoder`
         where upstream deliberately skips it

    f k: bar a, b
    f a, k: bar a, b
    x = f k: bar a, b
    [f a: g b, c]
    f a: g b, c
    # oracle (default):         warns nested_no_parens_keyword  — both agree
    # oracle WITH an encoder:   NO warning — warn_nested_no_parens_keyword has
    #   a catch-all clause "Key might not be an atom when using
    #   literal_encoder, we just skip the warning" (yrl:1328-1330); the
    #   encoded key is a 3-tuple, not an atom, so the guard fails
    # toxic2 WITH an encoder:   still warns — `maybe_nested_no_parens_warn`
    #   (lower.ex:2278-2304) inspects the CST before lowering, so encoding
    #   never suppresses it

An extra warning under `literal_encoder` — exactly the mode formatter-grade
tooling uses.

### K14. `fn a # ->\n -> 1 end` — comment containing "->" before the real
         arrow hijacks the `->` anchor

    fn a # ->
     -> 1 end
    # oracle: {:->, [newlines: 1, line: 2, column: 2], [[a], 1]}
    # toxic2: {:->, [newlines: 1, line: 1, column: 8], …}  (inside comment!)

The `->` scan from the head's end position is comment-unaware and matches the
arrow inside the comment text (`newlines:` count is right; only the anchor is
wrong). `fn a # c\n -> 1 end` (comment without "->") agrees. Same hazard
class as K10's `scan_op`; a token-driven scan instead of `:binary.match` over
raw source would fix both.

### K15. Outdented heredoc warnings: toxic2 warns once PER outdented line;
         upstream warns once per heredoc

    """
      a
     b
     c
      """
    # oracle: ONE warning, reported at {first_outdented_line, 1}…
    #   actually {line 3, column 1} — "The current heredoc line is indented
    #   too little" nofile:3:1
    # toxic2: TWO :outdented_heredoc warnings, at {3, 1} and {4, 1}

Upstream collects `Outdented` lines but warns once (the last notice wins /
only one is emitted; `elixir_tokenizer.erl` heredoc finish path). Warning
COUNT parity matters to the diagnostics-conformance harness. (Positions of
the surviving warning happen to coincide here.)

---------------------------------------------------------------------------

## Priority summary

| # | Finding | Class | Suggested order |
|---|---------|-------|-----------------|
| K1 | `unwrap_when` guard-comma false errors (14+ shapes) | false error | 1 |
| K4 | do-block calls as clause heads | missed error + wrong AST | 2 |
| K5 | `%<do-block>{}` struct bases | missed error | 3 |
| K7 | kw-then-positional in unparenthesised fn/case heads | missed error | 4 |
| K6 | `f a, b when c: d` ambiguous-comma hole | missed error | 5 |
| K3 | `?\é` escaped non-ASCII char literal | false error + wrong value | 6 |
| K2 | `%&1{}` / `%..{}` struct bases | false error (soup-class) | 7 |
| K8 | comment + newline-comma | missed error (mid-edit) | 8 |
| K9–K15 | metadata / warning parity | token_metadata consumers | 9 |

Method note: probes ran in default and `token_metadata: true, columns: true` +
identical `literal_encoder` modes; oracle invocations used the unmodified
`~/elixir/bin/elixir`. No crashes in either implementation across ~350 probe
inputs. Harness left at
`/var/folders/5t/z9kkxlhn4w769jqmn00xqqkw0000gn/T/opencode/kimi_probe.exs`
(ephemeral).

---------------------------------------------------------------------------

## GPT review — parser and lexer audit (2026-09-05, R1–R20)

**The implementation is not grammar-complete.** This review confirmed 20 additional finding
groups beyond the entries earlier in this file and in `test/toxic2/FUZZER_GAPS.md`.
Eighteen affect acceptance or AST structure; two are metadata-only. Some are obscure grammar
edges, but spaced access, heredoc contents, keyword names, and incorrect keyword ownership
are useful cases to fix independently of the older fuzzer backlog.

No implementation fixes were made. The reduced, report-only reproducer is
[`grammar_review_20260905.exs`](grammar_review_20260905.exs). It includes controls, runs both
structural and full token-metadata comparisons, and prints differences. Add `--details` to see
the actual oracle result, Toxic2 AST, and diagnostics for each difference:

```sh
MIX_OS_CONCURRENCY_LOCK=0 PATH=~/elixir/bin:$PATH mix run grammar_review_20260905.exs --details
```

`MIX_OS_CONCURRENCY_LOCK=0` was needed because this review environment prevents Mix's TCP lock.
The parser oracle is the Elixir executable built from the requested checkout, not the default
asdf executable.

### Scope and evidence

- Toxic2 commit: `535c3f084c730fe087479e046ae4c7760f2e20a9`.
- Reference: `~/elixir`, commit `2e9ce85e91c8beef41dc0826c6666a44e6fa6913`, Elixir 1.21.0-dev,
  OTP 28. Compared `elixir_parser.yrl`, `elixir_tokenizer.erl`, and `elixir_interpolation.erl`
  with the lexer, parser, precedence table, token view, and lowerer.
- Default tests: **1,057 passed, 2 excluded**.
- Imported parser gate: **7,510 frozen cases preserved**; overall 7,584/7,615 green, 31 backlog.
- Imported lexer gate: **774/774 green**.
- Additional probes: 14,401 generated grammar combinations; 571 selected full-metadata
  comparisons; separate targeted batches of 680 lexer cases, 257 boundary/attribute cases,
  213 capture/ellipsis/operator/control-character cases, 56 remote-call cases, and 60
  operator/slash cases. These batches overlap. Mismatch counts include known gaps and are
  not counts of independent bugs.
- No Toxic2 crash occurred in the completed differential batches. Structural comparisons
  recursively remove metadata; metadata comparisons use identical `columns: true`,
  `token_metadata: true`, and literal encoders. Warning-count parity was not exhaustively tested.
- Saved reduced harness: **82 source cases / 164 comparisons**: 30 false-error comparisons,
  30 wrong-AST comparisons, 48 missed-error comparisons, 6 metadata differences, and 50
  agreements. This deliberately concentrates failures, includes the K6 extension, and includes
  22 controls that agree in both modes; it is not a representative error rate.

The major production families and operator precedences are present. The uncovered problems
are chiefly restrictions and interactions between those families, lexical context, and AST
construction. A passing finite corpus does not establish that every production combination
or recovery edge is correct. "Valid" below means accepted by Elixir's parser; it does not
claim that every macro-oriented or unusual expression passes expansion or evaluation.

### Findings

#### R1 — P2: Access wrongly requires adjacency for every base

**Repros:** `f() [0]`, `(x) [0]`, `Foo [0]`, `%{} [0]`, `a.b() [0]`.

Upstream parses these as `Access.get(base, 0)`. Toxic2 rejects most; for `a.b() [0]` it silently
produces `a.b([0])`. Tabs and continued lines show the same problem. Ordinary newlines are
expression boundaries and must not simply be skipped to fix this.

`parser.ex:725-726`, `access?/3`, requires the CST to end exactly where `[` starts. That rule is
appropriate to the tokenizer's `bracket_identifier` distinction (`f [0]` is a call), but not to
the separate `bracket_expr -> access_expr bracket_arg` production (`yrl:313`).
The converse restriction is also missing: `..[0]` is accepted although a bare nullary range
is not an `access_expr`; `(..)[0]` is legal. Access needs the grammar's base classification.

#### R2 — P2: An empty parenthesized remote call can be called again without parentheses

**Repros:** `a.b() 1`, `a.b() x: 1`, `a."b"() x`.

Elixir rejects these. Toxic2 emits no error and changes them into `a.b(1)`, `a.b(x: 1)`, and
`a.b(x)`. This can hide a missing operator or separator after an already completed call.

`parser.ex:529`, `np_callee?/2`, considers every two-child `:remote_call` a bare callee. The
same shape also represents an explicitly parenthesized zero-argument call, so `()` is lost
when `build_np_call/4` adds arguments. Upstream only allows `dot_identifier`/`dot_op_identifier`
as no-parens callees (`yrl:252-261`), not a completed `parens_call`.
Nonempty calls such as `a.b(1) 2` correctly report an error.

#### R3 — P2: Heredoc indentation scanning changes valid string contents

**Minimal raw-sigil repro:**

```elixir
~S"""
  #{
  """
```

Upstream's sigil content is `"\#{\n"`; Toxic2's is `"  \#{\n  "`. It retains both the body
indentation and the closing line's spaces. A raw sigil does not interpolate, but the indentation
pre-scan treats its literal `#{` as an interpolation opener and never finds a depth-zero close.

The same scanner incorrectly counts braces inside quoted strings, sigils, and comments within
a real interpolation. For example:

```elixir
"""
  #{"{"}
  """
```

Upstream's surrounding fragments are `""` and `"\n"`; Toxic2 retains extra spaces. This changes
the value, not just indentation metadata or warning counts.

Root: `lexer.ex:1871-1872`, `heredoc_start_body/6`, invokes `heredoc_indent/4` without the
interpolation-enabled flag. Its `skip_to_eol/3` helper (`lexer.ex:1909-1915`) counts braces
without lexical string/comment state. Upstream extracts interpolation with the tokenizer before
stripping indentation (`elixir_interpolation.erl:60-78` and the heredoc extraction helpers).
This is independent of K15's duplicate outdent warnings.

#### R4 — P2: `not in` loses keyword ownership and bypasses ambiguity checks

**Repro:** `[a not in f x: 1, y: 2]`.

Upstream produces one list element: `not (a in f(x: 1, y: 2))`. Toxic2 produces two:
`not (a in f(x: 1))` and `{:y, 2}`, with no error. Map values and keyword values have the same
ownership problem. Separately, `f 0, a not in f b, c` and `[a not in f b, c]` are rejected
upstream for ambiguous commas, but accepted by Toxic2.

`parser.ex:361-367`, `rightmost_operand/1`, descends `:binary_op` and `:unary_op` only.
The dedicated `:not_in_op` built at `parser.ex:1041` is opaque to both keyword-run absorption
and strictness checks. The rewrite helpers used when appending absorbed keywords need the
same support. This is distinct from OX3 (bare map entry admission), K10 (metadata), and K6
(`when` keyword guards). Ordinary `in` passes the corresponding controls.

#### R5 — P2: Legal unquoted keyword names are rejected by ASCII fast paths

**Repros:** `[foo@bar: 1]`, `[Foo!: 1]`, `[Foo?: 1]`.

All are accepted upstream and produce ordinary atom keys. Toxic2 emits errors. The lowercase
scanner's `read_name/1` stops before `@`; the uppercase scanner uses `word_len/2`, stopping
before `!`/`?`. They therefore never see the keyword colon attached to the complete name.

Root: `lexer.ex:661-688`, the ASCII identifier/alias clauses, and `read_name/1` at line
1962. Upstream reads the whole identifier and checks for a keyword suffix before rejecting
`@` or invalid alias characters (`elixir_tokenizer.erl:688-715`). Quoted equivalents work.

#### R6 — P2: Malformed braced Unicode escapes are silently accepted

**Repros:** `"\u{41"`, `"\u{41x}"`, `"\u{0000041}"`.

Elixir rejects all three. Toxic2 returns `"A"`, `"Ax}"`, and `"A"`, respectively, with no
error. Quoted atoms, keyword keys, remote names, charlists, and ordinary heredocs share the bug.

`lexer.ex:1368-1374`, `esc/1`, consumes any nonempty hex run and calls `drop_rbrace/1`, which
does not require a closing brace. It also imposes no digit-count limit. Upstream requires
exactly one to six hex digits followed immediately by `}` (`elixir_interpolation.erl:233-252`).
Valid `"\u{41}"` and out-of-range-codepoint error controls behave correctly.

#### R7 — P2: A backslash bypasses raw forbidden-character validation

Construct a source string as `"\"\\" <> <<0x202E::utf8>> <> "\""`: a quote, a backslash,
the **actual** U+202E character, and a quote. Elixir rejects this; Toxic2 accepts it. Actual
U+2028, VT, FF, and bare CR also demonstrate missed validation in ordinary quoted strings.
Quoted atoms/calls and applicable string/sigil/heredoc readers share variants of the issue.

This is not the textual escape `"\u202E"`, which is intentionally legal on both sides.
`lexer.ex:1127-1132` decodes an escaped codepoint before the normal `bidi?/break?` checks;
`read_sigil/10` has a similar unchecked branch at `lexer.ex:1458-1460`. Upstream routes a
backslash's following character through `extract_char`, preserving validation
(`elixir_interpolation.erl:76-108`). The previously documented raw-character check does not
cover this backslash-prefixed bypass.

#### R8 — P2: Attribute operands omit the second parenthesized argument group

**Repros:** `@f()(1)`, `@f(1)(2)`.

Upstream accepts the nested call as the operand of `@`. Toxic2 parses the first call and reports
the second `(` as unexpected. `parser.ex:2716-2737` uses `maybe_paren_call/6` to consume exactly
one group, unlike the general postfix path. The `parens_call` grammar allows two groups and is
an `access_expr`, so the attribute operand must admit it (`yrl:301-305`).

#### R9 — P2: Repeated attributes put bracket access outside the wrong node

**Repros:** `@@f[x]`, `@@f()[x]`.

Upstream groups the first as `@(Access.get(@f, x))`. Toxic2 groups it as
`Access.get(@(@f), x)`, without diagnostics. The specialized attribute operand path
(`parser.ex:2716-2721`) returns the nested unary node before recognizing the inner
`bracket_at_expr`. This is a missing interaction with the explicit `bracket_at_expr`
productions (`yrl:315-318`), rather than an incorrect numeric precedence-table entry.

#### R10 — P2: Keyword-only no-parens calls are not absorbed in map-key position

**Repro:** `%{f a: 1, b: 2 => 1}`.

Upstream accepts one association, with `f(a: 1, b: 2)` as its key. Toxic2 splits the keyword
run into map entries and emits multiple errors. Unary-wrapped keys have the same problem.

`parser.ex:2149-2153` checks for `=>` immediately after the first partial key expression;
it never calls `absorb_kw_run` for the key. The value side already calls that helper at
`parser.ex:2157`. Upstream permits a matched expression on both sides of `=>`
(`yrl:623-626`). V1's documented fixes explicitly cover values and container elements;
the key position is an additional hole.

#### R11 — P2: Ellipsis consumes a new statement and misreads `not in`

**Repros:** `...\nx`, `... # comment\n[0]`, `... not in x`.

The first two are two expressions upstream, but become a single unary ellipsis in Toxic2.
The third is accepted upstream as nullary `...` followed by the `not in` operator, but Toxic2
tries to parse unary `not` as the ellipsis operand and reports an error.

`parser.ex:2648` skips newlines before deciding whether ellipsis has an operand; the grammar
uses `ellipsis_op matched_expr` with no eol production, unlike ordinary unary operators.
`dotdot_operand?/2` at `parser.ex:2663` also treats every unary-op token as an operand start
without excluding the fused `not in` case. Same-line `... x` and `(...) not in x` are controls.

#### R12 — P2: Signed nullary range arguments become binary arithmetic

**Repros:** `f +..`, `A.f -..`.

Upstream builds `f(+(..))` / `A.f(-(..))`; Toxic2 builds `f + (..)` / `A.f() - (..)` with
no error. The source's whitespace is significant here.

`parser.ex:608-611`, `np_arg_kind?/3`, requires the token after adjacent unary `+`/`-` to be
in `np_first_kind?`, which omits `:range_op`. The range is a valid nullary operand. This is
not the previously fixed operator-reference AST issue: the source contains no `/arity`.

#### R13 — P2: Capture integers use only an unsigned decimal digit run

**Repros:** `&1_0`, `&0x0A`, `&0o12`, `&0b1010`.

Upstream parses all as `{:&, meta, [10]}`. Toxic2 consumes only `&1` or `&0` and reports the
rest as unexpected. Spaced `& 0x0A` works.

`lexer.ex:594-598` uses `take_while(..., is_digit)` instead of the full integer scanner.
Upstream emits `capture_int` and then tokenizes the integer normally
(`elixir_tokenizer.erl:483-500`; `yrl:275`). Consequently the capture token also supports
radix forms and underscores. This concerns parser grammar, not expansion's capture validation.

#### R14 — P2: A final line continuation is accepted as a complete source

**Repros:** the bytes `x`, `\`, LF, EOF; likewise with CRLF.

Upstream reports `invalid escape \\ at end of file`. Toxic2 returns `x` with no error.
The lexer continuation clauses (`lexer.ex:390-394`) also match an empty remaining buffer.
Upstream has explicit terminal `\\\n` and `\\\r\n` error clauses before its ordinary
continuation clauses (`elixir_tokenizer.erl:647-651`). This is relevant to incomplete editor
buffers. A continuation followed by more source, such as `x\\\n+1`, is a passing control.

#### R15 — P2: Some identifiers containing `@` are accepted outside keyword/atom position

**Repros:** `é@bar`, `a.é@bar()`, `not@bar`.

Upstream rejects these as invalid identifiers. Toxic2 accepts the first two as names containing
`@`, and the last as `not (@bar)`. No error is emitted.

`lexer.ex:829-830` discards the vendored identifier tokenizer's `special` flags, including
`:at`, and `emit_unicode_name/9` admits the identifier without checking them. For `not@bar`,
the ASCII scanner stops at `@` and prematurely recognizes `not` as a reserved operator.
Upstream checks `HasAt` after the keyword suffix check (`elixir_tokenizer.erl:690-705`).
The distinction matters: `:é@bar` and `[é@bar: 1]` are valid and must remain accepted.

#### R16 — P2: A unary wrapper incorrectly makes an unmatched do-block eligible for postfixes

**Repros:** `!f do x end.foo`, `!f do x end[0]`, `@f do x end.(1)`.

Elixir rejects the unparenthesized postfix after `end`. Toxic2 emits a clean AST. The equivalent
unwrapped `f do x end.foo` is correctly rejected, making this an admission inconsistency.

`parser.ex:2699-2706` marks the unary node `:matched` even when its operand contains a do-block.
The outer postfix pass then accepts dot/access operations. The grammar keeps
`unary_op_eol unmatched_expr` unmatched (`yrl:167-170`), and dot productions require a matched
left operand (`yrl:478-498`). This is separate from K4's clause-head and K5's struct-base holes.

#### R17 — P2: `unquote_splicing` block construction is not restricted to arity one

**Repros:** `unquote_splicing()`, `unquote_splicing(x, y)`, `unquote_splicing(x) do end`.

Upstream leaves these as ordinary calls. Toxic2 adds a synthetic `__block__` wrapper. The
same problem occurs as the sole expression in parentheses, clause bodies, and do-blocks.
`lower.ex:2751`, `wrap_splice/1`, matches any argument shape; upstream's `build_block`
special case matches exactly one argument (`yrl:802-803`).

There is also a metadata mismatch on the correctly wrapped arity-one case:
`quote do unquote_splicing(x) end`. Upstream puts the `do` location directly on the wrapper;
Toxic2 changes it to `parens: [line: 1, column: 7]`. The block-special case must retain the
section metadata rather than taking the general single-expression metadata path.
These differ from the fixed §2.2, which concerns unwrapping a splice in a clause head.

#### R18 — P2: Grapheme clusters shift source columns even without escapes

**Repro:** source `"é"; x`, where the accent is a separate U+0301 codepoint.

Upstream anchors `x` at column 6; Toxic2 anchors it at column 7. `~s(é); x` similarly gives
8 versus 9. A joined emoji such as `"👩‍💻"; x` demonstrates a larger drift. The literal value
matches, but subsequent source columns and delimiter metadata differ.

`lexer.ex:1188-1203` and the corresponding sigil/heredoc scanners advance by individual
codepoints. Upstream's string extraction uses `unicode_util:gc` and advances once per
grapheme cluster (`elixir_interpolation.erl:93-111`). The fix needs to preserve those lexical
column semantics throughout source slicing, not just adjust one metadata field.
This is independent of OX4: these repros contain no backslash escape.

#### R19 — P2: Parentheses around a single no-parens call are attributed to the clause head

**Repro:** `fn (f a, b) -> 1 end` (also in case/parenthesized stabs).

The structural AST agrees: the clause has one pattern, `f(a, b)`. Upstream puts the `parens`
metadata on that call. Toxic2 strips it from the call and places it on `->` instead.

`parser.ex:1523-1558` treats any depth-one comma inside parentheses followed by an arrow as
`stab_parens_many`. Here the comma belongs to the nested no-parens call; the grammar instead
has a parenthesized expression used as a single pattern. A lexical comma scan cannot decide
this distinction. This is separate from F6: the delimiters are on one line and are found,
but they are assigned to the wrong construct.

#### R20 — P2: Operator-name lookahead fails when the next slash begins `//`

**Repros:** `+//2`, `f +//2`, `%{m | //x}`.

Upstream rejects these; Toxic2 accepts them. The upstream operator handlers inspect the next
source character after horizontal whitespace. When it is `/`, the preceding operator is
emitted as an identifier even if that slash starts the `//` token. The subsequent parse then
rejects a misplaced range step.

`parser.ex:526`, `op_ref_slash?/2`, only recognizes a `:mult_op` slash token, so it misses
`:ternary_op` and instead admits a prefix operator over the unary `//` rewrite. The lexer
emits operators without preserving this reference classification (`lexer.ex:752-755`). See
`elixir_tokenizer.erl:893-947`, `handle_unary_op` / `handle_op`. This is a non-dot lexical
context gap, distinct from F2. These spellings have very low practical likelihood.

### Broader manifestations of tracked findings

- K6 is not confined to a non-first call argument. `[a when b: 1]`, `{a when b: 1}`,
  `<<a when b: 1>>`, `a[a when b: 1]`, and `%{a => a when b: 1}` are also invalid upstream
  and silently accepted. The special `when`-keyword expression needs its proper no-parens
  category in every restricted container/association context. These are not counted again.
- Further struct-base/operator-soup examples, such as `%+&f/1{}`, are admitted where upstream
  rejects them. They reinforce the existing conclusion that struct bases need recursive
  `map_base_expr` validation; they are not counted as a separate new group here.
- F2/F3/F4 and the applicable OX/KIMI families were encountered again. Their existence does not
  explain the independent repros above. Earlier "FIXED" entries should not be interpreted as
  a proof that all adjacent grammar contexts have been covered.

### Suggested repair order

1. Preserve valid source semantics: R1–R4, then R5/R10. Fix R1 and R2 together so restoring
   spaced access does not leave the empty-remote-call admission hole.
2. Restore reliable lexical errors: R6/R7/R14/R15. Preserve valid textual Unicode escapes and
   `@`-bearing atoms/keyword keys as explicit controls.
3. Complete the less common grammar combinations: R8/R9/R11/R12/R13/R16/R17/R20.
4. Restore metadata parity: R18/R19 and R17's arity-one block metadata, alongside the already
   documented metadata backlog.

Regression coverage should assert error **severity**, normalized AST equality for valid inputs,
and full AST equality with an identical literal encoder. Add paired controls that vary only the
relevant whitespace, parentheses, keyword position, or literal mode. The current frozen gates
can remain green while all of these new families still fail.
