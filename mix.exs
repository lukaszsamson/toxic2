defmodule Toxic2.MixProject do
  use Mix.Project

  def project do
    [
      app: :toxic2,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      # Warnings are errors in CI/quality runs (set MIX_ENV=test or pass --warnings-as-errors).
      elixirc_options: [warnings_as_errors: System.get_env("CI") == "true"],
      dialyzer: dialyzer()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run the quality gate in :test env so the `test` step inside the alias works.
  def cli do
    [
      preferred_envs: [
        "toxic2.check": :test,
        "toxic2.check.full": :test,
        "toxic2.conformance.imported": :test,
        "toxic2.check.imported": :test
      ]
    ]
  end

  # In :test, also compile `test/support` — home of the large imported conformance corpora
  # (`*_corpus.ex`). They live here (not lib/) so they don't ship in the app and aren't scanned
  # by the quality guard (which globs `lib/**/*.ex` + `test/**/*.exs`, never `test/**/*.ex`).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # The QUALITY gate (distinct from the phase-6 conformance freeze gate, which is per
  # TOXIC_2.md). This is the anti-reward-hack / anti-drift layer and runs from phase 1.
  defp aliases do
    [
      # Fast gate — run on every change.
      "toxic2.check": [
        "format --check-formatted",
        "toxic2.guard",
        "credo --strict",
        # --force so warnings always resurface (an earlier step may have already compiled).
        "compile --warnings-as-errors --force",
        "test",
        # Conformance freeze gate (phase 6+): fail if any frozen-passing source regressed.
        "toxic2.conformance --gate"
      ],
      # Full gate — adds Dialyzer (slow first run: builds the PLT).
      "toxic2.check.full": [
        "toxic2.check",
        "dialyzer"
      ],
      # Opt-in regression gate for the imported backlog corpora (NOT in the default check —
      # report-only ratchet). Fails only if a frozen-green imported source regresses.
      "toxic2.check.imported": [
        "toxic2.conformance.imported --gate",
        "toxic2.conformance.imported --lexer --gate"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      # :mix is needed because the harness Mix tasks (lib/mix/tasks) reference Mix.*.
      plt_add_apps: [:mix],
      flags: [:error_handling, :extra_return, :missing_return, :unmatched_returns]
    ]
  end
end
