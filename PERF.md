# 2026-06-13 — Fair (apples-to-apples) measurement + arch-change verdict + representation survey

(Everything below this dated header supersedes the older notes further down, which predate the
token_metadata work and the perf passes 6–10.)

## 1. Fair measurement: compare at MATCHED output

The headline `mix toxic2.bench` calls `Code.string_to_quoted/1` with **no opts** → oracle emits
`[line: N]` only. Toxic2's default emits `[line: N, column: C]`. So the headline 1.27x compares
**unequal output** — toxic2 carries strictly more metadata than its baseline.

Verified: `Toxic2.parse_to_ast(src, token_metadata: true)` produces an AST **byte-identical** to
`Code.string_to_quoted(src, token_metadata: true, columns: true)`. That is the real apples-to-apples
pair. Fresh-process-per-iteration bench over the 105-file oracle-valid stdlib corpus:

```
arm             median ms     x oracle_tm   x oracle_plain
t2_plain           123.6          1.14x          1.28x
t2_tm              229.7          2.12x          2.38x      <-- fair, matched output
oracle_plain        96.7          0.89x          1.00x
oracle_cols        107.0          0.99x          1.11x
oracle_tm          108.4          1.00x          1.12x
```

**The honest fair number is 2.12x, not 1.27x.** Two facts fall out:
- Oracle barely cares about metadata level: 96.7 → 108.4ms (+12%) from plain to full token_metadata.
- Toxic2 nearly doubles: 123.6 → 229.7ms (+86%). The token_metadata lowering is toxic2's weak spot,
  not its parser. Allocation tells the same story: plain 48.1M words → token_metadata 81.5M (+69%).

## 2. Where the token_metadata cost goes (tprof call_memory, tm path)

```
2,743,437 w  376,474 c  Lower.split_leading_ws/1   <-- #1, and it's pure waste
1,341,123 w  108,041 c  Lower.lower_token/5
  801,080 w  100,135 c  Lower.tm_node_keys/4
  666,141 w   32,781 c  Lower.call_closing/6
  652,800 w  130,560 c  Lower.tspan/2
  583,698 w   65,562 c  Lower.after_open_paren/4
  551,880 w   29,450 c  Lower.finalize_eoe/3
  458,635 w   98,887 c  Lower.gap_newlines/4
  386,387 w   70,585 c  Lower.scan_eoe/6
  352,044 w   16,764 c  Lower.kw_at/5
```

The `end_of_expression` / `newlines:` scanners (`scan_eoe`, `gap_newlines`, and their shared
`split_leading_ws`) are the dominant tm allocators. They do, per node:
`String.slice(line, col-1, String.length(line) - (col-1))` then `split_leading_ws` on the slice.
That is **O(line length) twice** (`String.length` walks the whole line counting codepoints; `slice`
re-walks and materializes a sub-binary) plus `split_leading_ws` builds yet another sub-binary tail —
all to answer three trivial questions: where does the first non-ws char sit, is the rest empty, does
it start with `#`/`;`. `bin_opt_info` already flags `split_leading_ws` (BINARY CREATED, returned).

## 3. Proposed architectural changes — verdict: DON'T (agree with your instinct)

| Change | Complexity | Gain | Verdict |
|---|---|---|---|
| Metadata fast-mode (`columns:`/`metadata:` levels) | low (opts already threaded) | **0 on default headline** by construction; only helps a consumer who opts down | Skip as perf work. It's a feature, not a speedup. |
| CST span flattening (span tuple → node fields) | medium-high, broad churn across parser/lower/cst | ~1% alloc — and **alloc is already 0.97x oracle on default / not the bottleneck** | Skip. Wrong metric. |
| Token-tuple slimming (drop redundant `el`) | high (tagged union for multiline; every `tspan`/`merge_tt`/`cst_ends_at?` touched) | lands on lex, which is already 0.52x alloc / 0.60x wall | Skip unless lex becomes the target. |
| nid/fuel via `:counters`/`:atomics` | medium (breaks pure-return contract) | shrinks Pratt return tuples by ~2 words; but for VALID code nid/fuel are **immediates threaded for free**, and counters add a BIF call per fuel-decrement (every recursion) | Skip — see §4. |
| diags via ETS/pdict (mutable accumulator) | medium, breaks purity | diags is `[]` for valid code (free); only non-empty on broken files, which aren't perf-sensitive | Skip. |
| Arena / mutable CST | total rewrite; explicitly rejected by design | attacks alloc (already below oracle) | Skip. |
| Fuse parser+lower → direct AST | rewrite; undermines the tolerant CST design | would close the structural 2-pass gap but at the cost of the architecture | Out of scope. |

