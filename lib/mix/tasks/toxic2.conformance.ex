defmodule Mix.Tasks.Toxic2.Conformance do
  @shortdoc "Conformance harness: compare Toxic2 AST vs the reference parser; freeze-ratchet gate"
  @moduledoc """
  The phase-6 conformance harness (see `TOXIC_2.md` → Agent Development Harness). This is the
  **one** place the reference parser (`Code.string_to_quoted/2`) is the intended tool — it is the
  oracle (P10), and this task lives under `lib/mix/tasks` (tooling), exempt from the guard.

  For each corpus entry (`Toxic2.Conformance.Corpus`):

  - oracle `{:ok, ast}` → **class 1**: lower Toxic2's CST and compare ASTs after metadata
    normalization (`:pass` / `:fail`);
  - oracle `{:error, _}` → **class 2**: Toxic2 must not crash and must emit an `:error`
    diagnostic (`:ok_invalid` / `:unexpected_valid`).

  A Toxic2 exception is `:crash` (always a bug — the parser/lowerer are total).

  ## Usage

      mix toxic2.conformance                 # human summary
      mix toxic2.conformance --json          # machine report (buckets + first failures)
      mix toxic2.conformance --gate          # fail if any frozen-passing source regressed
      mix toxic2.conformance --update-freeze # ratchet freeze.json forward to current passes

  The freeze gate may only be ratcheted **forward** (P: agents add newly-passing sources, never
  delete an entry to go green).
  """
  use Mix.Task

  alias Toxic2.Conformance.Corpus

  @passing [:pass, :ok_invalid]

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    {opts, _, _} =
      OptionParser.parse(args,
        switches: [json: :boolean, gate: :boolean, update_freeze: :boolean, bucket: :string]
      )

    # Always evaluate the full corpus — the freeze gate must see every source, regardless of
    # any `--bucket` display filter (otherwise out-of-bucket frozen cases would look "missing").
    results = Enum.map(Corpus.all(), fn e -> Map.put(e, :status, evaluate(e.source)) end)
    shown = bucket_filter(results, opts[:bucket])

    if opts[:json], do: IO.puts(json_report(shown)), else: print_summary(shown)
    if opts[:update_freeze], do: update_freeze(results)
    if opts[:gate], do: check_gate(results)

    :ok
  end

  defp bucket_filter(results, nil), do: results

  defp bucket_filter(results, bucket),
    do: Enum.filter(results, fn r -> bucket in Enum.map(r.tags, &Atom.to_string/1) end)

  # --- evaluation (oracle-backed; reused by the conformance ExUnit test) ---

  @doc "Classify one source: `:pass | {:fail, oracle, toxic} | :ok_invalid | :unexpected_valid | {:crash, msg}`."
  def evaluate(source) do
    case Code.string_to_quoted(source, columns: true) do
      {:ok, oracle_ast} -> compare_valid(source, oracle_ast)
      {:error, _} -> compare_invalid(source)
    end
  end

  defp compare_valid(source, oracle_ast) do
    {toxic_ast, diags} = Toxic2.parse_to_ast(source)
    errors = Enum.filter(diags, &(elem(&1, 2) == :error))

    cond do
      # Valid code must parse cleanly: AST equality AND no :error diagnostics (a parser/lowerer
      # recovery on valid input is a conformance failure even if the AST happens to match).
      errors != [] -> {:fail_diag, errors}
      normalize(toxic_ast) == normalize(oracle_ast) -> :pass
      true -> {:fail, normalize(oracle_ast), normalize(toxic_ast)}
    end
  rescue
    e -> {:crash, Exception.message(e)}
  end

  defp compare_invalid(source) do
    {_toxic_ast, diags} = Toxic2.parse_to_ast(source)
    if Enum.any?(diags, &(elem(&1, 2) == :error)), do: :ok_invalid, else: :unexpected_valid
  rescue
    e -> {:crash, Exception.message(e)}
  end

  # Strip metadata so only structure + values are compared (P4: no metadata parity).
  defp normalize(ast) do
    Macro.prewalk(ast, fn
      {f, _meta, a} -> {f, [], a}
      other -> other
    end)
  end

  # --- reporting ---------------------------------------------------------

  defp label({:fail, _, _}), do: :fail
  defp label({:fail_diag, _}), do: :fail
  defp label({:crash, _}), do: :crash
  defp label(status), do: status

  defp bucket(%{tags: [t | _]}), do: Atom.to_string(t)
  defp bucket(_), do: "untagged"

  defp print_summary(results) do
    counts = results |> Enum.map(&label(&1.status)) |> Enum.frequencies()
    total = length(results)
    failures = Enum.filter(results, &(label(&1.status) in [:fail, :unexpected_valid, :crash]))

    Mix.shell().info("toxic2.conformance: #{total} cases #{inspect(counts)}")

    Enum.each(Enum.take(failures, 10), fn r ->
      Mix.shell().info("  [#{bucket(r)}] #{inspect(r.source)} -> #{summarize(r.status)}")
    end)

    if failures == [], do: Mix.shell().info([:green, "all conformance cases green"])
  end

  defp summarize({:fail, o, t}),
    do: "AST mismatch\n      oracle: #{inspect(o)}\n      toxic:  #{inspect(t)}"

  defp summarize({:fail_diag, errs}),
    do:
      "valid source produced #{length(errs)} error diagnostic(s): #{inspect(Enum.map(errs, &elem(&1, 3)))}"

  defp summarize({:crash, msg}), do: "CRASH: #{msg}"
  defp summarize(:unexpected_valid), do: "accepted invalid source without an :error diagnostic"
  defp summarize(other), do: inspect(other)

  defp json_report(results) do
    by_status =
      results |> Enum.map(&Atom.to_string(label(&1.status))) |> Enum.frequencies()

    first_failures =
      results
      |> Enum.filter(&(label(&1.status) in [:fail, :unexpected_valid, :crash]))
      |> Enum.sort_by(&byte_size(&1.source))
      |> Enum.take(10)
      |> Enum.map(fn r ->
        %{"source" => r.source, "bucket" => bucket(r), "detail" => summarize(r.status)}
      end)

    %{
      "total" => length(results),
      "by_status" => by_status,
      "first_failures" => first_failures
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  # --- freeze-ratchet gate ----------------------------------------------

  defp freeze_path, do: Path.join(File.cwd!(), "freeze.json")

  defp read_freeze do
    case File.read(freeze_path()) do
      {:ok, bin} -> :json.decode(bin)
      {:error, _} -> nil
    end
  end

  # Forward-only ratchet: UNION existing frozen sources with newly-passing ones, never remove.
  # A frozen source that now fails stays in the freeze (the gate will flag it) — you cannot drop
  # an entry to go green, and removing a corpus entry cannot silently un-freeze it.
  defp update_freeze(results) do
    existing = read_freeze() || []
    passing = for r <- results, label(r.status) in @passing, do: r.source
    union = Enum.concat(existing, passing) |> Enum.uniq() |> Enum.sort()
    File.write!(freeze_path(), IO.iodata_to_binary(:json.encode(union)))

    Mix.shell().info(
      "freeze.json: #{length(union)} sources (+#{length(union) - length(existing)}; never removed)"
    )
  end

  defp check_gate(results) do
    case read_freeze() do
      nil ->
        Mix.raise("no freeze.json — bootstrap it with `mix toxic2.conformance --update-freeze`")

      frozen ->
        by_source = Map.new(results, &{&1.source, label(&1.status)})
        regressed = Enum.reject(frozen, &(Map.get(by_source, &1) in @passing))

        if regressed == [] do
          Mix.shell().info([:green, "conformance gate ok (#{length(frozen)} frozen)"])
        else
          Mix.raise(
            "conformance freeze regressions:\n" <>
              Enum.map_join(regressed, "\n", &"  #{inspect(&1)}")
          )
        end
    end
  end
end
