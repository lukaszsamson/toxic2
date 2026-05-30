# Toxic 2 — Tolerant-Only Elixir Lexer + Parser (Design Spec & Agent Guide)

This is the canonical design spec for a ground-up rewrite of an Elixir lexer + parser. It is the synthesis of two converged prior specs. Everything below is settled. Implement it as written; do not relitigate the decisions it records.

## Why This Rewrite Exists (the failure being avoided)

The previous attempt (`toxic` + `toxic_parser`, ~44k LOC) tried to satisfy three hostile goals through one tangled mechanism:

1. Byte-exact AST **and error-MESSAGE** parity with Elixir's `yecc` parser.
2. A separate strict error policy.
3. IDE-grade tolerant recovery.

The result was pathological: 535 commits (almost all "fix"), 33/64 property tests still failing, a parser that called `Code.string_to_quoted/2` just to borrow the reference's error strings, a deferral-heavy lexer (`do_identifier` / `op_identifier` / `paren_identifier` rewrites, newline swallowing), and a streaming cursor whose plumbing — not lexing — dominated cost. Every property failure was a collision between the three goals; every local fix regressed another.

This rewrite removes the three root causes:

- **Goal-stacking.** One tolerant mode; strict is a thin wrapper; **never** chase invalid-code error-string or upstream-metadata parity.
- **Lexer/parser coupling via deferrals.** The lexer emits source-ordered tokens only; the parser owns all syntactic repair.
- **A streaming cursor.** Tokenize once into a tuple; the cursor is an integer index; never rewind or re-lex.

---

## Non-Negotiable Principles (P1–P10)

These override local convenience. If a local change appears to require violating one of these, the change is wrong.

