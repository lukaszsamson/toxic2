# Performance audit — 2026-09-06

Audited `c924fcf690d0ef0b5efc984e4d9500899e683085`, including production BEAM disassembly, `tprof` call-time/call-memory profiles, scaling tests, and isolated A/B prototypes. Production source was not edited. Runtime: Elixir 1.21.0-dev (`2e9ce85`), OTP 28 / ERTS 16.4.0.1, JIT, 12 schedulers.

The ≤1.5× headline still holds, but the remaining work is **not all irreducible correctness overhead**. There are four demonstrated quadratic paths, a binary-scanner deoptimization, avoidable comment work, and some useful inlining candidates. These do not require removing correctness checks or changing the CST architecture.

**Baseline and measurement limits.** `MIX_ENV=prod mix toxic2.bench --reps 10 --json`, 105 oracle-valid stdlib files, 3,494,298 bytes:

| Stage | Median ms | p95 ms | Minimum ms | Allocation proxy MB |
|---|---:|---:|---:|---:|
| Lex | 142.28 | 145.04 | 139.75 | 192.94 |
| Lex + parse | 228.67 | 237.59 | 222.32 | 303.65 |
| Full | 277.05 | 309.43 | 272.11 | 361.98 |
| Oracle | 193.13 | 200.31 | 188.44 | 363.36 |

Full: **1.435× time / 0.996× allocation proxy**. The existing benchmark compares Toxic2's default line+column metadata with the oracle's default line metadata; this is not the full-token-metadata comparison.

The A/B experiments below used renamed modules, shuffled arms over 15 rounds, fresh processes, and warm-up passes. Scaling experiments used seven samples. Parser/lower-only measurements used prepared token views/CSTs. Their absolute times are not interchangeable with cumulative stage differences in the official harness. Improvements across experiments must not be added together. `tprof` timings are instrumented and were used to rank work, not as uninstrumented stage times. Heap-word statistics do not measure all off-heap binary payload allocation or copying traffic.

**1. Unicode literal readers repeatedly copy the remaining source — highest-priority lexer scaling fix.**

Locations: [lexer.ex:1329](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:1329), [lexer.ex:1675](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:1675), [lexer.ex:1921](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:1921), [lexer.ex:2254](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:2254).

Each Unicode fallback reconstructs `<<c::utf8, rest::binary>>` before calling `gc_step/2`. `gc_step_slow/2` additionally constructs `<<prev::utf8, bin::binary>>` to test whether the next character extends the previous grapheme. These include the unconsumed source, potentially far beyond the literal. Repetition sums the lengths of the remaining tails: quadratic copying.

BEAM confirms both operations survive compilation: `bs_get_tail` followed by `bs_create_bin` with a UTF-8 segment and a binary segment sized `:all`. This is an actual full binary construction, distinct from a shared sub-binary.

An isolated prototype passed the existing binary into `gc_step` and used `uu_gc([prev | bin])` for the previous-codepoint probe:

| Quoted content, 32,000 repetitions | Current lex ms | Prototype lex ms |
|---|---:|---:|
| `é` | 27.825 | 2.542 |
| `漢` | 78.273 | 8.131 |
| `e` + combining acute | 81.020 | 8.390 |
| `👩‍💻` | 794.234 | 11.184 |

The prototype scales approximately linearly over 4k–32k inputs. However, on the stdlib corpus its lex median was slightly worse (130.57 → 132.25 ms) and traced heap words increased 1.6%. **Do not land that prototype unchanged.** Preserve the ASCII match-context fast paths while removing Unicode tail copies, potentially by passing the decoded head and remaining binary separately. Keep combining-mark, emoji, escape-boundary, invalid-UTF-8 and interpolation behavior intact.

**2. The lazy source-line index is rebuilt per empty-parenthesis check — quadratic default lowering.**

Locations: [lower.ex:197](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:197), [lower.ex:1823](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:1823).

`src_slice` resolves `{:lazy, source}` into a new options map, but only its recursive slice call receives that map. The enclosing traversal retains the original lazy options. Every later `(;)`/empty-paren check splits and scans the whole source again. The comment saying “Build them once” is incorrect across calls.

BEAM shows `source_lines/1`, `ascii_lines/2`, and `put_map_exact` on each lazy invocation; only the slice result returns.

| Repeated `(;)\n` expressions | Current lower-only ms | Build-once prototype ms |
|---|---:|---:|
| 1,000 | 23.408 | 0.249 |
| 2,000 | 99.644 | 0.356 |
| 4,000 | 430.659 | 1.082 |
| 8,000 | 1,664.733 | 1.433 |

These are valid semicolon blocks, avoiding warning construction as a confounder. The eager prototype establishes causality, not the final default policy. Prefer recording the semicolon distinction during parsing, using the available tokens, or resolving the index once when the CST requires it. Avoid restoring an unconditional split for ordinary default parsing without benchmarking it.

