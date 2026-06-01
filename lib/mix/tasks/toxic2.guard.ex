defmodule Mix.Tasks.Toxic2.Guard do
  @shortdoc "Fails the build on reward-hacks and old-design drift (see TOXIC_2.md)"
  @moduledoc """
  Mechanical guardrail against the specific reward-hacks and architectural drift that sank the
  previous attempt (`toxic` / `toxic_parser`). This is the anti-cheat layer of the harness: an
  agent must not be able to make tests green by leaning on the built-in Elixir parser, by
  writing tautological assertions, or by silently skipping work.

  Run directly with `mix toxic2.guard`, or as part of `mix toxic2.check`.

  ## What it forbids

  Forbidden in **library core** (`lib/toxic2/**`) *and* in **non-oracle tests**:

  - The built-in Elixir parser / tokenizer / eval as an implementation or a test crutch:
    `Code.string_to_quoted(!)`, `Code.string_to_quoted_with_comments(!)`, `Code.eval_string`,
    `Code.eval_quoted`, `Code.compile_string`, `:elixir.string_to_quoted`, `:elixir_tokenizer`,
    `:elixir_parser`. The whole point of Toxic 2 is independence from these. The reference
    parser is allowed in **exactly one place** — the oracle (`test/support/oracle*` /
    `test/**/*conformance*`) — which is the only legitimate consumer (P10).

  Forbidden in **library core only** (`lib/toxic2/**`):

  - `Macro.to_string` — lossy AST→string comparison must not live in the library
    (it normalizes away real structural differences; see R_OPUS §10.5).

  Forbidden in **all library core** (`lib/**` except the harness Mix tasks and the vendored
  Unicode tables in `lib/toxic2/unicode/`):

  - `++` — no list append on the hot path; build reversed and reverse once (Performance rules).
    All of library core is treated as hot so a new parser/cursor module can't silently escape
    the ban; a legitimate boundary append uses a trailing `# guard:allow`. The vendored
    `String.Tokenizer` port under `lib/toxic2/unicode/` is exempt wholesale: it is
    machine-generated compile-time table construction kept byte-faithful to upstream Elixir.

  Forbidden in **test files**:

  - Tautological assertions (`assert true`) — a classic green-without-work hack.
  - `@tag :skip` / `@moduletag :skip` — disabling a test to dodge a failure.

  ## Escape hatch (auditable)

  Any single line may be exempted with a trailing `# guard:allow` comment. This is deliberate:
  it keeps a *visible, greppable, reviewable* record instead of a silent bypass. Overuse is
  itself a smell the freeze/review can catch.
  """
  use Mix.Task

  # Needles are assembled from fragments so this task's OWN source never matches them.
  # Function needles are flagged only when *called* (`needle(` ), so doc mentions like
  # `Code.string_to_quoted/2` and prose don't false-positive.
  @builtin_call_needles [
    "Code." <> "string_to_quoted",
    "Code." <> "eval_string",
    "Code." <> "eval_quoted",
    "Code." <> "compile_string",
    ":elixir." <> "string_to_quoted"
  ]

  # Module needles: these are never legitimate, so a mere mention is flagged.
  @builtin_module_needles [":elixir_" <> "tokenizer", ":elixir_" <> "parser"]

  @macro_to_string "Macro." <> "to_string"

  # Files where the reference parser IS the intended tool.
  @oracle_path ~r{test/(support/oracle|.*conformance)}

  @allow_marker "# guard:allow"

  @assert_true ~r/\bassert\s+true\b(?!\s*(==|!=|<|>|=~))/
  @skip_tag ~r/@(module)?tag\s+:skip\b/

  @impl true
  def run(_args) do
    paths = scanned_paths()

    case violations(paths) do
      [] ->
        Mix.shell().info([
          :green,
          "toxic2.guard: clean (",
          Integer.to_string(length(paths)),
          " files)"
        ])

      vs ->
        report =
          vs
          |> Enum.map(fn {path, line, rule, text} ->
            "  #{path}:#{line}  [#{rule}]  #{String.trim(text)}"
          end)
          |> Enum.join("\n")

        Mix.raise(
          "toxic2.guard found #{length(vs)} reward-hack/drift violation(s):\n" <>
            report <>
            "\n\nSee `mix help toxic2.guard`. Legitimate exceptions: trailing `#{@allow_marker}`."
        )
    end
  end

  @doc """
  The exact set of files the guard scans: all library core (`lib/**`) except the harness Mix
  tasks (tooling) and the vendored, machine-generated Unicode tables (`lib/toxic2/unicode/` —
  ported wholesale from Elixir's `String.Tokenizer`; its compile-time `++` table-building is data
  generation, not hot-path hand-written code, and we keep it byte-faithful rather than annotate
  every line), plus all test files. Exposed so the self-test scans precisely what `run/0` does.
  """
  @spec scanned_paths() :: [Path.t()]
  def scanned_paths do
    lib =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(
        &(String.contains?(&1, "lib/mix/") or String.contains?(&1, "lib/toxic2/unicode/"))
      )

    Enum.concat(lib, Path.wildcard("test/**/*.exs"))
  end

  @doc """
  Pure scanner. Returns a list of `{path, line_number, rule, line_text}` violations.

  Exposed so tests can exercise it on fixture files without shelling out.
  """
  @spec violations([Path.t()]) :: [{Path.t(), pos_integer(), atom(), String.t()}]
  def violations(paths) do
    Enum.flat_map(paths, &scan_file/1)
  end

  defp scan_file(path) do
    is_lib = String.contains?(path, "lib/")
    is_test = String.ends_with?(path, ".exs") and String.contains?(path, "test/")
    is_oracle = Regex.match?(@oracle_path, path)
    # All library core is hot by default, so a new parser/cursor file can't silently escape
    # the `++` ban. Legitimate boundary appends use a trailing `# guard:allow`.
    is_hot = is_lib

    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      if String.contains?(line, @allow_marker) do
        []
      else
        line_rules(line, is_lib, is_test, is_oracle, is_hot)
        |> Enum.map(fn rule -> {path, n, rule, line} end)
      end
    end)
  end

  defp line_rules(line, is_lib, is_test, is_oracle, is_hot) do
    []
    |> maybe(builtin_parser?(line) and not is_oracle, :builtin_parser)
    |> maybe(is_lib and String.contains?(line, @macro_to_string), :macro_to_string_in_lib)
    |> maybe(is_hot and contains_append?(line), :list_append_in_hot_module)
    |> maybe(is_test and Regex.match?(@assert_true, line), :tautological_assert)
    |> maybe(is_test and Regex.match?(@skip_tag, line), :skip_tag)
  end

  defp builtin_parser?(line) do
    Enum.any?(@builtin_call_needles, &Regex.match?(~r/#{Regex.escape(&1)}\s*\(/, line)) or
      Enum.any?(@builtin_module_needles, &String.contains?(line, &1))
  end

  # Flag the `++` list-append operator (formatter guarantees ` ++ ` with spaces), but not the
  # lexeme as *data* — strings like `"a ++ b"` and atoms like `:++` are not appends. Strip
  # string literals first; the format-check step rejects unspaced `a++b`, so requiring spaces
  # here cannot be evaded.
  defp contains_append?(line) do
    code = String.replace(line, ~r/"[^"]*"/, "")
    String.contains?(code, " ++ ") and not String.starts_with?(String.trim_leading(line), "#")
  end

  defp maybe(acc, true, rule), do: [rule | acc]
  defp maybe(acc, false, _rule), do: acc
end
