defmodule Mix.Tasks.Toxic2.Bench do
  @shortdoc "Benchmark lexer/parser/lower vs the oracle (TOXIC_2.md phase 13, no deps)"
  @moduledoc """
  Phase 13 benchmark. Times the toxic2 pipeline stages against the reference (`Code.string_to_quoted`,
  i.e. the yecc/`elixir_parser` automaton) on a corpus of REAL, oracle-valid Elixir files, and
  reports wall-time + an allocation proxy. Dependency-free: `:timer.tc` + `:erlang.statistics`.

  Methodology (so the numbers are hard to misread): each of `--reps` rounds measures every stage in
  a FRESH process (one warm-up pass discarded) in SHUFFLED order, so scheduler/thermal drift hits
  all stages evenly and heaps don't bias each other. The table reports the **median** (p95 in
  parens, min separately) — NOT just the min. Caveat: the headline `t2_full / oracle` ratio still
  drifts run-to-run because the *oracle baseline* moves with machine load; the allocation column
  (`x oracle`) is the stable, durable comparison.

      mix toxic2.bench                       # Elixir stdlib lib/ (default corpus)
      TOXIC2_BENCH_DIR=/path mix toxic2.bench
      mix toxic2.bench --reps 12             # more rounds (default 8) for tighter medians
      mix toxic2.bench --json                # machine-readable rows
      mix toxic2.bench --top 10              # also list the 10 slowest files (t2_full)

  Only oracle-valid files are measured, so both sides do equivalent work. As of the last perf pass
  `t2_full` sits around ~1.5–1.6× the oracle (median, load-dependent), allocations ~1.08× — the
  ≤1.5× wall-time target is NOT yet met; the lexer is still ~half of `t2_full`.
  """
  use Mix.Task

  @default_dir "/Users/lukaszsamson/elixir/lib/elixir/lib"
  @ignored ~w(_build deps .git tmp priv rel cover doc logs)

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dir: :string, reps: :integer, top: :integer, json: :boolean]
      )

    dir = opts[:dir] || System.get_env("TOXIC2_BENCH_DIR") || @default_dir
    reps = opts[:reps] || 8

    unless File.dir?(dir) do
      Mix.raise("bench corpus dir not found: #{dir} (set --dir or $TOXIC2_BENCH_DIR)")
    end

    sources = load_valid_sources(dir)

    if sources == [] do
      Mix.shell().info("no oracle-valid .ex/.exs files under #{dir} — nothing to benchmark.")
    else
      report(sources, reps, opts, dir)
    end
  end

  # --- corpus ------------------------------------------------------------------------------------

  defp load_valid_sources(dir) do
    dir
    |> walk()
    |> Enum.map(&{&1, File.read!(&1)})
    |> Enum.filter(fn {_p, src} -> match?({:ok, _}, safe_quote(src)) end)
  end

  defp walk(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(names, fn name ->
          path = Path.join(dir, name)

          cond do
            name in @ignored -> []
            File.dir?(path) -> walk(path)
            String.ends_with?(name, ".ex") or String.ends_with?(name, ".exs") -> [path]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  defp safe_quote(src) do
    Code.string_to_quoted(src)
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # --- measurement -------------------------------------------------------------------------------

  @stages [
    {"t2_lex", "tokenize", :lex},
    {"t2_parse", "lex+parse→CST", :parse},
    {"t2_full", "lex+parse+lower", :full},
    {"oracle", "Code.s2q / yecc", :oracle}
  ]

  defp stage_fun(:lex), do: fn s -> Toxic2.tokenize(s) end
  defp stage_fun(:parse), do: fn s -> Toxic2.parse(s) end
  defp stage_fun(:full), do: fn s -> Toxic2.parse_to_ast(s) end
  defp stage_fun(:oracle), do: fn s -> Code.string_to_quoted(s) end

  defp report(sources, reps, opts, dir) do
    srcs = Enum.map(sources, fn {_p, s} -> s end)
    bytes = srcs |> Enum.map(&byte_size/1) |> Enum.sum()
    n = length(srcs)

    # `reps` interleaved rounds: each round measures every stage in SHUFFLED order, each in a FRESH
    # process (warm-up pass discarded), so scheduler/thermal drift hits all stages evenly and one
    # stage's heap can't bias another. Per-pass totals are kept for median/p95 (not just min).
    samples =
      Enum.reduce(1..reps, %{}, fn _round, acc ->
        Enum.reduce(Enum.shuffle(@stages), acc, fn {_label, _desc, key}, acc ->
          {us, words} = measure_once(srcs, stage_fun(key))
          Map.update(acc, key, {[us], [words]}, fn {ts, ws} -> {[us | ts], [words | ws]} end)
        end)
      end)

    stats = Map.new(@stages, fn {_l, _d, key} -> {key, summarize(samples[key])} end)
    {oracle_med, _, _, oracle_words} = stats[:oracle]

    if opts[:json] do
      IO.puts(json_report(stats, oracle_med, oracle_words, bytes, n, reps))
    else
      print_table(stats, oracle_med, oracle_words, bytes, n, reps, dir)
    end

    maybe_top(sources, opts[:top])
  end

  # One fresh-process measurement: a warm-up pass (JIT + atom/module caches), one timed pass, then a
  # separate allocation pass. The parent blocks in `receive`, so the system GC-reclaimed-words delta
  # is attributable to this process.
  defp measure_once(srcs, fun) do
    parent = self()
    ref = make_ref()

    {_pid, mref} =
      spawn_monitor(fn ->
        _ = pass_us(srcs, fun)
        us = pass_us(srcs, fun)
        :erlang.garbage_collect()
        {_, r0, _} = :erlang.statistics(:garbage_collection)
        Enum.each(srcs, fun)
        :erlang.garbage_collect()
        {_, r1, _} = :erlang.statistics(:garbage_collection)
        send(parent, {ref, us, r1 - r0})
      end)

    receive do
      {^ref, us, words} ->
        Process.demonitor(mref, [:flush])
        {us, words}
    end
  end

  defp pass_us(srcs, fun) do
    Enum.reduce(srcs, 0, fn s, acc ->
      {us, _} = :timer.tc(fn -> fun.(s) end)
      acc + us
    end)
  end

  # {median_us, p95_us, min_us, median_words}
  defp summarize({times, words}) do
    t = Enum.sort(times)
    {pctile(t, 0.5), pctile(t, 0.95), List.first(t), pctile(Enum.sort(words), 0.5)}
  end

  defp pctile(sorted, p) do
    idx = min(length(sorted) - 1, round((length(sorted) - 1) * p))
    Enum.at(sorted, idx)
  end

  defp print_table(stats, oracle_med, oracle_words, bytes, n, reps, dir) do
    Mix.shell().info("""
    toxic2.bench — #{n} oracle-valid files, #{fmt_bytes(bytes)}, #{reps} rounds (warm-up + fresh
    process per stage, shuffled order; median reported, p95 in parens)
    corpus: #{dir}
    """)

    Mix.shell().info(
      pad("stage", 26) <>
        pad("median ms", 16) <>
        pad("min ms", 10) <>
        pad("MB/s", 9) <>
        pad("x oracle", 10) <>
        "≈MB alloc / x"
    )

    Enum.each(@stages, fn {label, desc, key} ->
      {med, p95, min_us, words} = stats[key]
      alloc_mb = words * :erlang.system_info(:wordsize) / 1.0e6

      Mix.shell().info(
        pad("#{label} (#{desc})", 26) <>
          pad("#{fmt(med / 1000, 1)} (#{fmt(p95 / 1000, 1)})", 16) <>
          pad(fmt(min_us / 1000, 1), 10) <>
          pad(fmt(bytes / med, 1), 9) <>
          pad(fmt(med / oracle_med, 2) <> "x", 10) <>
          "#{fmt(alloc_mb, 1)} / #{fmt(words / max(oracle_words, 1), 2)}x"
      )
    end)

    headline(stats, oracle_med)
  end

  defp json_report(stats, oracle_med, oracle_words, bytes, n, reps) do
    wordsize = :erlang.system_info(:wordsize)

    rows =
      Enum.map(@stages, fn {label, _desc, key} ->
        {med, p95, min_us, words} = stats[key]

        ~s({"stage":"#{label}","median_ms":#{fmt(med / 1000, 2)},"p95_ms":#{fmt(p95 / 1000, 2)},) <>
          ~s("min_ms":#{fmt(min_us / 1000, 2)},"x_oracle":#{fmt(med / oracle_med, 3)},) <>
          ~s("alloc_mb":#{fmt(words * wordsize / 1.0e6, 2)},"alloc_x":#{fmt(words / max(oracle_words, 1), 3)}})
      end)

    ~s({"files":#{n},"bytes":#{bytes},"rounds":#{reps},"stages":[#{Enum.join(rows, ",")}]})
  end

  defp headline(stats, oracle_med) do
    {full, _, _, _} = stats[:full]
    {parse, _, _, _} = stats[:parse]
    {lex, _, _, _} = stats[:lex]
    ratio = full / oracle_med
    target = if ratio <= 1.5, do: "✓ within ≤1.5x target", else: "✗ ABOVE 1.5x target"

    Mix.shell().info("""

    headline: t2_full is #{fmt(ratio, 2)}x the oracle wall-time (median) — #{target}
    stage breakdown of t2_full: lex #{share(lex, full)}% · parse #{share(parse - lex, full)}% · lower #{share(full - parse, full)}%
    """)
  end

  defp share(part, whole), do: fmt(part / whole * 100, 0)

  defp maybe_top(_sources, nil), do: :ok

  defp maybe_top(sources, top) do
    rows =
      sources
      |> Enum.map(fn {path, src} ->
        {us, _} = :timer.tc(fn -> Toxic2.parse_to_ast(src) end)
        {path, us, byte_size(src)}
      end)
      |> Enum.sort_by(fn {_p, us, _b} -> -us end)
      |> Enum.take(top)

    Mix.shell().info("slowest #{top} files (t2_full):")

    Enum.each(rows, fn {path, us, b} ->
      Mix.shell().info("  #{pad(fmt(us / 1000, 2) <> "ms", 10)} #{fmt_bytes(b)}  #{rel(path)}")
    end)
  end

  # --- formatting --------------------------------------------------------------------------------

  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
  defp fmt(f, 0), do: :erlang.float_to_binary(f * 1.0, decimals: 0)
  defp fmt(f, d), do: :erlang.float_to_binary(f * 1.0, decimals: d)
  defp fmt_bytes(b) when b >= 1_000_000, do: "#{fmt(b / 1.0e6, 1)}MB"
  defp fmt_bytes(b) when b >= 1000, do: "#{fmt(b / 1000, 1)}KB"
  defp fmt_bytes(b), do: "#{b}B"
  defp rel(path), do: Path.relative_to_cwd(path)
end