**3. Mixed-Unicode metadata scans are quadratic and no longer allocation-free per byte.**

Locations: [lower.ex:354](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:354), [lower.ex:375](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:375), [lower.ex:1041](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:1041), [lower.ex:1047](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:1047).

After a position passes a line's leading ASCII prefix, `line_probe`/`col_byte` restart from the beginning of the line. Many metadata queries at increasing columns repeatedly traverse the same prefix: O(number of queries × column). A single early non-ASCII character is sufficient; the remaining text can be ASCII.

In addition, the ASCII clauses in `line_walk/3` and `col_byte_walk/3` use `binary_part(bin, 1, byte_size(bin) - 1)` at every step. The current BEAM sequence is:

```text
bs_get_tail
gc_bif binary_part
... decrement column / advance offset ...
call_only line_walk/3    # or col_byte_walk/3
```

The recursive entry uses `bs_start_match3`. The source comments claiming one reused match context with zero per-step allocation no longer describe this code. This materializes tails; it does not necessarily copy their entire payloads as finding 1 does.

Measured lower-only with `token_metadata: true`, input `"é"; ` followed by repeated `x; ` on the same line:

| Statements | Median ms | Process reductions |
|---|---:|---:|
| 500 | 14.830 | 788,035 |
| 1,000 | 58.130 | 3,076,111 |
| 2,000 | 226.242 | 12,146,721 |
| 4,000 | 1,031.365 | 48,497,391 |

First restore match-context-friendly recursion for ASCII steps, checking the generated instructions. For the asymptotic problem, use reusable byte offsets or a sparse grapheme-position index on mixed lines. Merely skipping the known ASCII prefix improves constants but remains quadratic after it. Position mapping must preserve the lexer's contextual Unicode-column semantics.

**4. Alias-chain extension copies and rescans all accumulated children.**

Locations: [parser.ex:948](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/parser.ex:948), [cst.ex:184](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/cst.ex:184).

Each `.Alias` runs `Enum.concat(segs, [new_segment])` and builds a fresh `CST.node/5`. Concatenation copies the growing prefix; `inherit/2` then walks that growing list again. BEAM retains the external concat and constructor calls. The final flat representation is reasonable; its incremental construction is quadratic.

Prepared-token parse of `A.A.A...`: 500 segments → 0.512 ms; 1,000 → 1.902 ms; 2,000 → 8.509 ms; 4,000 → 37.006 ms. Corresponding reductions grow from 144k to 8.43M. Normal short aliases make this a smaller practical priority than findings 1–3.

Gather a contiguous alias run in reverse, reverse once, and construct its CST once. Retain existing behavior for newline-after-dot, remote-member, multi-alias and recovery transitions. No alias prototype was implemented in this audit.

**5. Default tokenization collects comments that its caller immediately discards.**

Locations: [lexer.ex:195](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:195), [lexer.ex:338](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:338), [lexer.ex:2201](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lexer.ex:2201).

`tokenize/2` calls `tokenize_with_comments/2`. Every comment constructs `"#" <> body`, its six-field tuple, a notice-list cell, and computes the following newline count. The stream is then partitioned and reversed before comments are discarded. The lookahead also duplicates whitespace/newline work done by normal lexing. BEAM contains the binary construction and comment tuple allocation.

Suppressing only collection in a prototype, retaining lint and column accounting, changed stdlib lex median 130.57 → 128.55 ms (**1.5%**) and traced heap words 25,226,728 → 24,866,413 (**1.4%**). Make collection explicit at the comments API boundary. The prototype intentionally does not preserve the comments-returning API and is not a shippable replacement for it.

**6. Targeted inlining has measurable candidates; blanket inlining does not.**

The baseline profile counted 173,003 `read_name/1` calls, 178,290 `bang_before_eq_notice/6` calls, and 1,092,693 `Parser.skip_eols/2` calls per stdlib pass. Small wrapper calls and returned intermediate tuples remain visible in BEAM.

| Isolated experiment | Stage median before → after | Interpretation |
|---|---:|---|
| Inline lexer `read_name/1`, `bang_before_eq_notice/6`, `dot_member_split/2` together | 130.57 → 127.34 ms lex | Promising: 2.5%; traced lex heap words −3.4% |
| Inline parser `skip_eols/2` | 111.92 → 105.74 ms prepared parse | Promising: 5.5% in this harness; reductions slightly increased |
| Inline lowerer `atomize/7` | 43.37 → 43.94 ms default lower | No demonstrated default wall-time gain; heap words −3.6% |
| Move unused leaf metadata into consuming branches/closures | 42.20 → 42.76 ms default lower | No demonstrated wall-time gain; heap words −0.7% |
| Replace `lex_lower_no_kw`'s `@` binary-head test with a guarded `binary_part` check | 130.57 → 138.33 ms lex | Reject this rewrite: slower |

