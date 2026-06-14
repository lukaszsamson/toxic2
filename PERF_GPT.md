The realistic perf story changed: [PERF.md](/Users/lukaszsamson/claude_fun/toxic2/PERF.md) is partly stale because the best ideas already landed. Current bench on my run is `t2_full/oracle = 1.38x` median, allocations `1.015x` oracle. So the original `<=1.5x` target is met on the measured corpus; remaining work is incremental and should be profile-gated.

The next changes that can still realistically deliver:

1. **Finish direct span plumbing**
   There are still some `Tokens.span(...)` paths in [parser.ex](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/parser.ex) and likely [lower.ex](/Users/lukaszsamson/claude_fun/toxic2/lib/toxic2/lower.ex). Since span allocation was already proven costly once, replacing remaining hot span reads with local tuple-field helpers is the safest next cleanup. Expected gain: small but real, maybe `1-2%`.

2. **Lower-local token/CST accessors**
   Parser got the big win from local inlined token reads. Lower still does more cross-module `Tokens.*` / `CST.*` work. It is a smaller phase now, but worth A/B testing with local helpers for token kind/value/span and CST tag/span access. Expected gain: probably `1-3%`, low semantic risk, some readability cost.

3. **Specialize default lowering opts**
   The opts map fixed `Keyword.get`, but default parse still pays branches like `opts.range`, `opts.literal_encoder`, etc. A default fast lowering path for the common case could help without changing public semantics. Expected gain: uncertain, maybe `2-4%` if those branches are hot. Risk: duplication if done carelessly.

4. **Inline adjacency/span comparisons in parser hotspots**
   If current profiling still shows adjacency helpers or span extraction in hot loops, inline those over flat token tuples. This is the same kind of win as `tk/tv/tt`: boring, local, measurable.

What I would **not** prioritize now:

- **Metadata fast-mode**: useful as a feature, not as default perf work. It will not improve the oracle-comparable default path unless you change semantics.
- **CST span flattening**: probably can save allocations, but now that allocation is near parity, the churn/risk is hard to justify.
- **Token representation overhaul**: high risk for shrinking returns.
- **Fusing parser + lower / direct AST path**: this undermines the architecture that made the rewrite converge.

My recommended next step is to update [PERF.md](/Users/lukaszsamson/claude_fun/toxic2/PERF.md) with the current baseline, then rerun `tprof` call-count and call-memory on the latest tree. Pick only items that still appear in the current top list. At this point, a realistic target is not “another big leap”; it is shaving `3-7%` while preserving the clean tolerant-parser design.