**The load-bearing reason most of these fail:** on the DEFAULT path allocation is already *below*
oracle (0.97x) while wall is *above* (1.27x) — so allocation-reduction architecture cannot move the
headline. The wall gap is compute in lowering. And on the FAIR (token_metadata) path the cost is not
the data representation at all — it's the **algorithm** in the eoe/newlines scanners (§2). Fix the
algorithm, not the representation.

## 4. Representation survey (bitflags / clever structures / counters / atomics / O(1) access)

Most of the codebase already uses the smart representation:
- **CST flags**: a bitset integer, inherited by OR-ing children at construction (O(1) "has error in
  subtree"). Already optimal — no change.
- **diag_ids**: `nil | id | [id]` — avoids a cons cell for the common 0/1-diagnostic node. Optimal.
- **Tokens view**: `{tuple_of_tokens, size, cont}` — O(1) indexed access via `elem`; `cont` is `nil`
  (not an empty MapSet) when there are no continuations. Optimal.
- **source_lines**: a tuple of line sub-binaries (sub-binaries share the original source, no copy);
  O(1) line access via `elem`. The *container* is right; the *consumers* are wrong (§2).

**`:counters` / `:atomics` for nid/fuel — analyzed and REJECTED.** They are the textbook mutable-
counter case, but the threading they'd replace is nearly free here: for valid code `diags=[]`,
`nid` rarely advances, `fuel` is a small int — all immediates, 0 heap words, passed through return
tuples that the JIT keeps in registers. Converting to a counter ref *adds* a BIF call on every
`fuel - 1` (i.e. every `parse_expr` recursion, ~200k+ calls) and every `nid` mint, to save tuple
words that are already below oracle. Net: wall-time loss to "optimize" alloc that isn't the problem,
plus it breaks the pure-scalar return contract that makes the parser resumable/testable. Same logic
kills mutable diags accumulators.

**The one representation/algorithm change worth doing — fix the eoe/newlines scan (the actual 2.12x
cost center).** Replace `String.slice` + `String.length` + `split_leading_ws` with a single direct
walk over the line sub-binary that:
1. skips `col-1` codepoints (a byte step for ASCII lines — the overwhelming majority),
2. skips leading space/tab in place,
3. returns the first significant char (or end-of-line) and its column — **no materialized slice, no
   full-line `String.length`, no tail sub-binary**.

This turns each scan step from O(line length) + 2 allocations into O(col) + 0 allocations, and it
hits the top allocator (`split_leading_ws`, 2.7M w) plus `scan_eoe`/`gap_newlines` directly. Expected:
a large dent in the +69% token_metadata allocation and a real slice of the 2.12x wall — this is the
only candidate that targets the stage *and* resource where the fair-comparison cost actually lives.
Localized to ~4 private functions in lower.ex; semantics pinned by the existing token_metadata parity
corpus (oracle byte-equality), so risk is low. Worth implementing and A/B-measuring next.

### DONE (commit 02d1c03) — landed and measured

`line_probe/2` replaced the slice+`String.length`+`split_leading_ws` path. Result on the matched
token_metadata comparison:

```
token_metadata wall   229.7 -> 194.5 ms   (2.12x -> 1.86x oracle_tm)
token_metadata alloc  81.5M -> 63.0M words (-22.7%)
```

**Key implementation gotcha (cost me one iteration):** the first cut split the walk into
`line_seek` (skip n cols) + `line_classify` (skip ws) with a bare-variable termination head
`line_seek(bin, 0, col)`. That single non-binary-matching clause defeated match-context reuse for
the *whole* function — `bin_opt_info` flagged "does not begin with a suitable binary match", and the
byte scan materialized a fresh sub-binary on every codepoint: total tm alloc went the WRONG way,
81.5M -> 113.6M (`line_seek` alone 43.5M w). Fusing into one `line_walk/3` where **every clause
begins with `<<...>>`** (the counter is a phase guard, `n > 0` vs `0`) restored context reuse →
zero per-step alloc. Lesson: a recursive binary scanner must have *no* bare-variable head clause, or
it silently de-opts to per-step sub-binary materialization. Default (non-tm) path untouched.

### DONE pass 2 (commit 940b16f) — de-slice the remaining tm anchor finders

After the §2 scanner fix, tprof showed the residual tm String cost was the SAME grapheme slicing in
`scan_op` (`->`/`|`/`when`/`not`/`in`/`=>`/`.` anchors), `last_paren`+`last_index_of` (`closing:`),
`kw_at` (`do:`/`end:`), and the shared `src_slice/3` (`token:` text, `(`/`)` checks). All used
`String.slice` + `String.split` + `String.length` = O(line) grapheme walks + intermediate
sub-binaries/lists. Replaced with byte-walk primitives:
- `col_byte/2`: codepoint column → byte offset, scalar return, all-binary-head (the `0` terminal is
  `<<_::binary>>`, never a bare var). Shared by scan_op / kw_at / src_slice.
- `scan_op`: `col_byte` to position, then C-level `:binary.match` for the needle; `last_index_of`
  deleted in favour of `last_char_col` (one in-place walk for the last `)` column).
- `kw_at → word_at?`: `col_byte` + a single `binary_part` equality check.
- `src_slice` single-line: `col_byte` ×2 + one `binary_part`, preserving `String.slice`'s ""/to-end clamp.

Result: **tm alloc 62.97M → 57.16M words (−9.2%, exact tprof)**; tm WALL flat within noise. The
contrast with §2 is instructive: those eol scanners ran per-node and did a genuine O(line)
`String.length` CPU walk → fixing them moved wall (2.12×→1.86×). These finders fire far less often,
so swapping `String.slice`/`split` for `:binary.match` is CPU-neutral — the win is allocation +
clarity + codepoint-correctness (`String.slice` indexes by *graphemes*, a latent mismatch with the
lexer's codepoint columns on non-ASCII operands). **Takeaway: de-slicing pays in wall only where the
slice ran hot enough that its O(line) grapheme walk was real CPU; elsewhere it's an allocation win.**
Remaining tm String alloc is `src_slice`'s MULTI-line clause (rare — heredoc token text) +
`source_lines`' per-file `String.split(source, "\n")` (needed, one per file) — both low-value.

### DONE pass 3 (commit fc73530) — src_slice multi-line clause, for completeness

De-sliced the `el > sl` clause too (col_byte + binary_part for the first-line tail / last-line head;
Enum.join keeps the result). **Measured: tm allocation byte-IDENTICAL before/after on both stdlib
(57,156,853 w) and a heredoc-heavy synthetic corpus (16,423,523 w)** — the multi-line clause is
effectively COLD on real code (heredoc `token:` is single-line per fragment; only rare cross-line
`;`-in-span checks reach it). So this is a correctness + consistency change (src_slice is now
uniformly codepoint/byte-based, no String grapheme ops), NOT a speedup. Confirms the §pass-2
takeaway: de-slicing a cold path yields nothing measurable — the eol scanner (hot) was the only
slice removal that moved wall.

NOTE — pre-existing bug found while testing (NOT introduced here; reproduces at fa825c5, before any
de-slicing): a multi-line paren call followed by a do-block, `foo(\n a,\n b\n) do c end`, mismatches
the oracle's token_metadata (`closing:` for the `)` before the `do`). Lives in
`close_paren_before_do`/`last_paren` logic, unrelated to slicing. Candidate for a separate fix.

### DONE pass 4 (commits b31ed15, 62effef) — fix the "bug", then fix what de-slicing cost in CPU

1. **The "closing bug" was a key-ORDER bug, not a value bug.** Oracle's `closing:` value was correct;
   toxic emitted meta keys as `eoe, newlines, do, end, closing` where the oracle emits
   `eoe, do, end, newlines, closing` (verified across call/tuple/map/fn/bitstring: do/end first, THEN
   newlines, THEN closing). `tm_node_keys` concat'd `open_newlines` before `doend_keys` — right only
   with no do-block. Swapped to `doend_keys, open_newlines, closing_keys, delimiter_keys`. OSS tm
   byte-equality 5510 → **5512**/5519 (2 real files). Added order-sensitive regression tests
   (`assert_parity` normalises order, so it couldn't catch this).

2. **eprof (TIME, not alloc) exposed the real next bottleneck — a regression my own de-slicing
   introduced.** `col_byte/3` (21%) + `utf8_width/1` (10.6%) = ~32% of tm CPU: `col_byte` decoded a
   full UTF-8 codepoint and called `utf8_width` on EVERY byte (incl. ASCII), 8.76M calls. Added an
   ASCII fast-path clause (`<<c, rest>> when n>0 and c<128 -> off+1`) before the utf8 clause.
   **col_byte 21%→14.7%, utf8_width gone, t2_tm wall 301.4→271.9 ms (−9.8%), ratio 1.94×→1.81×.**
   First wall win on tm since the eol scanner. LESSON: de-slicing trades BIF-alloc for BEAM-CPU walks
   — always re-profile with eprof (TIME) afterward, because a no-alloc walk can still be a CPU hog;
   give every per-byte scanner an ASCII fast path (one byte = one column, no utf8 decode).

### DONE pass 5 (commit 7098fc2) — O(1) ASCII positioning for col_byte
Added a whole-source ASCII flag to opts (one cached-pattern `:binary.match` per file; set ⇔ no byte
≥128 anywhere ⇔ every line pure ASCII ⇔ codepoint col == byte offset). col_byte then returns `col-1`
in O(1) for ASCII files; files with any non-ASCII fall to `col_byte_walk` (always correct). Threaded
to src_slice / scan_op / kw_at. **col_byte 14.7% → out of profile; t2_tm 202.3 → 183.5 ms (−9.3%),
ratio 1.80× → 1.67×.** Cumulative tm arc: 2.12× → 1.86× (eol scanner) → 1.81× (col_byte ASCII clause)
→ 1.67× (this). NOTE the whole-source flag is coarse — one non-ASCII byte flips a whole file to the
walk; on stdlib that leaves 3.12M `col_byte_walk` calls (unicode docstrings). A per-LINE flag would
recover those, but needs a parallel tuple in `source_lines` + threading the line index (medium ROI).

### DONE pass 6 (commits f867547, a4c0e0b) — line_walk ASCII + keyword-assembly audit
1. **line_walk ASCII path (f867547).** The eol scanner got the same whole-source-ASCII O(1)
   treatment as col_byte: `line_probe(text, col, true)` jumps to byte `col-1` and classifies with
   O(1) `:binary.at` peeks (`line_classify_ascii`), no per-codepoint skip walk. **t2_tm 184.4 →
   177.9 ms (−3.5%), 1.67× → 1.63×.** Non-ASCII files keep `line_walk` (utf8-correct).
2. **Keyword-assembly audit (a4c0e0b).** eprof flagged `Enum.concat_list/1` at 3.25% (523k calls):
   `tm_node_keys` built `Enum.concat([doend, newlines, closing, delimiter])` (a concat over four
   mostly-EMPTY lists) and `finalize_node` concat'd that onto the base meta. Reworked to thread the
   base meta in as a `tail` and PREPEND each component right-to-left via `prepend/2` (returns `tail`
   unchanged for an empty component — the common case — else one small `++`). A no-tm-keys node now
   allocates nothing; the 4-element intermediate and the second concat are gone. **concat_list 3.25%
   → 0; `++` calls 606k → 156k (−74%); eprof CPU −2.4%; t2_tm min 178.5 → 173.3 ms (−2.9%).**
   Key order unchanged. AUDIT CONCLUSION on the rest of the assembly: the remaining concats are
   already small-LEFT (`Enum.concat(small_keys, shared_tail)` copies only the keys, shares the tail —
   O(keys), not O(meta)); `tm_anchor`'s `Enum.concat(meta, [line,column])` copies `meta` but only
   fires for empty-meta nodes where `meta` is ≤4 tm keys; no O(n) meta copies remain. No further
   smart-list win without changing the meta representation itself (out of scope / low ROI).

### DONE pass 7 (commit b2cfff0) — PER-LINE ASCII flags (the ~9% non-ASCII-file walk)
Replaced the coarse whole-source bool with per-LINE flags: `ascii_lines/2` does one whole-source C
scan; all-ASCII files (majority) collapse to the `:all` sentinel (no per-line tuple, `line_ascii?` is
constant `true`); mixed files get a per-line bool tuple. Callers already have the line INDEX, so they
pass `line_ascii?(opts, line)`. A non-ASCII byte now costs only its OWN line the walk. **col_byte_walk
6.1% → 0.01%, line_walk 3.2% → 0.01% (ASCII lines in mixed files take the O(1) path); eprof CPU 28.86M
→ 24.99M us (−13.4%); t2_tm wall min ~199 → ~156 ms (−21%, back-to-back).** Biggest single win of the
de-slicing arc. 333 OSS non-ASCII files exercise the per-line path; equality unchanged 5512/5519.

### DONE pass 8 (commit 26a296f) — external gpt-5.5 review (copilot CLI), high-ROI items
Ran `copilot --model gpt-5.5 --effort high -p ...` over lower.ex. KEPT 3 per-node items: scan_op uses
`moff - boff` on ASCII lines (skip cp_between's binary_part+count); `child_at/2` replaces
`Enum.at(0/1)` on the call metadata path; `src_byte_at/3` (col_byte + :binary.at) replaces
`src_slice(..,col,col+1)=="x"` single-char delimiter checks (no 1-byte sub-binary). **t2_tm min
160.3 → 145.3 ms (−9.4%).** REJECTED with reasons: Keyword.has_key?→hand recursion (has_key? IS the
:lists.keymember BIF, recursion is slower); word_at? binary_part→:binary.match scope (wash); do_block
find dedup / last_paren backward / scan_op last_line bounds (worst-case/low-frequency, no common-case
win); line_classify_ascii compiled-pattern (GPT's own "benchmark, likely loses on short runs").
CLI note: opencode `run` agentic loop timed out (exit 124) twice; `copilot -p --model gpt-5.5
--allow-all-tools --no-color` worked (~2 min). opencode arg gotcha: `-f` is a greedy array so the
message must be positional-FIRST; `--prompt` is not a `run` option.

### STATE: token_metadata path is now at the SHARED FLOOR
Post-b2cfff0 eprof top is all SHARED lex/parse (identical in default mode, structural): `lex/6` 4.2%
(token 6-tuples), `word_len` 2.9% + `plain_run_len` 2.8% (per-byte scanners), `binary_to_atom` ~4%
(atomization — oracle pays this too), parser combinators (`skip_eols`, `postfix`, `clause_head_ahead?`).
The only tm-SPECIFIC rows left are `line_classify_ascii` 1.8% (the eol newline scan — must scan to the
next token, inherent) and `tm_node_keys` 1.8% (meta assembly — the OUTPUT, inherent). **There is no
remaining tm-specific hotspot worth a targeted fix** — further wins require attacking the shared floor
(token-tuple representation, per-byte lexing, atomization), which is the rejected arch-change territory
above (allocation already ≤ oracle; high churn/risk). The de-slicing + ASCII-positioning arc is
complete: tm went 2.12× → ~1.4× oracle.

---

# (older notes — stale, kept for history)

The current perf story is credible. I reran the new benchmark and got:

```json
t2_lex:  0.673x oracle, 180.28 MB alloc
t2_parse: 1.178x oracle, 281.60 MB alloc
t2_full: 1.505x oracle, 346.61 MB alloc, 1.046x oracle alloc
```

So the agent’s conclusion is basically right: you are now on the line, not safely under it.

On `Token.kind`: yes, but I’d phrase it as **token-view access should be macro or local-inline**, not `Toxic2.Token.kind/1`. The hot path is mostly this shape:

```elixir
Tokens.kind(view, i)
Tokens.value(view, i)
Tokens.token(view, i)
Tokens.span(view, i)
```

Those are cross-module function calls. `@compile {:inline, kind: 2}` in `Toxic2.Tokens` will not inline them into `Parser`/`Lower`.

Best experiment:

```elixir
# parser-local first, not public API
@compile {:inline, tk: 2, tv: 2, tt: 2}

defp tk({toks, _eol, size}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 0)
defp tk(_t, _i), do: :eof

defp tv({toks, _eol, size}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 5)
defp tv(_t, _i), do: nil

defp tt({toks, _eol, size}, i) when i >= 0 and i < size, do: elem(toks, i)
defp tt(_t, _i), do: :eof
```

Then replace hot `Tokens.kind/value/token` calls in `Parser` first. If that wins, do the same in `Lower`. A macro can also work, but local-inline functions are easier to debug and less code-bloaty. If local inline does not move the needle, a macro probably will not justify the ugliness.

My take on the other proposals:

- `metadata: false | :line | :line_column`: useful feature, not a default perf fix. It changes output semantics and won’t help oracle-parity mode. I share your skepticism.
- CST span flattening: not crazy. Current node stores a 6-tuple plus a nested 4-tuple span. Flattening to `{:node, kind, sl, sc, el, ec, children, flags, diag_ids}` saves one tuple allocation per node. That could be real, but it is broad churn. Worth a branch only if token-access + eol-prefix cleanup cannot get reliably below 1.5.
- Remove/lazy `eol_prefix`: more attractive than span flattening. `eol_between?/3` is unused outside tests, but every token view still builds the prefix. Removing or lazily building it is probably safer than CST shape changes and may save another small percent.
- CST accessor macros (`CST.tag`, `CST.node_kind`, etc.): plausible after token access. There are many cross-module calls in `Lower`/`Parser`, but do token view first.

Recommended order:

1. Local-inline or macro token access in `Parser`, then `Lower`.
2. Lazy/remove `eol_prefix`.
3. Local-inline CST accessors if profiling still shows them.
4. Only then consider CST span flattening.
5. Treat metadata fast-mode as a separate API feature, not the path to default `<1.5x`.

The next safest bet is token-view access. It attacks a real repeated cross-module call pattern without changing representation or semantics.

  What's actionable vs inherent

  1. Tokens.kind/2 — the dominant hotspot (12% of calls). It's a one-liner (elem(elem(toks,i),0) + range guard), but it's the parser's universal peek and is cross-module, so @compile :inline can't reach it.
  ~7 kind-peeks per token (clause-head lookahead, skip_eols, no-parens-arg checks all re-peek). Two levers: a cross-module-inlinable read (a kind macro — the reviewer's noted higher-churn path) or
  algorithmically reducing redundant peeks. This is the biggest single lever but the fix is structural.
  2. The eol_prefix index is dead weight — Tokens.prefix/2 (1.08M words, 2.3% alloc) + eol_inc/prefix (~0.88M calls) build it on every parse, but eol_between? (its only consumer) is called nowhere. Removing
  or lazifying it is the cleanest win available: ~2% allocation + ~2.6% of calls, zero behavior risk. (I flagged it last pass; it's now visibly in the top-10 of both calls and allocations.)
  3. lists:keyfind/3 — 1.4M calls from Keyword.get(opts, :range/:literal_encoder/:existing_atoms_only) re-queried per node. Cheap on the default empty-opts path but pure call overhead. Fix: resolve the flags
  once into compact threaded values instead of a keyword lookup per node.
  4. lex/6 token tuples (17.8% alloc) and read_name/word_len name scanning (~10%) are largely inherent — one tuple per token, the name binary is the token value. Attacking these means a leaner
  token/representation change (high churn, the reviewer's "representation cleanup").
  5. Per-byte scanners (plain_run_len, skip_to_eol, word_len) are inherent to lexing — each call is trivial; the count just reflects byte volume.

  If you want me to act: #2 (kill the dead eol index) is the no-risk cleanup, #3 (resolve opts once) is low-risk, and #1 (Tokens.kind) is the high-leverage-but-structural one (a kind/token macro is the
  realistic route, A/B-measured). Want me to take #2 and #3?

  - #5 metadata fast-mode and #6 CST span/state flattening: the bigger levers, but #5 changes product semantics (only helps opt-in meta-less callers, not the default oracle comparison) and #6 is broad churn.

Yes, there is still safe perf headroom, but it is now incremental. The benchmark is honest: current median is `t2_full 1.561x oracle`, `alloc 1.082x`. That is close enough that changes need A/B measurement, not intuition.

**Inlining**
There is space for inlining, but keep it narrow.

Good candidates:

```elixir
# lib/toxic2/lexer.ex
@compile {:inline,
  rest_at: 2,
  kw_suffix: 1,
  kw_colon?: 1,
  match_op: 1,
  lookup_op: 2,
  reserved_token: 4
}
```

Maybe candidates after measurement:

```elixir
# lib/toxic2/parser.ex
@compile {:inline,
  merge: 2,
  merge_tt: 3,
  merge_ct: 3,
  merge_tc: 3
}

# lib/toxic2/lower.ex
@compile {:inline,
  tmeta: 2,
  op_atom: 2,
  op_meta: 2,
  span_meta: 1
}
```

Avoid inlining recursive scanners (`lex/6`, `word_len/2`, `read_name/1`, `consume_eols/4`, `plain_run_len/4`) and large multi-branch parser routines. That risks code growth and worse i-cache behavior.

Important caveat: `@compile {:inline, kind: 2}` inside `Toxic2.Tokens` will not inline calls from `Toxic2.Parser`. It only helps local calls in that module. Cross-module hot helpers need either local wrappers or macros, and macros are higher churn.

**Safer Next Optimizations**

1. Inline the tiny local helpers above and A/B with `mix toxic2.bench --reps 20 --json`. Keep only changes that improve median and p95.

2. Add direct token-field helpers where spans are still allocated:
   `Tokens.start_line/2`, `start_col/2`, `end_line/2`, `end_col/2` or parser-local tuple matching. Current `merge_*` is good; finish replacing remaining `tok_span/cst_span` fallbacks only where hot.

3. Revisit `Toxic2.Tokens.from_list/1`.
   It builds both token tuple and EOL prefix with `Enum.reduce`, `:lists.reverse`, `List.to_tuple`. Fine architecturally, but it is still visible in allocation. A hand-recursive builder may shave a little without grammar risk.

4. Lexer operator path can still be tightened:
   after the fused dispatch, `match_op/lookup_op/binary_part` are still likely hot. A direct binary pattern match for the most common 1- and 2-char operators (`.`, `,`, `(` etc. already dedicated; `=`, `|>`, `->`, `::`, `+`, `-`, `/`) may beat map lookup. This is safe but tedious; benchmark per batch.

5. Metadata mode is the bigger lever, but it changes product semantics:
   `metadata: false | :line | :line_column` could probably beat `1.5x`, but default oracle-style AST still pays metadata allocation. Treat it as an opt-in fast mode, not a fix for default perf.

I would do inlining first because it is low risk and reversible. Expected gain is small, probably `1–3%`. Getting from `1.56x` to `<1.5x` likely needs inlining plus one representation/path cleanup, not inlining alone.

---

## Re-profile + A/B (current tree, after token-access/eol-prefix/opts/CST.token fixes landed)

**Current baseline (median over reps-20 runs, ratio normalizes load): `t2_full ≈ 1.36x` oracle,
allocations `≈ 1.015x`.** The ≤1.5× target is MET. `keyfind`, `Tokens.kind`, `Tokens.prefix` are
gone from the profile (those fixes landed). The current call-count top is now dominated by INHERENT
work — per-byte lexer scanners (`plain_run_len` 5.6%, `skip_to_eol` 5.2%, `word_len` 4.5%) and
`lex/6` (token 6-tuples, ~19% of allocation) — none cleanly removable. The only non-inherent
category left is the small cross-module CST/Tokens accessors (`CST.tag`, `CST.token_index`,
`Tokens.value`, …), concentrated in `Lower`.

**A/B result — GPT item #2 (Lower-local CST accessors): NO measurable win, reverted.** Inlined the 5
hottest CST accessors (`tag`/`token_index`/`node_kind`/`children`/`span`, ~42 sites) as local
helpers in `Lower`. Median `t2_full` went 1.363 → 1.368 — within the ±1.2% noise band (if anything
slightly worse from code growth). Same lesson as the earlier `Tokens.kind` inline: a tiny function's
**call-count %** is inflated by tracing overhead and overstates its wall-time cost; the BEAM JIT
handles small cross-module calls fine. Reverted (the CST-shape coupling / readability cost buys
nothing).

**Conclusion: we're at the inherent floor (~1.36×, alloc ~1.015×).** Since the LARGEST remaining
non-inherent lever (#2) measured ~0%, the smaller ones — #1 (remaining `tok_span` fallbacks), #3
(default-opts fast path: branches are cheap map reads), #4 (adjacency inlining: not in the hot
profile) — are very unlikely to clear the noise floor and aren't worth the churn. Kept: `CST.inherit`
flag propagation (tested CST contract + tooling-useful, allocates nothing). Further real gains would
need a representation change (CST span/state flattening, token rep) — high churn, shrinking returns,
explicitly deferred. Metadata fast-mode remains a feature, not default-perf work.
