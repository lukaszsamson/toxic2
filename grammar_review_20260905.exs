# Reduced differential repros for GRAMMAR_REVIEW_2026-09-05.md.
# Run with the reference checkout's Elixir:
# MIX_OS_CONCURRENCY_LOCK=0 PATH=~/elixir/bin:$PATH mix run grammar_review_20260905.exs
# This is a report-only audit: differences are printed, not treated as expected test passes.

defmodule GrammarReview20260905 do
  alias Toxic2.Diagnostic

  def cases do
    [
      {"R1", "f() [0]"},
      {"R1", "(x) [0]"},
      {"R1", "Foo [0]"},
      {"R1", "a.b() [0]"},
      {"R1", "..[0]"},
      {"R2", "a.b() 1"},
      {"R2", "a.\"b\"() x: 1"},
      {"R3", "~S\"\"\"\n  \#{\n  \"\"\""},
      {"R3", "\"\"\"\n  \#{\"{\"}\n  \"\"\""},
      {"R3", "\"\"\"\n  before\n  \#{# {\n1}\n  after\n  \"\"\""},
      {"R4", "[a not in f x: 1, y: 2]"},
      {"R4", "%{x => a not in f x: 1, y: 2}"},
      {"R4", "f 0, a not in f b, c"},
      {"R4", "[a not in f b, c]"},
      {"R5", "[foo@bar: 1]"},
      {"R5", "[Foo!: 1]"},
      {"R5", "[Foo?: 1]"},
      {"R6", "\"\\u{41\""},
      {"R6", "\"\\u{41x}\""},
      {"R6", "\"\\u{0000041}\""},
      {"R6", ":\"\\u{41\""},
      {"R7", "\"\\" <> <<0x202E::utf8>> <> "\""},
      {"R7", "~s(\\" <> <<0x2028::utf8>> <> ")"},
      {"R7", "\"\\" <> <<11>> <> "\""},
      {"R8", "@f()(1)"},
      {"R8", "@f(1)(2)"},
      {"R9", "@@f[x]"},
      {"R9", "@@f()[x]"},
      {"R10", "%{f a: 1, b: 2 => 1}"},
      {"R10", "%{+f a: 1, b: 2 => 1}"},
      {"R11", "...\nx"},
      {"R11", "... # comment\n[0]"},
      {"R11", "... not in x"},
      {"R12", "f +.."},
      {"R12", "A.f -.."},
      {"R13", "&1_0"},
      {"R13", "&0x0A"},
      {"R13", "&0o12"},
      {"R13", "&0b1010"},
      {"R14", "x\\\n"},
      {"R14", "x\\\r\n"},
      {"R15", "é@bar"},
      {"R15", "a.é@bar()"},
      {"R15", "not@bar"},
      {"R16", "!f do x end.foo"},
      {"R16", "!f do x end[0]"},
      {"R16", "@f do x end.(1)"},
      {"R17", "unquote_splicing()"},
      {"R17", "unquote_splicing(x, y)"},
      {"R17", "unquote_splicing(x) do end"},
      {"R17", "quote do unquote_splicing(x) end"},
      {"R18", "\"e\u0301\"; x"},
      {"R18", "~s(e\u0301); x"},
      {"R18", "\"👩\u200D💻\"; x"},
      {"R19", "fn (f a, b) -> 1 end"},
      {"R19", "case x do (f a, b) -> 1 end"},
      {"R20", "f +//2"},
      {"R20", "%{m | //x}"},
      {"K6-extension", "[a when b: 1]"},
      {"K6-extension", "%{a => a when b: 1}"},
      {"control", "f()[0]"},
      {"control", "f [0]"},
      {"control", "(..)[0]"},
      {"control", "a.b 1"},
      {"control", "a.b(1) 2"},
      {"control", "~S\"\"\"\n  text\n  \"\"\""},
      {"control", "[a in f x: 1, y: 2]"},
      {"control", "[é@bar: 1]"},
      {"control", "\"\\u{41}\""},
      {"control", "\"\\u202E\""},
      {"control", "@f(1)"},
      {"control", "@f[x]"},
      {"control", "%{f(a: 1, b: 2) => 1}"},
      {"control", "... x"},
      {"control", "(...) not in x"},
      {"control", "f + .."},
      {"control", "& 0x0A"},
      {"control", "x\\\n+1"},
      {"control", ":é@bar"},
      {"control", "!(f do x end).foo"},
      {"control", "unquote_splicing(x)"},
      {"control", "fn (a, b) -> 1 end"}
    ]
  end

  def normalize({form, meta, args}) when is_list(meta),
    do: {normalize(form), [], normalize(args)}

  def normalize(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&normalize/1) |> List.to_tuple()

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(value), do: value

  def run do
    results =
      for {id, source} <- cases(), mode <- [:ast, :token_metadata] do
        opts =
          if mode == :token_metadata do
            [
              columns: true,
              token_metadata: true,
              literal_encoder: fn value, meta -> {:ok, {:__lit__, meta, [value]}} end
            ]
          else
            [columns: true]
          end

        oracle = Code.string_to_quoted(source, opts)
        {actual, diagnostics} = Toxic2.parse_to_ast(source, opts)
        errors? = Enum.any?(diagnostics, &Diagnostic.error?/1)

        result =
          case oracle do
            {:error, _reason} ->
              if errors?, do: :agree, else: :missed_error

            {:ok, expected} ->
              cond do
                errors? -> :false_error
                normalize(expected) != normalize(actual) -> :wrong_ast
                mode == :token_metadata and expected != actual -> :metadata
                true -> :agree
              end
          end

        if result != :agree do
          IO.inspect({id, mode, result, source}, label: "DIFFERENCE", limit: :infinity)

          if "--details" in System.argv() do
            IO.inspect(oracle, label: "oracle", limit: :infinity)
            IO.inspect(actual, label: "toxic2", limit: :infinity)
            IO.inspect(diagnostics, label: "diagnostics", limit: :infinity)
          end
        end

        result
      end

    IO.inspect(System.version(), label: "Elixir")
    IO.inspect(length(cases()), label: "Source cases")
    IO.inspect(Enum.frequencies(results), label: "Comparison outcomes")
  end
end

GrammarReview20260905.run()
