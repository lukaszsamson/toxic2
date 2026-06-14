claude:

Stepping back. Here's an honest accounting and a grounded recommendation. I checked the current state to avoid asserting from memory.

  What's actually achieved

  A complete, tolerant-only Elixir lexer → CST parser → AST lowering, validated against the live oracle (Code.string_to_quoted), not captured expectations:
  - Correctness: curated 521, imported parser 4689 / lexer 774, 294-package OSS corpus, a 34k-file home-dir scan at 0 mismatches, ~180 realistic constructs pinned. All 13 migration phases done.
  - Totality (P5): lexer/parser/lower never raise — verified by fuzzing truncations, deletions, random bytes, invalid UTF-8.
  - Source ranges (range: true) with the parent-contains-children invariant, plus an Elixir-compatible literal_encoder.
  - Atom safety: existing_atoms_only gates every source-derived name.
  - Perf: ~1.38× oracle wall-time (under the 1.5× target), allocations ~1.01× — measured, A/B'd.
  
  That's a strong, correct, fast core. What it is not yet is a tooling-grade parser — and that gap is where your four candidates live.

  The four candidates, assessed (with measured facts)

  1. Diagnostics / warnings — biggest functional gap. toxic2 emits exactly one warning (:deprecated_not_in); the lexer emits zero. Elixir's tokenizer/parser emit a dozen+ (ambiguous pipe, unnecessary quotes,
  single-quoted-charlist deprecation, missing parens in keywords, ? escape warnings…) — you saw them flood the conformance output. The old toxic/toxic_parser had warning suites; I harvested the input
  snippets (phase-12) but never the emission. Value: high for any compiler-frontend/linter use. Effort: medium (per-warning detection). Risk: low — warnings are additive, don't touch the AST or conformance.
  
  2. Token-metadata parity — incomplete, and it's the formatter's blocker. Measured just now: for if x do y end the oracle emits [:do, :end, line, column]; toxic2 emits [:range, line, column]. For
  foo(a,b)/%{a: 1} the oracle has :closing; toxic2 has only :range. Missing: do:/end:/closing:/delimiter:/newlines:/end_of_expression:. The data exists in the CST spans — this is mostly a lowering-emission
  feature. Value: high if the consumer is a formatter / Sourceror-style refactoring tool. Effort: medium. There's a design decision here: toxic2 deliberately chose a clean uniform range: over Elixir's
  scattered keys — do you want both (true parity) or keep range-first?

  3. Error tolerance — present but shallow. The parser is total and emits error diagnostics + a best-effort AST, and the recovery property test pins the contract. But it doesn't test recovery quality (does
  the partial AST stay useful for an LSP after an error?), there's no strict-mode wrapper (the spec says "strict is a wrapper over the tolerant core" — not built), and error messages aren't oracle-parity
  (deliberately — the spec says don't assert reference strings). Value: high for editor/LSP use. Effort: medium-high.
  
  4. Differential fuzzer — the spec's own unchecked box. Today's fuzzing only checks totality (no crash). The spec's Test Strategy explicitly lists "Differential fuzzing: generated valid programs compare AST
  vs reference" — that doesn't exist yet. The old toxic_parser had StreamData generators; phase-12 imported their recorded failures but not a live generator. Value: highest correctness leverage — it would
  automatically hunt the remaining obscure gaps instead of relying on curated corpora. Effort: medium (port a generator; needs the stream_data dep). Risk: low.
  
  Recommendation

  The ordering hinges on one question: who consumes this parser? It changes everything:

  - If the goal is editor/LSP/formatter tooling (which the CST + ranges + literal-encoder design strongly implies): do #2 token-metadata parity and #3 error-recovery quality + strict wrapper first — they're
  the actual blockers for Sourceror/formatter/LSP integration. #1 warnings second (linters).
  - If the goal is a compiler frontend / drop-in Code.string_to_quoted replacement: #1 warnings is the parity gap that matters most, then #2.
  - Regardless of goal, I'd slot #4 the differential fuzzer in first or early — it's the cheapest, lowest-risk multiplier: it locks down everything you've built and surfaces real gaps for the others. It's
  also the one item the spec explicitly still calls for.

  My concrete proposal: (a) build the differential fuzzer now (small, de-risks the rest, closes a spec gap), then (b) decide #2 vs #1 based on the consumer. If you don't have a specific consumer yet, #2
  (token metadata) is the highest-leverage feature because it unlocks the whole formatter/refactoring tooling class and the data's already in the CST.

  What's the intended consumer — editor/LSP tooling, a formatter, or a compiler-frontend replacement? That answer picks #2 vs #1; the fuzzer (#4) I'd recommend either way. I can start on the fuzzer
  immediately if you agree.

  gpt:

  You achieved the thing the first project failed to converge on: a tolerant-only parser with valid-code AST parity, a simpler architecture, and performance now inside the original target without abandoning CST/lowering.

The important shift is that performance was not fixed by changing algorithms. It was fixed by making the BEAM execution model explicit: flat tokens, batch lexing, integer cursor, no deferrals, local hot helpers, fewer cross-module calls, and no dead prefix index. That validates the redesign.

**What This Means**
I would call the core parser project “functionally successful” for valid code:

- Valid realistic Elixir: effectively covered.
- Corpus parity: strong enough to trust.
- Performance: no longer disqualifying.
- Architecture: still understandable, not a patch stack.
- Fuzzer backlog: now a triage input, not the boss.

The next mistake would be to move the old impossible goals back into scope.

**Next Steps**
1. Stabilize the contract.
   Write down the public guarantees now: token shape, CST shape, AST lowering options, diagnostic tuple shape, range semantics, atom policy, and tolerant behavior. This prevents future agents from “improving” the design back into complexity.

2. Build diagnostics deliberately.
   Do **not** chase Elixir error-message parity. Build your own diagnostics with stable codes, source ranges, severity, and recovery notes. Good target: “useful for editor/tooling”, not “byte-identical to `Code.string_to_quoted`”.

3. Add warning support selectively.
   Warnings are worth doing only where they are cheap and useful:
   deprecated `not in`, single-quoted charlists, ambiguous no-parens, trailing comma, quoted atom/call warnings. But make warnings a separate pass or clearly separated lowerer/parser diagnostics. Do not let warning parity infect parsing.

4. Avoid token metadata parity as a goal.
   Token metadata parity is a trap unless a consumer needs it. You already have ranges and line/column. If needed, add explicit opt-ins like `range: true`, `literal_encoder`, maybe `metadata: :elixir_compatible`, but keep default focused on AST shape and useful source locations.

5. Improve error tolerance quality.
   This is the best next product area. Create invalid-code fixtures grouped by recovery scenario:
   missing closers, broken strings/heredocs, incomplete do/end, bad operators, interrupted calls, broken bitstrings, bad interpolation. Assert:
   no crash, forward progress, bounded diagnostics, useful partial AST, localized recovery.

6. Reframe fuzzing.
   Use fuzzers for:
   totality,
   no atom leaks,
   no infinite loops,
   bounded runtime,
   diagnostic locality,
   valid-code counterexamples.

   Do not blindly chase every oracle-valid fuzzer AST mismatch. Bucket them into “real grammar island”, “cheap harmless parity”, and “yecc artifact / no practical value”.

7. Keep perf guarded, not obsessed over.
   Add a non-blocking perf report or loose CI guard with historical JSON. You are under target now; further work should need a concrete consumer or a clear measured regression. CST flattening and metadata modes can wait.

**Priority Order**
I’d do:

1. Public contract docs.
2. Diagnostic codes/ranges quality.
3. Invalid-code recovery corpus.
4. Warning subset.
5. Fuzzer invariant harness.
6. Only then revisit exotic parity gaps.

The main thing: stop treating `Code.string_to_quoted` as the product for invalid code. It is only the oracle for valid AST shape. For everything else, Toxic2 should now define its own better contract.
