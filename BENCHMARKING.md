# Toxic2 — benchmarking & profiling guide

How to reproduce every measurement used in the perf work, plus the current numbers.
(Untracked working doc, like PERF.md. Commit if you want it tracked.)

## Paths / environment

- Project dir: `/Users/lukaszsamson/claude_fun/toxic2` (run all `mix` commands here)
- Elixir stdlib corpus: `/Users/lukaszsamson/elixir/lib/elixir/lib`
- Wide OSS corpus: `/Users/lukaszsamson/claude_fun/elixir_oss/projects` (~13.5k files, 30 projects)
- Erlang `:tools` (tprof/eprof) ebin — NOT on `mix run`'s path by default; add it in scripts:
  `:code.add_patha(~c"/Users/lukaszsamson/.asdf/installs/erlang/28.5.0.1/lib/tools-4.1.4/ebin")`
  (bump the version if the asdf erlang install changes)
- Always build/run in prod for perf: `MIX_ENV=prod`

## Current numbers (HEAD `0ff99fc`, 2026-06-14)

Ratio = toxic2 wall / live-oracle wall, **matched output**, fresh process per iteration, median.
"default" = `[line, column]` meta (oracle `Code.string_to_quoted/1`); "tm" = full token_metadata
(toxic2 `token_metadata: true` vs oracle `token_metadata: true, columns: true`).

| corpus            | default | token_metadata |
|-------------------|---------|----------------|
| Elixir stdlib     | 1.29x   | 1.44x          |
| Wide OSS (sample) | 1.32x   | 1.59x          |

Allocation (tprof words, toxic2 / oracle): **default 0.98x** (below oracle); **tm ~1.12x** (above).
The AST (incl. metadata keyword lists) is byte-identical to oracle, so the lists are NOT the cause —
the extra is toxic2's intermediate **green CST + the lowering pass + `source_lines` line-split**,
which oracle's direct yecc build doesn't pay (architectural, not waste). CPU/reductions is the binding
constraint, not allocation.

Official stage breakdown (`mix toxic2.bench`, stdlib, default): t2_lex ~0.60x, t2_parse ~0.95x,
t2_full ~1.30x oracle; alloc ~0.98x. Stage split ~45% lex / 26% parse / 29% lower.

Dense test/data files (witchcraft benches, decimal/string/enum tests, gen_lsp enums) sit at the
~2.4-2.8x tm "plateau" — no single hotspot left; it's the shared lex/parse floor + per-node tm meta.

## A. Built-in mix tasks

```sh
cd /Users/lukaszsamson/claude_fun/toxic2

# Official corpus benchmark (stdlib default). Fresh process per stage, shuffled, median+p95+min,
# allocation per stage. --dir to change corpus, --reps N, --top N for slowest files, --json.
MIX_ENV=prod mix toxic2.bench
MIX_ENV=prod mix toxic2.bench --dir /path/to/corpus --reps 20

# Correctness gates (run after any change):
mix toxic2.check                 # format + guard + credo + tests + frozen conformance (exit 0 = ok)
mix toxic2.conformance --gate    # 521 frozen curated cases
TOXIC2_OSS_DIR=/Users/lukaszsamson/claude_fun/elixir_oss mix toxic2.conformance.oss  # 5393 OSS files
mix test                         # unit tests (incl. token_metadata parity, confusable, etc.)
```

## B. Wall-clock ratio (stdlib + OSS, default + tm)

`/tmp/ratios.exs` — fresh process per iteration (GC state must NOT bleed between arms), median.

