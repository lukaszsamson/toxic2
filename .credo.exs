%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        # `lib/toxic2/unicode/` is the vendored `String.Tokenizer` port — machine-generated and
        # kept byte-faithful to upstream Elixir, so it's exempt from our complexity checks (same
        # rationale as the `toxic2.guard` exemption).
        excluded: [~r"/_build/", ~r"/deps/", ~r"lib/toxic2/unicode/"]
      },
      strict: true,
      checks: %{
        enabled: [
          # Complexity hotspots are how the old parser rotted (4k-line pratt.ex,
          # 10-arg functions). Keep the lid on from day one.
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12},
          {Credo.Check.Refactor.FunctionArity, max_arity: 9},
          {Credo.Check.Refactor.LongQuoteBlocks, []},
          {Credo.Check.Refactor.Nesting, max_nesting: 3}
        ],
        disabled: [
          # TODO/FIXME are fine during a staged build-out.
          {Credo.Check.Design.TagTODO, []},
          {Credo.Check.Design.TagFIXME, []}
        ]
      }
    }
  ]
}