The lexer experiment combines three changes: its gain cannot be assigned to one helper without separate measurements. Run full-pipeline A/B and the grammar gates before shipping any of these. Large recursive-function inlining can change code size and register/heap behavior enough to offset fewer calls.

**7. Remaining closure and duplicated-metadata allocations are real, but lower priority.**

At [lower.ex:443](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:443), the identifier/alias builders capture `meta` and pass a fun to `atomize/7`. BEAM shows `make_fun3` with a captured register and `call_fun2` in `atomize`; the profile has 87,423 calls. Inlining `atomize` removes those closure constructions and dynamic calls, although a direct generated helper call remains. The allocation reduction above is confirmed; wall-time benefit is not.

At [lower.ex:433](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex:433), `tmeta |> maybe_token_range` runs before dispatch even for plain numeric/literal/atom branches that do not consume this `meta`. BEAM constructs the line/column tuples and cons cells before `select_val`. Moving construction into a captured fun enlarges that fun's environment, partially offsetting the saving. Specializing the two atom builders plus branch-local metadata is a better next experiment than moving the allocation mechanically.

`quoted_parts_ast/5`, `lower_stmts/5` and `lower_do_block/5` also retain capturing `Enum.reduce` closures. They are less urgent than the central leaf path; do not treat every `Enum` use as a problem. Likewise, `Tokens.has_cont?/1` adds a 488,723-call pass before tuple conversion. Lexer-produced summary flags could eventually avoid it and the source/token scans for Unicode lint, but plumbing must earn its cost in a full benchmark.

**What is already BEAM-friendly.** `plain_run_len/4` uses `bs_start_match4 :resume` and `call_only`, with no per-byte binary construction. `word_len/2` tail-recurses through its match context and creates its returned tail/tuple at termination, not per character. `depth_delta/1` compiles to `select_val`. `lower_each/6` is already an explicit recursive traversal. Token tuples, CST flags, scalar parser counters, reverse accumulators and the existing single-fragment string path are reasonable. The large apparent profiler cost of these loops is not by itself evidence that they need replacing.

Numeric scanning already fuses digit validation with recognition. `strip_underscores` still rescans recognized digits, so returning an underscore-presence flag is a small candidate, not a demonstrated gain. Most of the apparent `Enum` and concatenation work in the Unicode table generator happens at compile time and should not be counted as runtime lexing work.

**Validation and next implementation order.** Lexer prototypes and the parser-inline prototype matched current outputs on 8,910 curated/imported entries plus 1,000 deterministic generated inputs, including invalid bytes, Unicode and escape fragments. Lexer prototypes also matched 105 stdlib files. The two lowerer experiments matched those 105 files in default, token-metadata, range, existing-atoms-only and literal-encoder modes; explicit missing-atom cases matched too. Unicode scaling samples and eager-lower samples had exact before/after output comparisons. This is differential prototype validation, not a claim that the 1,102-test suite or both grammar harnesses were rerun, nor a new oracle-conformance claim.

Prioritize the Unicode copying and source-index rebuild, then mixed-line metadata scanning. Follow with comment gating and isolated inlining measurements. Fix alias accumulation when addressing pathological scaling. Keep timing-only micro-optimizations that failed A/B out of the production patch.

**Reproduction artifacts.** Scripts, generated prototype modules, complete BEAM dumps and raw logs are in [/tmp/toxic2-perf-audit](/tmp/toxic2-perf-audit), preserved in the [evidence archive](/tmp/toxic2-perf-audit-20260906.tar.gz). From the repository root:

```sh
MIX_ENV=prod mix compile
elixir -pa _build/prod/lib/toxic2/ebin /tmp/toxic2-perf-audit/profile.exs
elixir -pa _build/prod/lib/toxic2/ebin /tmp/toxic2-perf-audit/scaling.exs
elixir -pa _build/prod/lib/toxic2/ebin /tmp/toxic2-perf-audit/variants.exs
elixir -pa _build/prod/lib/toxic2/ebin -pa /tmp/toxic2-perf-audit /tmp/toxic2-perf-audit/ab.exs
elixir -pa _build/prod/lib/toxic2/ebin /tmp/toxic2-perf-audit/lower_ab.exs
elixir -pa _build/prod/lib/toxic2/ebin /tmp/toxic2-perf-audit/more.exs
elixir -pa _build/prod/lib/toxic2/ebin -pa /tmp/toxic2-perf-audit /tmp/toxic2-perf-audit/validate.exs
elixir -pa _build/prod/lib/toxic2/ebin -pa /tmp/toxic2-perf-audit /tmp/toxic2-perf-audit/alloc.exs
```

Run timing commands sequentially. The scripts use this machine's stdlib path. Compiler-generated line-table indices in raw disassembly are not source line numbers; source links above refer to the audited revision.
