# Regenerates the imported conformance corpora from the prior projects' test suites.
#
#   elixir scripts/import_corpus.exs
#
# We keep ONLY the input strings — the suites' own expectations (metadata-rich AST / exact
# `:elixir_tokenizer` tuples) are not Toxic2's contract; the live oracle is the arbiter. Output is
# committed; rerun only when the upstream suites change.
#
# Parser inputs come from several suites, harvested two ways: the literal first argument of
# `assert_conforms(...)` calls, and the literal RHS of `code = "..."` assignments (the `code =
# expr; assert toxic_parse(code) == s2q(code)` idiom). The systematic operator-precedence suite
# builds its inputs by runtime interpolation, so we can't harvest literals — instead we replicate
# a bounded enumeration of its operator matrix here. Lexer inputs come from `tokenize(...)` calls.

base = Path.expand("../..", __DIR__)
out_dir = Path.expand("../test/support", __DIR__)
tp = fn rel -> Path.join([base, "toxic_parser/test", rel]) end

literal = fn
  bin, _self when is_binary(bin) ->
    {:ok, bin}

  {sig, _, [{:<<>>, _, [bin]}, _]}, _self when sig in [:sigil_s, :sigil_S] and is_binary(bin) ->
    {:ok, bin}

  _other, _self ->
    :skip
end

slug = fn title ->
  title
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9]+/, "_")
  |> String.trim("_")
  |> case do
    "" -> "ungrouped"
    s -> s
  end
end

line_of = fn meta -> Keyword.get(meta, :line, 0) end

# Harvest {source, line, group} triples from one suite file. `calls` lists call names whose first
# literal arg is an input; `code_var?` also harvests `code = <literal>` assignments.
collect = fn path, calls, code_var? ->
  ast = path |> File.read!() |> Code.string_to_quoted!(columns: true)

  {_, describes} =
    Macro.prewalk(ast, [], fn
      {:describe, meta, [title | _]} = node, acc when is_binary(title) ->
        {node, [{line_of.(meta), title} | acc]}

      node, acc ->
        {node, acc}
    end)

  describes = Enum.sort_by(describes, &elem(&1, 0))

  group_for = fn line ->
    describes
    |> Enum.take_while(fn {dl, _} -> dl <= line end)
    |> List.last()
    |> case do
      nil -> "ungrouped"
      {_, title} -> title
    end
  end

  add = fn arg, meta, acc ->
    case literal.(arg, literal) do
      {:ok, src} -> [{src, line_of.(meta), group_for.(line_of.(meta))} | acc]
      :skip -> acc
    end
  end

  {_, raw} =
    Macro.prewalk(ast, [], fn
      {name, meta, [arg | _]} = node, acc when is_atom(name) ->
        cond do
          name in calls ->
            {node, add.(arg, meta, acc)}

          code_var? and match?({:=, _, [{:code, _, c}, _]} when is_atom(c), node) ->
            {node, add.(Enum.at(elem(node, 2), 1), meta, acc)}

          true ->
            {node, acc}
        end

      node, acc ->
        {node, acc}
    end)

  raw
end

# --- systematic operator-precedence matrix (replicates systematic_operators_test.exs) ---------
right_assoc = ~w(++ -- +++ --- .. <> = | :: when)

left_assoc =
  ~w(** * / + - ^^^ in |> <<< >>> <<~ ~>> <~ ~> <~> < > <= >= == != =~ === !== && &&& and || ||| or <- \\)

binary_ops = right_assoc ++ left_assoc
unary_str = %{"not" => "not "}
simple_unary = ~w(+ - ! ^ not ~~~)
us = fn u -> Map.get(unary_str, u, u) end

systematic =
  (for(o1 <- binary_ops, o2 <- binary_ops, do: "a #{o1} b #{o2} c") ++
     for(u <- simple_unary, b <- binary_ops, do: "#{us.(u)}a #{b} b") ++
     for(b <- binary_ops, u <- simple_unary, do: "a #{b} #{us.(u)}b"))
  |> Enum.map(fn src -> {src, 0, "systematic operators"} end)

# --- parser corpus: union across suites + the systematic matrix --------------------------------
parser_files = [
  {tp.("conformance_test.exs"), "conformance", [:assert_conforms], false},
  {tp.("conformance_large_test.exs"), "large", [], true},
  {tp.("operators_test.exs"), "operators", [], true},
  {tp.("elixir_source_repros_test.exs"), "repros", [:assert_conforms], true}
]

parser_raw =
  Enum.flat_map(parser_files, fn {path, ftag, calls, code_var?} ->
    collect.(path, calls, code_var?) |> Enum.map(fn {s, l, g} -> {s, l, "#{ftag}: #{g}"} end)
  end) ++ Enum.map(systematic, fn {s, l, g} -> {s, l, "systematic: #{g}"} end)

parser = Enum.uniq_by(parser_raw, fn {s, _l, _g} -> s end)

lexer =
  collect.(tp.("../../toxic/test/toxic/valid_code_test.exs"), [:tokenize], false)
  |> Enum.sort_by(fn {_s, l, _g} -> l end)
  |> Enum.uniq_by(fn {s, _l, _g} -> s end)
  |> Enum.map(fn {s, l, g} -> {s, l, "valid_code: #{g}"} end)

# `group` is "file: describe"; tags = [:imported, file_slug, group_slug] for flexible bucketing.
render = fn module, source_desc, entries ->
  body =
    Enum.map_join(entries, ",\n", fn {src, line, group} ->
      [ftag | _] = String.split(group, ":", parts: 2)

      tags = [:imported, String.to_atom(slug.(ftag)), String.to_atom(slug.(group))] |> Enum.uniq()

      "%{source: #{inspect(src)}, tags: #{inspect(tags)}, group: #{inspect(group)}, line: #{line}}"
    end)

  """
  defmodule #{module} do
    @moduledoc false
    # GENERATED by scripts/import_corpus.exs from #{source_desc}.
    # Do not edit by hand — rerun the generator. Only the input strings are imported; the live
    # oracle (not any captured expectation) is the conformance arbiter.

    @entries [
    #{body}
    ]

    @spec all() :: [%{source: String.t(), tags: [atom()], group: String.t(), line: non_neg_integer()}]
    def all, do: @entries
  end
  """
end

write = fn name, source ->
  File.write!(Path.join(out_dir, name), Code.format_string!(source) ++ ["\n"])
end

write.(
  "imported_parser_corpus.ex",
  render.(
    "Toxic2.Conformance.ImportedParser",
    "toxic_parser conformance/large/operators/repros suites + systematic operator matrix",
    parser
  )
)

write.(
  "imported_lexer_corpus.ex",
  render.("Toxic2.Conformance.ImportedLexer", "toxic/test/toxic/valid_code_test.exs", lexer)
)

IO.puts(
  "imported parser corpus: #{length(parser)} unique sources (#{length(systematic)} systematic)"
)

IO.puts("imported lexer  corpus: #{length(lexer)} unique sources")
