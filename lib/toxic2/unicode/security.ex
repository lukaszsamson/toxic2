# Vendored from Elixir's `String.Tokenizer.Security` (lib/elixir/unicode/security.ex) — the UTS-39
# confusables check. Kept here under `lib/toxic2/unicode/` (guard/Credo exempt, like the tokenizer
# port) so toxic2 has no dependency on `String.Tokenizer.Security`. The skeleton / prototype /
# bidi-skeleton logic is verbatim (replacing `String.Tokenizer.dir/1` with the vendored tokenizer's);
# only the token iteration is adapted to toxic2's token shape, emitting `:confusable_identifier`
# warning notices instead of Elixir warning tuples.
defmodule Toxic2.String.Tokenizer.Security do
  @moduledoc false

  alias Toxic2.String.Tokenizer

  # toxic2 identifier-bearing token kinds (Elixir splits these into op/paren/bracket variants).
  @identifier_kinds [:identifier, :kw_identifier, :alias, :atom]

  @doc """
  Scan a token stream for confusable identifiers (UTS-39). Returns id-less lexer warning notices
  `{:lexer, :warning, :confusable_identifier, {sl, sc, sl, sc}, details}` in token order. Two
  identifiers whose confusable *skeletons* coincide but whose characters differ are flagged.
  """
  def lint(tokens) do
    {_skeletons, rev} =
      Enum.reduce(tokens, {%{}, []}, fn token, {skeletons, warnings} ->
        check_token(token, skeletons, warnings)
      end)

    :lists.reverse(rev)
  end

  defp check_token({kind, sl, sc, _el, _ec, value}, skeletons, warnings)
       when kind in @identifier_kinds and is_binary(value) and value != "" do
    name = String.to_charlist(value)

    # An ASCII identifier's confusable skeleton IS its own charlist (ASCII NFD = ASCII, and A-Za-z0-9
    # are excluded from the confusable→prototype map), so skip the two `:unicode.characters_to_nfd_list`
    # passes + `bidi_skeleton` for it. Behaviour-identical: a unicode confusable that maps to an ASCII
    # prototype still produces that same charlist, so collisions are still detected. It matters because
    # the lint, once it runs (a file with ≥1 unicode name), otherwise paid full NFD for EVERY ASCII
    # identifier — ~18% of CPU on unicode-touched, identifier-dense files. `byte_size == length` of the
    # codepoint charlist is the all-ASCII test.
    skeleton = if byte_size(value) == length(name), do: name, else: confusable_skeleton(name)

    case skeletons[skeleton] do
      {_, _, ^name} ->
        {skeletons, warnings}

      {prev_line, _, prev_name} when name != prev_name ->
        details = %{
          name: value,
          prev_name: List.to_string(prev_name),
          prev_line: prev_line
        }

        {skeletons,
         [{:lexer, :warning, :confusable_identifier, {sl, sc, sl, sc}, details} | warnings]}

      _ ->
        {Map.put(skeletons, skeleton, {sl, sc, name}), warnings}
    end
  end

  defp check_token(_token, skeletons, warnings), do: {skeletons, warnings}

  ## Skeleton (UTS-39 section 4) — verbatim from String.Tokenizer.Security.

  confusables_path = "confusables.txt"

  @external_resource Path.join(__DIR__, confusables_path)

  lines =
    Path.join(__DIR__, confusables_path)
    |> File.read!()
    |> String.split(["\r\n", "\n"], trim: true)

  regex = ~r/^((?:[0-9A-F]+ )+);\t((?:[0-9A-F]+ )+);/u
  matches = Enum.map(lines, &Regex.run(regex, &1, capture: :all_but_first))

  confusable_prototype_lookup =
    for [confusable_str, prototype_str] <- matches, reduce: %{} do
      acc ->
        confusable = String.to_integer(String.trim(confusable_str), 16)

        if Map.has_key?(acc, confusable) or
             confusable in ?A..?Z or confusable in ?a..?z or confusable in ?0..?9 do
          acc
        else
          prototype =
            prototype_str
            |> String.split(" ", trim: true)
            |> Enum.map(&String.to_integer(&1, 16))

          Map.put(acc, confusable, prototype)
        end
    end

  for {confusable, prototype} <- confusable_prototype_lookup do
    defp confusable_prototype(unquote(confusable)) do
      unquote(prototype)
    end
  end

  defp confusable_prototype(other), do: <<other::utf8>>

  def confusable_skeleton(s) do
    :unicode.characters_to_nfd_list(s)
    |> bidi_skeleton()
    |> :unicode.characters_to_nfd_list()
  end

  def bidi_skeleton(s) do
    if match?([_, _ | _], s) and any_rtl?(s) do
      unbidify(s) |> Enum.map(&confusable_prototype/1)
    else
      Enum.map(s, &confusable_prototype/1)
    end
  end

  defp any_rtl?(s), do: Enum.any?(s, &(:rtl == Tokenizer.dir(&1)))

  # make charlist match visual order by reversing spans of {rtl, neutral} (UTS39-28 §4 fast path).
  def unbidify(chars) when is_list(chars) do
    {neutrals, direction, last_part, acc} =
      Enum.reduce(chars, {[], :ltr, [], []}, fn head, {neutrals, part_dir, part, acc} ->
        case Tokenizer.dir(head) do
          :weak_number ->
            {[], part_dir, [head] ++ neutrals ++ part, acc}

          :neutral ->
            {[head | neutrals], part_dir, part, acc}

          ^part_dir ->
            {[], part_dir, [head | neutrals] ++ part, acc}

          :ltr when part_dir == :rtl ->
            {[], :ltr, [head | neutrals], Enum.reverse(part, acc)}

          :rtl when part_dir == :ltr ->
            {[], :rtl, [head], neutrals ++ part ++ acc}
        end
      end)

    case direction do
      :ltr -> Enum.reverse(acc, Enum.reverse(neutrals ++ last_part))
      :rtl -> Enum.reverse(acc, neutrals ++ last_part)
    end
  end
end