- **P1. One parser mode: tolerant.** There is a single combined diagnostic stream (lexer + parser + lowerer diagnostics, in source order). Strict is a thin wrapper (parse + lower once; if the stream contains any diagnostic of severity `:error`, return the first as an error; else return the AST). Diagnostics of severity `:warning` (e.g. the `not in` deprecation) do **NOT** trip strict. **NEVER** branch grammar logic on mode. See [Diagnostics](#diagnostics) for the lifecycle contract.
- **P2. Lexer emits source-ordered tokens only.** No deferrals, no lookbehind token rewrites, no newline swallowing, no parser decisions.
- **P3. Lexer reports lexical errors ONLY as inline `:error` tokens** (no separate diagnostic list); **the PARSER owns all syntactic repair** and is the sole producer of diagnostics from those tokens. Recovery lives in exactly one place.
- **P4. Parser builds a nested green CST**, not the Elixir AST directly.
- **P5. Lowering (CST → AST) is the ONLY place that knows Elixir AST quirks.**
- **P6. Cursor is a token tuple + integer index.** Speculation checkpoint is a saved tuple of scalars. Never rewind/re-lex the lexer.
- **P7. Hot parser/lexer state lives in function arguments, not in structs.**
- **P8. Pratt handles operators ONLY.** Calls, no-parens arg lists, do-blocks, stabs, containers, maps, bitstrings, strings/sigils are recursive-descent grammar routines that CALL Pratt for subexpressions.
- **P9. Expression category** (matched/unmatched/no_parens) **and has-error are computed at node CONSTRUCTION** (OR-ing children); never re-walk a subtree in a hot loop.
- **P10. Valid-code AST parity matters** (compared after metadata normalization). **Invalid-code error-string parity and upstream metadata parity do NOT.**

---

## Architecture Pipeline

```
source binary
  -> batch lexer (Toxic2.Lexer.tokenize/2)
  -> token_tuple
  -> tolerant parser (Toxic2.Parser.parse_tokens/3)
  -> nested green CST + diagnostics
  -> lowerer (Toxic2.Lower.to_ast/3)
  -> Elixir AST (exact for valid code, best-effort for invalid)
```

Two libraries:

- **`toxic2`** — lexer.
- **`toxic2_parser`** — parser + lowerer.

The public API wraps results in a struct **at the boundary ONLY**; hot functions carry plain args.

### CST, not arena (key correction vs the richer GPT draft)

Use a **NESTED green tree** built bottom-up from recursive-descent return values. Do **NOT** use an id-indexed arena, node ids, `next_id` threading, or id→node resolution. Recursive descent builds children before parents, so nesting is natural and needs no arena. Arenas only earn their keep for incremental reparse, which is a non-goal here. Dropping the arena also simplifies speculation (no `next_id` to restore).

---

## Lexer

### Token shape

Flat, no nested span tuple — one fewer allocation per token:

```
{kind, sl, sc, el, ec, value}   # 1-based, end-exclusive positions; value or nil
```

### Token categories

One kind per lexical category. Precedence and role are parser logic, not lexer logic.

**Layout / separators**
- `:eol` (value = newline count), `:";"`, `:","`, `:comment` (only if requested).
- Newlines are **explicit**; operators and commas **never** carry newline counts.

**Delimiters**
- `:"("` `:")"` `:"["` `:"]"` `:"{"` `:"}"` `:"<<"` `:">>"` `:do` `:end` `:fn`.
- Block labels as `:block_label` with value `:else | :catch | :rescue | :after`.

**Identifiers**
- `:identifier`, `:alias`, `:kw_identifier` (`foo:` — purely lexical/forward, **KEEP**), quoted identifier start / fragment / end.
- Do **NOT** emit `:paren_identifier`, `:bracket_identifier`, `:do_identifier`, `:op_identifier`, or quoted variants — adjacency is a parser decision.

**Literals**
- `:int`, `:flt`, `:char`, `:atom`; `true` / `false` / `nil` are `:literal` (value is the
  closed-set atom `true`/`false`/`nil`).

**Value-type rule (no source atom interning).** Source-derived names — `:identifier`, `:alias`,
`:atom`, `:kw_identifier`, and later sigil names — carry **binary** values. Atomization is a
**lowering** concern with an explicit atom policy (`existing_atoms_only`, `static_atoms_encoder`),
so tolerant lexing / fuzzing of untrusted or generated input can never grow the global atom
table. Only **closed-set** lexemes carry atoms: operators (value = the operator atom),
`:literal` (`true`/`false`/`nil`), and `:block_label`. This is load-bearing — atomizing arbitrary
identifiers during lexing is a denial-of-service foundation for an error-tolerant parser.

**Operators**
- PRESERVE the operator **FAMILIES** as kinds because they map to Elixir precedence classes:
  `:unary_op` `:dual_op` `:mult_op` `:power_op` `:concat_op` `:range_op` `:ternary_op` `:xor_op` `:and_op` `:or_op` `:comp_op` `:rel_op` `:arrow_op` `:in_op` `:in_match_op` `:type_op` `:when_op` `:pipe_op` `:assoc_op` `:match_op` `:stab_op` `:at_op` `:capture_op` `:capture_int` `:ellipsis_op` `:dot`.
- Each carries the operator atom as `value`.
- `not in` is lexed as `:unary_op(:not)` then `:in_op(:in)` — **never fused**. Pratt builds a faithful, non-rewritten CST node (see [`not in` below](#elixir-specific-ambiguities-all-parser-side-no-deferrals)); lowering alone emits the canonical AST shape + deprecation warning.
- `foo.()` is `:dot` then `:"("` — dot-call is parser logic.
- (Rejected Claude alternative: a single `:operator` kind + a parser-side precedence table — simpler, but a compile-time-known atom kind in the tuple head enables a jump-table `case` (the dispatch win), and the families reuse the existing Toxic vocabulary and aid precedence-class reuse; **families win**.)

**Strings / heredocs / sigils / interpolation**
- LINEAR + source-ordered: `*_start`, `:string_fragment`, `:begin_interpolation` / `:end_interpolation`, matching `*_end`.
- Heredoc indentation stripping is **lexical** (done by the lexer).
- The lexer may report malformed escapes / unterminated constructs as `:error` tokens but MUST **NOT** synthesize closers.

**Error**
```
{:error, sl, sc, el, ec, %Toxic2.LexError{code, details}}
```
A real token the parser places as an error leaf/node. This token is the **sole transport**
for lexer diagnostics: `Toxic2.Lexer.tokenize/2` returns `{tokens, warnings}` where
`tokens` may contain `:error` tokens but there is **no separate lexer error list**. The
parser converts each `:error` token into exactly one diagnostic (see
[Diagnostics → Lifecycle contract](#lifecycle-contract-single-combined-stream)).

---

## Cursor and Spacing

### Cursor primitives (pure functions over tokens + i)

```
kind/2, token/2, value/2, peek_kind(tokens, i, n), advance(i) = i + 1, at_eof?/2
```

### Spacing helpers

These drive ALL whitespace sensitivity and replace the old adhesion token kinds:

```
same_line?(a, b)
adjacent?(a, b)                  # a.end == b.start
separated_on_same_line?(a, b)
has_eol_between?(tokens, i, j)   # true iff any :eol token lies in the index range (i, j)
```

> **Performance guardrail for `has_eol_between?/3` (do not skip).** A range-scanning helper
> like this is exactly how the old project grew a hidden O(n²): a "small helper" called from
> Pratt / no-parens decisions over *growing* spans. Two hard rules:
> 1. `has_eol_between?/3` is permitted **only for bounded local lookahead** — `j - i` must be
>    a small constant (a handful of tokens, e.g. operator-newline continuation). It must
>    **never** be called over a span that grows with subexpression size.
> 2. For any "is there a newline before this far-away token" question, do **not** scan. Build
>    an **`eol_prefix` index once** alongside the token tuple: `eol_prefix[k]` = number of
>    `:eol` tokens at indexes `< k`. Then `has_eol_between?(i, j)` over an arbitrary range is
>    `eol_prefix[j] - eol_prefix[i] > 0` in O(1). The same prefix-count trick covers `:";"`
>    and comment counts if needed. This index is the only sanctioned way to ask the question
>    across an unbounded span. (The CI guardrail "recursive/range walks from Pratt loops"
>    covers misuse of this helper.)

### Speculation

- Checkpoint = `{i, diags, next_diag_id, fuel}`.
- On failure: `i` / `next_diag_id` / `fuel` are scalars; `diags` is restored by retaining the old list head (O(1), shared immutable tail), which correctly drops any diagnostics appended during the failed branch. Discarded speculative subtrees are not free — they were allocated and become garbage (real minor-GC pressure proportional to speculative work); the win is **no rollback bookkeeping**, not zero cost.
- **Bounded speculation only** — never unbounded backtracking. Bounding is the load-bearing perf lever: never over-speculate on the assumption that speculation is allocation-cheap.

> Implementation note (recorded): the rejected Claude alternative was an immutable list-tail cursor; it is idiomatic and cheap for advance/backtrack, but tuple+index gives O(1) `peek_n`, stable token indexes for diagnostics anchoring, and easy range checks between arbitrary tokens. Implement cursor ops behind helpers and benchmark both early; default to **tuple+index**.

---

## Nested Green CST

### Node shapes (NO arena; children nested directly)

```
{:node, kind, span, children, flags, diag_ids}
{:token, token_index, flags, diag_ids}
{:missing, expected_kind, anchor_index, flags, diag_ids}

# diag_ids: prefer `nil | id` (immediate) for the common 0/1-diagnostic node;
# use a list only for the rare multi-diagnostic node, to avoid a cons cell per error node.
```

### Flags

Flags are a **bitset / small integer** (NOT a map):
`has_error`, `synthetic`, `contains_eol`, `has_comments`, `matched_expr`, `unmatched_expr`, `no_parens_expr`.

`has_error` and the expression class are set **at construction** by OR-ing children — never by walking a built subtree (P9).

---

## Parser

### Function shape

Plain args, compact return — no structs, no arena, no `next_id`:

```
parse_expr(tokens, i, min_bp, ctx, diags, next_diag_id, fuel)
  :: {:ok, cst_node, i, diags, next_diag_id, fuel}
```

- `ctx` is a small atom or bitmask (`matched | unmatched | no_parens` + flags), not a struct.
- `diags` is a **reversed list** (prepend; reverse once at the boundary).
- **No parser function returns a fatal user error**; fatal is reserved for internal invariants (exhausted fuel).

### Pratt scope (P8)

Pratt handles operators **only**. Calls, no-parens arg lists, do-blocks, stabs, containers, maps, bitstrings, strings/sigils are recursive-descent grammar routines that **call** Pratt for subexpressions.

### Elixir-specific ambiguities (all parser-side, no deferrals)

- **Calls / adjacency.** `foo(` is a paren call iff `adjacent?(callee, "(")`; `foo (` (spaced) is a no-parens call with a parenthesized argument; `foo[` is access iff adjacent. Range checks, not token kinds.
- **No-parens calls.** GRAMMAR routines (`no_parens_zero` / `one` / `many` / `one_ambig`), not Pratt. Bounded speculation with a commit rule mirroring `yecc` (prefer outer arity 1 for `one_ambig`). Encode arity/nesting bans as direct checks producing diagnostics.
- **`a -1` vs `a - 1`.** Lexer emits neutral `:dual_op`; parser uses `separated_on_same_line?(callee, op)` **AND** `adjacent?(op, operand)` to choose no-parens-call-with-unary-arg vs binary subtraction.
- **`do` attachment.** Governed by `ctx` + head shape + whether the construct accepts a block; no `do_identifier` token.
- **`not in`.** Lexer stays neutral (two tokens). The parser recognizes `not <eol?> in` only where the grammar allows the combined operator, and Pratt builds **one named CST node that records the surface form faithfully** — it does **not** rewrite into `not(a in b)`:
  ```
  {:node, :not_in_op, span, [left_cst, right_cst], flags, diag_ids}
  ```
  No grammar routine or Pratt code performs the `not(... in ...)` rewrite or emits the warning. **Lowering alone** turns `:not_in_op` into the canonical AST `{:not, _, [{:in, _, [a, b]}]}` (or the current canonical shape) and emits the deprecation `:warning`. This keeps the "no rewrite-ish work in Pratt" rule enforceable: if `:not` or `:in` AST tuples appear anywhere outside `Toxic2.Lower`, that is a bug.

---

## Recovery (parser-only, uniform)

**One rule:** on an unexpected/invalid token, emit an error/missing node for the SMALLEST failing unit, prepend a diagnostic (onto the reversed `diags` list — never `++`/`List.insert_at`), skip to the nearest LOCAL sync set (consuming ≥1 token for forward progress), continue.

- Missing delimiters → `:missing` node at a zero-width anchor.
- Unexpected tokens → error leaf/node skipped to sync.
- A lexer `:error` token becomes an error leaf + diagnostic and does **NOT** trigger a second generic parser diagnostic unless the parser is blocked at a distinct boundary (no double-fix is possible because only the parser repairs).

### Sync sets (data)

```
expr_sync      = [:eol, :";", :",", :")", :"]", :"}", :">>", :end, :block_label, :eof]
call_args_sync = [:",", :")", :eol, :";", :end, :eof]
container_sync = [:",", :"]", :"}", :">>", :eol, :";", :end, :eof]
stab_sync      = [:stab_op, :end, :block_label, :eof]
string_sync    = [:string_fragment, :begin_interpolation, :end_interpolation, <string_end_kind>, :eof]
```

Recovery prefers the innermost scope; falls outward only if it cannot advance. The global step/fuel budget is a debug backstop (a threaded integer; reserve `:counters`/`:atomics` only if threading becomes noisy) — it must never trip on real input.

---

## Diagnostics

Flat tuple, NOT a struct/map on the hot path; convert to a struct at the boundary:

```
{id, phase, severity, code, sl, sc, el, ec, details}
```

- `id` is monotonic + deterministic within one parse.
- `severity` is `:error | :warning`. `:warning` never trips strict (P1).
- `phase` is `:lexer | :parser | :lowerer`.
- Error/missing nodes carry the matching `id` in `diag_ids` so tooling correlates node ↔ diagnostic.
- Diagnostics are anchored to token indexes where useful.

### Lifecycle contract (single combined stream)

There is exactly **one** combined diagnostic stream in the result, assembled in source order
from three contributors:

```
all_diagnostics =
  lexer_warnings                # returned by the lexer alongside tokens (warnings only)
  ++ parser_diagnostics         # incl. exactly ONE diagnostic per :error token consumed
  ++ lowerer_diagnostics        # e.g. the not in :warning
  |> sort_by_source_position()
```

- **Lexer ERROR → parser transport is the `:error` token, and ONLY the `:error` token.** The
  lexer does **not** return a separate error list. A lexical error's payload travels inside
  the `{:error, sl, sc, el, ec, %Toxic2.LexError{}}` token; the parser is the component that
  turns it into a diagnostic (and an error/missing CST node), tagged `phase: :lexer`. This
  makes duplication structurally impossible — there is no second channel to double-count.
- **Lexer WARNINGS** are the one thing the lexer returns out-of-band (as `{tokens, warnings}`),
  because they are not tied to a recoverable token position the parser must act on. They are
  `:warning` severity and never trip strict.
- **No double-reporting.** A lexer `:error` token yields exactly one diagnostic; the parser
  does not add a second generic "syntax error" diagnostic for the same token unless it is
  then blocked at a *distinct* construct boundary (the no-double-fix rule from
  [Recovery](#recovery-parser-only-uniform)).
- **Lowerer diagnostics** (e.g. the `not in` deprecation `:warning`) are appended to the same
  stream. They are the only diagnostics produced after the parse phase. Lowering never
  produces `:error` diagnostics for *valid* CST.
- `strict/2` and the conformance harness both filter this one stream by `severity == :error`.
  Nothing inspects per-phase lists in isolation.

---

## Lowering (`Toxic2.Lower.to_ast/3`)

The ONE pure pass that owns Elixir AST quirks:

- dotted aliases, captures, unary `+`/`-`, keyword/`do` calls, `not in` rewrite + warning, `capture_int`, metadata shaping.
- Valid CST → AST comparable to `Code.string_to_quoted_with_comments/2` after metadata normalization.
- Invalid CST → best-effort AST with `{:__error__, meta, payload}`.
- Lowering **NEVER** raises.

This split is what localizes a conformance failure to "CST structurally wrong" (parser bug) vs "lowering rule wrong" (lowerer bug), and makes lowering unit-testable in isolation — directly attacking a top root-cause of the old project's thrash.

---

## Metadata Policy

**Required**
- Valid AST shape + values match the reference.
- Line/column present where useful.
- Token ranges preserved in the CST.
- Synthetic nodes marked.
- Diagnostics have stable ranges.

**NOT required**
- Keyword-order in meta.
- Upstream `closing` / `end_of_expression` / `newlines`.
- Exact invalid-code error location.

If direct CST flags via meta start allocating too much, prefer bitset / internal flags over `meta[:cat]` / `meta[:err]`.

---

## Performance Rules (BEAM-specific)

- Tokenize once; tokens in a tuple; integer-index cursor.
- Compact tuples for tokens / diagnostics / nodes.
- Reversed lists for diags; reverse once.
- Atoms / integers / bitsets for `ctx` & flags (not maps).
- No structs in inner loops.
- No `Enum` in hot loops (direct recursion).
- No `++` (build reversed).
- No `Keyword` metadata until lowering.
- **Never** call `Code.string_to_quoted/2` from the parser.
- **Never** traverse a built CST/AST from a Pratt loop.

**Target (hypothesis to validate early, not yet evidence):** ≤ ~1.5× `yecc` wall-time on the valid corpus, with allocations materially below the old pipeline. The binding constraint is allocation/GC, not dispatch: `yecc` emits a table-driven LALR automaton with near-zero per-token allocation and produces the AST directly, whereas Toxic2 builds a CST *and* diagnostics *and* flags and then lowers in a second pass. That second pass over the tree is the main risk to 1.5×. The claim that the old 2× was "plumbing, not algorithm" is an assertion to confirm with the early benchmark (phase 6 / phase 13), not a settled fact.

---

## Test Strategy

Reuse old suites as material; split by responsibility.

- **Lexer tests (from `toxic`):** valid literals / identifiers / aliases / operators / strings / sigils / heredocs, unicode/security, comments, exact ranges — rewritten to the new linear token set (no deferral tokens, explicit `:eol`, no newline payload on operators, no synthesized closers).
- **Parser valid-code conformance (from `toxic_parser`, organized by nonterminal — highest-value asset):** for each valid source, assert `normalize_ast(Toxic2 lowered) == normalize_ast(Code.string_to_quoted(source, columns: true))` AND `error_diagnostics == []` (i.e. no diagnostics of severity `:error`). Valid code MAY emit `:warning` diagnostics (e.g. `not in`); warning behavior is tested separately, not asserted by the conformance rule.
- **Invalid-code tolerance (from property failures + the old `TOLERANT_MODE_V1` taxonomy):** no crash; bounded runtime; non-empty CST; diagnostics have ranges; every parser diagnostic anchored to a CST error/missing node; lowering returns a best-effort AST; no duplicate diagnostics for one lexer error unless a distinct boundary. Do **NOT** assert reference error strings. Unlike the old suite, invalid inputs are **NOT** skipped — they are the corpus.
- **Differential fuzzing:** generated valid programs compare AST vs reference; generated invalid/arbitrary token streams assert invariants only.

### Machine-checkable invariants

- Parser consumes-or-inserts on every recovery step.
- Index never decreases except inside an explicit speculative branch.
- Node ranges monotonic.
- Child ranges fit the parent or are synthetic.
- Diag ids unique.
- Every error/missing node points to a diag id.
- Lowering never raises.

---

## Agent Development Harness (the anti-thrash core)

Failures must be small, reproducible, classified, and mechanically checkable.

### Two gates

The harness has **two independent gates**. An agent's change must pass both.

1. **Quality gate** — formatting, lint, types, and the **reward-hack/drift guard**. Live from
   **phase 1** (it needs no conformance corpus). This is the anti-cheat + code-health layer.
2. **Conformance freeze gate** — the `freeze.json` ratchet over valid/invalid corpora. Bootstraps
   in **phase 6** (it needs the lowering + oracle harness). This is the anti-thrash layer.

### Quality gate (live now — `mix toxic2.check`)

`mix toxic2.check` runs, in order, failing fast:

```
mix format --check-formatted        # no unformatted code
mix toxic2.guard                    # reward-hack / old-design guard (see below)
mix credo --strict                  # lint + complexity ceilings (cyclomatic ≤ 12, arity ≤ 9, nesting ≤ 3)
mix compile --warnings-as-errors    # zero compiler warnings
mix test                            # unit + property suites
```

`mix toxic2.check.full` additionally runs `mix dialyzer` (typespec analysis; slow first run —
builds the PLT). Dialyzer flags: `error_handling`, `extra_return`, `missing_return`,
`unmatched_returns`. The whole alias runs in `MIX_ENV=test`.

These are not aspirational. They are implemented in the project and green. CI sets `CI=true`,
which also makes ordinary `mix compile` treat warnings as errors.

### Commands

The **conformance harness** (phase 6+) is a distinct task from the quality-gate alias
`mix toxic2.check` (above) — do not conflate them:

```
mix toxic2.conformance --json --gate
mix toxic2.conformance --bucket <construct> --gate
mix toxic2.conformance --fuzz --seed <seed>
mix toxic2.bench --project elixir
```

Each prints: total cases, failure count, first repro path, seed, elapsed, throughput. From
phase 6, the `mix toxic2.check` alias also runs `toxic2.conformance --gate` last, so one
command runs both gates.

### JSON report

Per-class pass/fail/crash counts, perf `ratio_to_yecc`, failures bucketed by construct, and a bounded, SHRUNK, stably-ordered (bucket, then input length, then lexical) `first_failures` list with input + AST diff.

### Freeze-ratchet gate (the central anti-thrash device)

`freeze.json` records every currently-passing input (class-1 valid-conformance + class-2 tolerance). `--gate` fails the build if ANY frozen-passing input regresses. Agents may **ONLY** ratchet the freeze forward (add newly passing inputs); they may **NEVER** delete an entry to make the gate green.

### One bucket at a time

Tags/buckets = `:lexer` `:layout` `:operator` `:no_parens` `:do_block` `:stab` `:container` `:map` `:bitstring` `:string` `:interpolation` `:keyword` `:recovery` `:lowering` `:metadata` `:performance`. An agent targets one bucket; the gate protects all others.

- Crash budget = 0 (P0, reported separately, blocks merge).
- Perf gate soft until conformance is high, then hard.

### Golden fixtures

Shrunk property failures auto-promote to fixtures (`id`, `source`, `mode`, `expected`, `tags`).

### Reward-hack / drift guard (`mix toxic2.guard`)

This is the **anti-cheat** check. Every reward-hack listed here was *actually observed* in the
previous attempt; the guard exists so an agent cannot repeat them to turn a test green without
doing the work. Implemented as `mix toxic2.guard` (a pure, unit-tested scanner — string-fragment
needles so the guard's own source never self-trips; an auditable per-line escape hatch
`# guard:allow`). Starts as text scanning; promote individual rules to Credo/AST checks as they
mature.

Forbidden in **library core** (`lib/toxic2/**`) **and non-oracle tests** — the built-in Elixir
parser/tokenizer/eval as a crutch (the #1 observed hack: borrowing the reference's behavior):
- `Code.string_to_quoted(!)`, `Code.string_to_quoted_with_comments(!)`, `Code.eval_string`,
  `Code.eval_quoted`, `Code.compile_string`, `:elixir.string_to_quoted`, `:elixir_tokenizer`,
  `:elixir_parser`. Allowed in **exactly one place**: the oracle (`test/support/oracle*` /
  `test/**/*conformance*`), the only legitimate consumer (P10).

Forbidden in **library core**:
- `Macro.to_string` (lossy AST↔string comparison must not live in the library; R_OPUS §10.5).

Forbidden in **hot modules**:
- `++` (build reversed, reverse once). Hot-path structs in lexer/parser core.

Forbidden in **test files** (green-without-work hacks):
- Tautological assertions (`assert true`).
- `@tag :skip` / `@moduletag :skip` (disabling a test to dodge a failure).

Additional drift rules (text-scan now, AST later):
- Recursive AST/CST walks from Pratt/main loops.
- `has_eol_between?/3` (or any token-range scan) called with a non-constant range, or over a span derived from subexpression size — must use the `eol_prefix` index instead.
- A separate lexer error list (errors must travel as `:error` tokens; lexer returns only `{tokens, warnings}`).
- New deferral-shaped token kinds.
- Lexer-side synthesized parser tokens.
- Mode branches in grammar code.

### Progress metrics in reports

Valid pass rate, invalid non-crash rate, property fails by tag, diagnostics-without-anchors, duplicate-diagnostics-per-lexer-error, avg & p95 parse time, reductions/KB, allocations/KB, max recovery skip length.

### Agent loop

`mix toxic2.check` (quality gate must be green first); `mix toxic2.conformance --json --gate`; pick the highest-count failing bucket (or assigned); read its `first_failures`; change ONE routine; `mix toxic2.conformance --bucket <b> --gate`; if the bucket improved AND both gates are green, ratchet freeze + commit naming the RULE changed (never "fix"); else revert.

---

## Reuse Map

**PORT**
- Operator/precedence families (from `precedence.ex` / `expr_class.ex`).
- Conformance suites + corpus runner (fix the hardcoded path to an env var).
- Property generators (add the missing string/heredoc/sigil generators).
- The linear string/interpolation logic (stripped of driver/deferral coupling).
- The `TOLERANT_MODE_V1` sync-set / error-node taxonomy.

**DISCARD**
- The streaming Driver + deferrals.
- The old `Cursor` / `TokenAdapter` / `EventLog` / `State` struct threading.
- Every mode branch.
- The `Code.string_to_quoted` error-parity path.
- `pratt.ex`'s non-operator logic.

Do **NOT** start by porting `pratt.ex` / `maps.ex` / `stabs.ex` — treat old modules as executable research and test material, not implementation substrate. Do not copy the old module decomposition.

---

## Design Rationale (the two specs' assessment of each other)

This spec is the synthesis of two converged specs. Future readers should understand the choices.

- **Claude's spec was judged the better FIRST IMPLEMENTATION PLAN:** smaller scope, fewer moving parts, clearer agent loop, less risk of rebuilding a large architecture before conformance is stable.
- **GPT's spec was judged the better NORTH-STAR** for an IDE-grade lossless parser with CST, precise error anchoring, and future formatter/incremental tooling.

Two choices were specifically debated:

1. **Direct-AST vs CST.** Direct-AST (Claude) is the pragmatic MVP and avoids a second representation, but re-couples parsing with AST quirks; if you later need formatter-grade losslessness, exact missing-token anchoring, or stable editor trees you'd wish for the CST. **RESOLUTION:** adopt CST + lowering from the start (CST node helpers land in phase 4, lowering in phase 6) — because dropping the arena makes a nested green tree barely more work than AST tuples, and the lowering pass REDUCES net complexity by centralizing the AST quirks that the old project smeared everywhere. The CST also delivers the north-star path without a future rewrite.

2. **List-tail cursor (Claude) vs tuple+index (GPT).** List-tail is idiomatic and cheap for advance/backtrack; tuple+index gives O(1) `peek_n`, stable token indexes for diagnostics, and easy arbitrary-token range checks. **RESOLUTION:** tuple+index as default, behind cursor helpers, benchmark both early.

---

## Migration Phases

The **quality gate** (`mix toxic2.check`: format, `toxic2.guard`, Credo, warnings-as-errors,
tests; `+ dialyzer` in `.check.full`) is live from **phase 1** and every phase must keep it
green. The **conformance freeze-ratchet gate** bootstraps in **phase 6** (alongside the oracle
harness); phases 1–5 are pre-conformance-gate (validated by ordinary unit tests), and from
phase 6 onward each phase also ends green under `toxic2.conformance --gate` and ratchets
`freeze.json` forward.

1. `Toxic2.Token` tuple helpers + batch lexer for a minimal token subset. **(done — plus the
   phase-1 quality gate: `mix toxic2.check` / `.check.full`.)**
2. Port literal/identifier/operator/delimiter lexing — no deferrals. **(done — numbers
   incl. `0x`/`0o`/`0b`/floats, chars, atoms, `:kw_identifier`, `:literal`, the full operator
   family set, `<<`/`>>`, `%`, comments; binary name values; codepoint-aware error fallback.
   Strings/sigils/heredocs/interpolation consolidated into phase 10 to avoid a wrong partial
   string-token contract.)**
3. Token cursor primitives + spacing helpers. **(done — `Toxic2.Tokens`: list→tuple view with
   O(1) indexed `kind`/`value`/`token`/`span`/`peek_kind`, `:eof` past the ends, `eol_between?/3`
   via a once-built `eol_prefix` index (O(1), the anti-O(n²) guardrail), and index-based
   `adjacent?`/`same_line?`/`separated_on_same_line?`. Cursor = integer index; no struct.)**
4. Nested green CST node helpers + flat diagnostics. **(done — `Toxic2.CST` with the three
   nested node shapes, bitset flags, and `has_error`/`contains_eol` inherited from children at
   construction (P9); `Toxic2.Diagnostic` (flat tuple) + `Toxic2.Diagnostics` (id-allocating
   accumulator, `errors/1` strict filter, `merge_sorted/1`).)**
5. Expression-list, literals, identifiers, basic Pratt operators. **(done — `Toxic2.Precedence`
   (binding powers keyed by operator family, pinned to `elixir_parser.yrl`) + `Toxic2.Parser`:
   Pratt over the integer-index cursor, building CST `:binary_op`/`:unary_op`/`:paren`/`:expr_list`
   nodes; tolerant (error leaf / `:missing` + one diagnostic, never a raise); CST-only, no AST
   quirks. Keyword-free `CST.node/5` added for the hot path.)**
6. Valid CST→AST lowering + conformance harness (`mix toxic2.conformance`: JSON, buckets, freeze gate); wire it into the `toxic2.check` alias. **(done — `Toxic2.Lower` (total CST→AST), `Toxic2.parse_to_ast/2`, `Toxic2.Conformance.Corpus`, and the `mix toxic2.conformance` task (oracle compare, `--json`, buckets, `--gate`/`--update-freeze` ratchet over `freeze.json`). Conformance is also an ExUnit suite (per-source). Wired into `toxic2.check`. The harness immediately caught a real bug: `**` is left-assoc in the live oracle, not right as a stale yrl said. Both gates now live: quality (phase 1) + conformance freeze (47 frozen).)**
7. Containers + calls.
8. No-parens call families with expression-class flags.
9. Blocks, stabs, control-flow, `do` attachment.
10. Strings, sigils, heredocs, interpolation.
11. Parser-only recovery + invalid-code property harness.
12. Port old property failures as permanent fixtures.
13. Benchmark; remove hot-path allocations before broadening features.

---

## Acceptance Criteria

- Lexer emits only linear source-ordered tokens.
- Parser has one tolerant core; strict is a wrapper.
- Valid corpus AST compares equal after normalization.
- Invalid corpus always returns CST + best-effort AST + diagnostics.
- No parser path calls `Code.string_to_quoted`.
- No lexer deferrals or synthesized closers.
- Parser speculation uses integer indexes.
- Hot state is in arguments, not structs.
- Property failures reproducible as fixtures.

The rewrite **SUCCEEDS** if new failures become local additions to sync sets, parse routines, or lowering rules — **never** cross-cutting changes to lexer recovery, cursor behavior, Pratt state, or reference-error compatibility.
