%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
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