```elixir
valid? = fn s -> match?({:ok,_}, (try do Code.string_to_quoted(s) rescue _ -> :e catch _,_ -> :e end)) end
load = fn dir, every -> Path.wildcard(Path.join(dir, "**/*.{ex,exs}")) |> Enum.reject(&String.contains?(&1, ["/deps/","/_build/","/node_modules/"])) |> Enum.sort() |> Enum.take_every(every) |> Enum.map(&File.read!/1) |> Enum.filter(valid?) end
stdlib = load.("/Users/lukaszsamson/elixir/lib/elixir/lib", 1)
oss = load.("/Users/lukaszsamson/claude_fun/elixir_oss/projects", 6)
run = fn srcs, fun -> p=self(); pid=:erlang.spawn_opt(fn -> t=System.monotonic_time(:microsecond); Enum.each(srcs,fun); send(p,{:d,self(),System.monotonic_time(:microsecond)-t}) end,[min_heap_size: 2_000_000]); receive do {:d,^pid,us}->us after 300_000->raise "to" end end
med = fn srcs, fun, n -> _=run.(srcs,fun); (for _<-1..n, do: run.(srcs,fun))|>Enum.sort()|>Enum.at(div(n,2)) end
b = fn label, srcs, n ->
  t2d=med.(srcs,&Toxic2.parse_to_ast/1,n); ord=med.(srcs,&Code.string_to_quoted/1,n)
  t2t=med.(srcs,&Toxic2.parse_to_ast(&1,token_metadata: true),n); ort=med.(srcs,&Code.string_to_quoted(&1,token_metadata: true,columns: true),n)
  IO.puts("R #{label}: default #{Float.round(t2d/ord,2)}x | tm #{Float.round(t2t/ort,2)}x")
end
b.("stdlib", stdlib, 11)
b.("oss", oss, 7)
```

Run: `MIX_ENV=prod mix run /tmp/ratios.exs 2>&1 | grep '^R '`

## C. A/B a change (back-to-back, drift-resistant)

Measure WORKING tree, then `git stash` to measure BASE, then `git stash pop`. Compare **min** of
many iterations (cancels load). The harness uses a fresh process per iteration.

```elixir
# /tmp/ab.exs — edit `srcs` to target the relevant files
corpus = "/Users/lukaszsamson/elixir/lib/elixir/lib"
srcs = Path.wildcard(Path.join(corpus, "**/*.{ex,exs}")) |> Enum.sort() |> Enum.map(&File.read!/1)
  |> Enum.filter(fn s -> match?({:ok,_}, (try do Code.string_to_quoted(s) rescue _ -> :e catch _,_ -> :e end)) end)
tm = fn -> Enum.each(srcs, &Toxic2.parse_to_ast(&1, token_metadata: true)) end
m = fn -> p=self(); pid=:erlang.spawn_opt(fn -> t=System.monotonic_time(:microsecond); tm.(); send(p,{:d,self(),System.monotonic_time(:microsecond)-t}) end,[min_heap_size: 2_000_000]); receive do {:d,^pid,us}->us after 300_000->raise "to" end end
_=m.(); ts=(for _<-1..21, do: m.())|>Enum.sort()
:io.format("median ~7.1f ms  min ~7.1f ms~n",[Enum.at(ts,10)/1000, hd(ts)/1000])
```

```sh
echo "WORKING:" && MIX_ENV=prod mix run /tmp/ab.exs 2>&1 | tail -1
git stash -q && MIX_ENV=prod mix compile 2>&1 >/dev/null
echo "BASE:"    && MIX_ENV=prod mix run /tmp/ab.exs 2>&1 | tail -1
git stash pop -q && MIX_ENV=prod mix compile 2>&1 >/dev/null
```

## D. eprof — TIME profile (find CPU hotspots)

Use this AFTER de-slicing/allocation work: a zero-alloc walk can still be a CPU hog.

```elixir
:code.add_patha(~c"/Users/lukaszsamson/.asdf/installs/erlang/28.5.0.1/lib/tools-4.1.4/ebin")
corpus = "/Users/lukaszsamson/elixir/lib/elixir/lib"   # or a single outlier file (see G)
sources = Path.wildcard(Path.join(corpus, "**/*.{ex,exs}")) |> Enum.sort() |> Enum.map(&File.read!/1)
  |> Enum.filter(fn s -> match?({:ok,_}, (try do Code.string_to_quoted(s) rescue _ -> :e catch _,_ -> :e end)) end)
fun = fn -> Enum.each(sources, &Toxic2.parse_to_ast(&1, token_metadata: true)) end
fun.()
:eprof.start(); {:ok,_}=:eprof.profile([], fun); :eprof.stop_profiling(); :eprof.analyze(:total, sort: :time)
```

Run: `MIX_ENV=prod mix run /tmp/eprof.exs 2>&1 | grep -vE "warning|deprecated|└─|^$" | tail -25`

## E. tprof — ALLOCATION profile (exact, deterministic, drift-immune)

