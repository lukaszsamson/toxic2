defmodule Mix.Tasks.Toxic2.Conformance.Oss do
  @shortdoc "Whole-file conformance over a local OSS Elixir tree (report-only)"
  @moduledoc """
  Parse every `.ex` / `.exs` file under a local OSS corpus and compare Toxic2's AST to the live
  oracle (whole-program stress, adapted from `toxic_parser`'s `conformance_corpus_test.exs`).

  This is **report-only and local** — the file set and paths are machine-specific, so nothing is
  committed or gated here (unlike the embedded `mix toxic2.conformance.imported` ratchet). It just
  tells you how much real-world source round-trips today.

  The tree is `$TOXIC2_OSS_DIR` (skipped gracefully if unset/missing):

      TOXIC2_OSS_DIR=/path/to/elixir_oss/projects mix toxic2.conformance.oss
      TOXIC2_OSS_DIR=… mix toxic2.conformance.oss --limit 500   # sample the first N files
  """
  use Mix.Task

  alias Mix.Tasks.Toxic2.Conformance, as: Harness

  @ignored ~w(_build deps .git tmp priv rel cover doc logs)
  @green [:pass, :ok_invalid]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [limit: :integer])

    case System.get_env("TOXIC2_OSS_DIR") do
      nil ->
        Mix.shell().info("TOXIC2_OSS_DIR not set — skipping OSS whole-file conformance.")

      dir ->
        if File.dir?(dir),
          do: walk(dir, opts),
          else: Mix.shell().info("#{dir} not found — skipping.")
    end

    :ok
  end

  defp walk(dir, opts) do
    files = collect(dir)
    files = if opts[:limit], do: Enum.take(files, opts[:limit]), else: files

    results =
      for path <- files do
        {path, evaluate_file(path)}
      end

    conformant = Enum.count(results, fn {_p, st} -> st == :pass end)
    tolerant = Enum.count(results, fn {_p, st} -> st == :ok_invalid end)
    backlog = Enum.reject(results, fn {_p, st} -> st in @green end)

    # A real source file is valid code, so `:pass` (exact AST) is the meaningful metric; a handful
    # of `:ok_invalid` (oracle itself rejects the file) are reported separately, not as conformance.
    Mix.shell().info(
      "toxic2.conformance.oss: #{conformant} conformant" <>
        if(tolerant > 0, do: " (+#{tolerant} oracle-invalid, tolerated)", else: "") <>
        " / #{length(results)} files; #{length(backlog)} backlog under #{dir}"
    )

    backlog
    |> Enum.take(30)
    |> Enum.each(fn {path, st} ->
      Mix.shell().info("  #{summarize(st)}  #{Path.relative_to(path, dir)}")
    end)
  end

  defp evaluate_file(path) do
    case File.read(path) do
      {:ok, source} -> Harness.evaluate(source)
      {:error, reason} -> {:read_error, reason}
    end
  rescue
    e -> {:crash, Exception.message(e)}
  end

  defp summarize(:pass), do: "pass"
  defp summarize(:ok_invalid), do: "ok_invalid"
  defp summarize({:fail, _, _}), do: "AST mismatch"
  defp summarize({:fail_diag, _}), do: "error diag on valid"
  defp summarize({:crash, _}), do: "CRASH"
  defp summarize(other), do: inspect(other)

  defp collect(dir) do
    dir
    |> Path.join("**/*.{ex,exs}")
    |> Path.wildcard()
    |> Enum.reject(fn p -> Enum.any?(@ignored, &(&1 in Path.split(p))) end)
    |> Enum.sort()
  end
end
