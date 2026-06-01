defmodule Mix.Tasks.Toxic2.Conformance.Imported do
  @shortdoc "Run the large imported conformance corpora (report-only backlog ratchet)"
  @moduledoc """
  Evaluate the **imported** corpora (`test/support/imported_*_corpus.ex`, ~2400 inputs adapted
  from the prior `toxic_parser` / `toxic` suites) against the live oracle.

  This is a *backlog ratchet*, deliberately separate from `mix toxic2.conformance` and NOT wired
  into `mix toxic2.check`: the curated corpus must always be green, but these imported inputs
  exercise grammar Toxic2 may not implement yet. First runs surface hundreds of not-yet-passing
  cases — that's expected. Sort by bucket, fix one grammar island, then `--update-freeze` to
  promote the now-passing cases into the imported freeze (forward-only, like the curated gate).

  Two tracks:

    * **parser** (default) — routes each source through `Toxic2.Conformance` `evaluate/1`
      (normalized-AST match vs `Code.string_to_quoted`, or tolerant `:ok_invalid` when the oracle
      rejects). "green" = `:pass | :ok_invalid`.
    * **lexer** (`--lexer`) — valid-*lexing* inputs that may not parse. When `:elixir_tokenizer`
      accepts the source, `Toxic2.tokenize/2` must emit NO `:error` token and keep source order
      ("clean"); when the oracle tokenizer rejects it, Toxic2 must merely not crash. We do NOT
      compare token streams one-for-one — Toxic2's token model is intentionally different.

      mix toxic2.conformance.imported                  # parser backlog report
      mix toxic2.conformance.imported --lexer          # lexer backlog report
      mix toxic2.conformance.imported --bucket string  # one bucket
      mix toxic2.conformance.imported --json
      mix toxic2.conformance.imported --gate           # fail on regression vs the imported freeze
      mix toxic2.conformance.imported --update-freeze  # ratchet the imported freeze forward
  """
  use Mix.Task

  alias Mix.Tasks.Toxic2.Conformance, as: Harness

  @parser_freeze "imported_freeze_parser.json"
  @lexer_freeze "imported_freeze_lexer.json"

  @impl true
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          gate: :boolean,
          update_freeze: :boolean,
          bucket: :string,
          lexer: :boolean
        ]
      )

    track = if opts[:lexer], do: :lexer, else: :parser
    results = evaluate_all(track)
    shown = bucket_filter(results, opts[:bucket])

    if opts[:json], do: report_json(track, shown), else: report(track, shown)
    if opts[:update_freeze], do: update_freeze(track, results)
    if opts[:gate], do: check_gate(track, results)
    # Re-enable so an alias can invoke this task twice (parser then `--lexer`) in one run.
    Mix.Task.reenable("toxic2.conformance.imported")
    :ok
  end

  # --- evaluation --------------------------------------------------------

  # The corpus modules live in `test/support` (compiled only in :test). Reference them through a
  # variable (no compile-time dependency, so `MIX_ENV=dev mix compile` stays warning-clean) and
  # require the source file on demand if the module isn't already loaded (so the task also works
  # under MIX_ENV=dev).
  @corpus %{
    parser: {Toxic2.Conformance.ImportedParser, "test/support/imported_parser_corpus.ex"},
    lexer: {Toxic2.Conformance.ImportedLexer, "test/support/imported_lexer_corpus.ex"}
  }

  defp corpus(track) do
    {mod, path} = @corpus[track]
    _ = unless Code.ensure_loaded?(mod), do: Code.require_file(path)
    mod.all()
  end

  defp evaluate_all(track) do
    for entry <- corpus(track) do
      Map.put(entry, :status, status(track, entry.source))
    end
  end

  defp status(:parser, source), do: Harness.evaluate(source)
  defp status(:lexer, source), do: lex_evaluate(source)

  # When the oracle tokenizer accepts the source, Toxic2 must lex it cleanly (no `:error` token,
  # source-ordered). When the oracle rejects it, Toxic2 must merely not raise.
  @doc false
  def lex_evaluate(source) do
    case :elixir_tokenizer.tokenize(String.to_charlist(source), 1, 1, []) do
      {:ok, _, _, _, _, _} -> lex_clean(source)
      _ -> lex_tolerant(source)
    end
  rescue
    e -> {:crash, Exception.message(e)}
  catch
    kind, reason -> {:crash, "#{kind}: #{inspect(reason)}"}
  end

  defp lex_clean(source) do
    {tokens, _w} = Toxic2.tokenize(source)
    errors = Enum.count(tokens, &(elem(&1, 0) == :error))

    cond do
      errors > 0 -> {:dirty, errors}
      not source_ordered?(tokens) -> {:unordered, source}
      true -> :clean
    end
  end

  defp lex_tolerant(source) do
    {_tokens, _w} = Toxic2.tokenize(source)
    :ok_lex_invalid
  end

  defp source_ordered?(tokens) do
    starts = Enum.map(tokens, &{elem(&1, 1), elem(&1, 2)})
    starts == Enum.sort(starts)
  end

  # "green" = the freeze-gate target (no regression). It bundles TRUE conformance (`:pass` /
  # `:clean`) with TOLERANCE on oracle-invalid input (`:ok_invalid` / `:ok_lex_invalid`) — the
  # reports below break these apart so the headline conformance number isn't inflated by tolerance.
  @conformant [:pass, :clean]
  @tolerant [:ok_invalid, :ok_lex_invalid]
  @green @conformant ++ @tolerant

  defp green?(status), do: status in @green

  # --- reporting ---------------------------------------------------------

  defp bucket_filter(results, nil), do: results

  defp bucket_filter(results, bucket),
    do: Enum.filter(results, fn r -> bucket in Enum.map(r.tags, &Atom.to_string/1) end)

  defp report(track, results) do
    conformant = Enum.count(results, &(&1.status in @conformant))
    tolerant = Enum.count(results, &(&1.status in @tolerant))
    backlog = Enum.reject(results, &green?(&1.status))
    frozen = read_freeze(track) || []

    Mix.shell().info(
      "toxic2.conformance.imported (#{track}): #{conformant} conformant + #{tolerant} " <>
        "tolerant-invalid = #{conformant + tolerant} green / #{length(results)}; " <>
        "#{length(backlog)} backlog (#{length(frozen)} frozen)"
    )

    backlog
    |> Enum.group_by(&group/1)
    |> Enum.sort_by(fn {_g, rs} -> -length(rs) end)
    |> Enum.take(20)
    |> Enum.each(fn {g, rs} ->
      Mix.shell().info("  #{String.pad_trailing(g, 40)} #{length(rs)} backlog")
    end)
  end

  defp report_json(track, results) do
    backlog = Enum.reject(results, &green?(&1.status))

    payload = %{
      "track" => Atom.to_string(track),
      "total" => length(results),
      "conformant" => Enum.count(results, &(&1.status in @conformant)),
      "tolerant_invalid" => Enum.count(results, &(&1.status in @tolerant)),
      "backlog" =>
        Enum.map(Enum.take(backlog, 200), fn r ->
          %{"source" => r.source, "group" => r.group, "status" => inspect(r.status)}
        end)
    }

    Mix.shell().info(IO.iodata_to_binary(:json.encode(payload)))
  end

  defp group(%{group: g}), do: g
  defp group(_), do: "ungrouped"

  # --- freeze ratchet (separate from the curated freeze.json) ------------

  defp freeze_path(:parser), do: @parser_freeze
  defp freeze_path(:lexer), do: @lexer_freeze

  defp read_freeze(track) do
    path = freeze_path(track)
    if File.exists?(path), do: :json.decode(File.read!(path)), else: nil
  end

  defp update_freeze(track, results) do
    existing = read_freeze(track) || []
    passing = for r <- results, green?(r.status), do: r.source
    union = Enum.concat(existing, passing) |> Enum.uniq() |> Enum.sort()
    File.write!(freeze_path(track), IO.iodata_to_binary(:json.encode(union)))

    Mix.shell().info(
      "#{freeze_path(track)}: #{length(union)} sources (+#{length(union) - length(existing)}; never removed)"
    )
  end

  defp check_gate(track, results) do
    case read_freeze(track) do
      nil ->
        Mix.raise("no #{freeze_path(track)} — bootstrap with `--update-freeze`")

      frozen ->
        by_source = Map.new(results, &{&1.source, green?(&1.status)})
        regressed = Enum.reject(frozen, &(Map.get(by_source, &1) == true))

        if regressed == [] do
          Mix.shell().info([:green, "imported #{track} gate ok (#{length(frozen)} frozen)"])
        else
          Mix.raise(
            "imported #{track} freeze regressions:\n" <>
              Enum.map_join(regressed, "\n", &"  #{inspect(&1)}")
          )
        end
    end
  end
end