```elixir
:code.add_patha(~c"/Users/lukaszsamson/.asdf/installs/erlang/28.5.0.1/lib/tools-4.1.4/ebin")
# ... build `sources` and `fun` as in D ...
fun.()
{_res, {:call_memory, traces}} = :tprof.profile(fun, %{type: :call_memory, report: :return})
total = traces |> Enum.map(fn {_m,_f,_a,[{_p,_c,w}]} -> w end) |> Enum.sum()
IO.puts("total words: #{total}")
traces |> Enum.map(fn {m,f,a,[{_,c,w}]}->{w,c,m,f,a} end) |> Enum.sort(:desc) |> Enum.take(30)
  |> Enum.each(fn {w,c,m,f,a}-> :io.format("~10w w ~9w c  ~w:~w/~w~n",[w,c,m,f,a]) end)
```

Row shape: `{module, fun, arity, [{pid, calls, words}]}`. `report: :return` is exact under tracing.
Use this (not wall time) to A/B allocation-only changes — it's deterministic.

## F. Rerank — find worst files (the lever that found passes 18-21)

Ranks every OSS file by toxic2/oracle **reductions** (deterministic CPU proxy, no reps needed).
Then `eprof` the top file ALONE (section G) — the cause is often unrelated to the file's content.

```elixir
valid? = fn s -> match?({:ok,_}, (try do Code.string_to_quoted(s) rescue _ -> :e catch _,_ -> :e end)) end
files = Path.wildcard("/Users/lukaszsamson/claude_fun/elixir_oss/projects/**/*.{ex,exs}") |> Enum.reject(&String.contains?(&1, ["/deps/","/_build/","/node_modules/"])) |> Enum.sort()
reds = fn fun -> p=self(); pid=:erlang.spawn_opt(fn -> fun.(); {:reductions,r}=:erlang.process_info(self(),:reductions); send(p,{:r,self(),r}) end,[]); receive do {:r,^pid,r}->r after 60_000->0 end end
rows = files |> Enum.flat_map(fn f -> src=File.read!(f)
  if byte_size(src) >= 400 and valid?.(src) do
    t2=reds.(fn -> Toxic2.parse_to_ast(src, token_metadata: true) end)
    o=reds.(fn -> Code.string_to_quoted(src, token_metadata: true, columns: true) end)
    [{f, byte_size(src), t2, o}] else [] end end)
short = fn f -> Path.relative_to(f, "/Users/lukaszsamson/claude_fun/elixir_oss/projects") end
IO.puts("=== WORST RATIO (size>=2KB) ===")          # density-independent outliers
rows |> Enum.filter(fn {_,b,_,_}->b>=2000 end) |> Enum.sort_by(fn {_,_,t2,o}->t2/max(o,1) end,:desc) |> Enum.take(15)
  |> Enum.each(fn {f,b,t2,o}-> :io.format("~5.2fx ~6wB ~ts~n",[t2/max(o,1),b,short.(f)]) end)
IO.puts("=== WORST PER BYTE ===")                   # densest work per byte
rows |> Enum.filter(fn {_,b,_,_}->b>=2000 end) |> Enum.sort_by(fn {_,b,t2,_}->t2/b end,:desc) |> Enum.take(10)
  |> Enum.each(fn {f,b,t2,o}-> :io.format("~6.1f r/B ~5.2fx ~ts~n",[t2/b,t2/max(o,1),short.(f)]) end)
IO.puts("=== WORST ABSOLUTE ===")                   # biggest CPU consumers (usually biggest files)
rows |> Enum.sort_by(fn {_,_,t2,_}->t2 end,:desc) |> Enum.take(8)
  |> Enum.each(fn {f,_,t2,o}-> :io.format("~10w r ~5.2fx ~ts~n",[t2,t2/max(o,1),short.(f)]) end)
```

### Allocation rerank (tprof per file, on a sample — full corpus is too slow)

```elixir
:code.add_patha(~c"/Users/lukaszsamson/.asdf/installs/erlang/28.5.0.1/lib/tools-4.1.4/ebin")
valid? = fn s -> match?({:ok,_}, (try do Code.string_to_quoted(s) rescue _ -> :e catch _,_ -> :e end)) end
sample = Path.wildcard("/Users/lukaszsamson/claude_fun/elixir_oss/projects/**/*.{ex,exs}") |> Enum.reject(&String.contains?(&1, ["/deps/","/_build/","/node_modules/"])) |> Enum.sort()
  |> Enum.filter(fn f -> s=File.read!(f); byte_size(s)>=2000 and byte_size(s)<=120000 and valid?.(s) end) |> Enum.take_every(110)
words = fn fun -> fun.(); {_r,{:call_memory,tr}}=:tprof.profile(fun,%{type: :call_memory, report: :return}); Enum.sum(Enum.map(tr, fn {_,_,_,[{_,_,w}]}->w end)) end
rows = Enum.map(sample, fn f -> src=File.read!(f)
  {f, words.(fn -> Toxic2.parse_to_ast(src, token_metadata: true) end), words.(fn -> Code.string_to_quoted(src, token_metadata: true, columns: true) end)} end)
rows |> Enum.sort_by(fn {_,t2,o}->t2/max(o,1) end,:desc) |> Enum.take(10)
  |> Enum.each(fn {f,t2,o}-> :io.format("~5.2fx alloc  ~ts~n",[t2/max(o,1), Path.basename(f)]) end)
```

## G. Profile a single outlier file (from a rerank)

```elixir
:code.add_patha(~c"/Users/lukaszsamson/.asdf/installs/erlang/28.5.0.1/lib/tools-4.1.4/ebin")
src = File.read!("/Users/lukaszsamson/claude_fun/elixir_oss/projects/<path from rerank>")
srcs = List.duplicate(src, 30)   # repeat so eprof has enough samples
fun = fn -> Enum.each(srcs, &Toxic2.parse_to_ast(&1, token_metadata: true)) end
fun.()
:eprof.start(); {:ok,_}=:eprof.profile([], fun); :eprof.stop_profiling(); :eprof.analyze(:total, sort: :time)
```

## H. Correctness: OSS token_metadata byte-equality (run after ANY tm change)

The gold safety net — compares the full AST against the live oracle byte-for-byte across all OSS
files. The wall benches don't check correctness; this does.

```elixir
oss = Path.wildcard("/Users/lukaszsamson/claude_fun/elixir_oss/projects/**/*.{ex,exs}") |> Enum.reject(&String.contains?(&1, ["/deps/","/_build/","/node_modules/"])) |> Enum.sort()
{ck,mm} = Enum.reduce(oss, {0,0}, fn f,{ck,mm} ->
  src=File.read!(f)
  case (try do Code.string_to_quoted(src, token_metadata: true, columns: true) rescue _ -> :s catch _,_ -> :s end) do
    {:ok,o} -> {t,_}=Toxic2.parse_to_ast(src, token_metadata: true); if t==o, do: {ck+1,mm}, else: {ck+1,mm+1}
    _ -> {ck,mm}
  end
end)
IO.puts("tm byte-equality: #{ck-mm}/#{ck} match, #{mm} mismatch")
```

Baseline: **5512/5519 match, 7 mismatch** (the 7 are pre-existing, stable — a regression shows as a
DIFFERENT count). For default-mode equality use `parse_to_ast(src)` vs `Code.string_to_quoted(src)`.
For lexer-warning changes (e.g. confusable lint), also compare `Toxic2.tokenize(src)` warnings.

## Methodology rules (hard-won — see memory `toxic2-benchmark`)

1. **Fresh process per timed iteration.** A single-process stage bench gives stable, reproducible,
   FAKE numbers (GC/heap state bleeds between A/B arms). All scripts above spawn a fresh process.
2. **Reductions for ranking** (deterministic, drift-immune CPU proxy), **tprof for allocation**
   (exact), **eprof for time** (find hotspots). Wall time only for headline ratios, using min of
   many iters and a control arm to detect drift.
3. **eprof AFTER de-slicing.** Removing allocation can leave a zero-alloc CPU hog (the % attribution
   reveals it). Conversely, call-count elimination alone is a wash (JIT-era local calls are free) —
   only allocation removal OR genuine work reduction moves the needle.
4. **Profile the outlier ALONE.** Its worst-ratio cause is often unrelated to its visible content
   (e.g. binary_test.exs looked bitstring-bound; was the confusable lint NFD-ing ASCII identifiers).
5. **Verify with bin_opt_info** for any new binary scanner — a bare-variable head clause silently
   de-opts the whole function to per-step sub-binary materialization:
   `ERL_COMPILER_OPTIONS=bin_opt_info MIX_ENV=prod mix compile --force 2>&1 | grep -A3 "NOT OPTIMIZED\|BINARY CREATED"`
6. **Always re-run OSS byte-equality (section H) + `mix toxic2.check`** before committing any
   token_metadata change — the wall benches don't catch correctness regressions.
