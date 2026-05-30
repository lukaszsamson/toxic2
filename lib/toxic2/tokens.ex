defmodule Toxic2.Tokens do
  @moduledoc """
  Token source + cursor primitives (see `TOXIC_2.md` → Cursor and Spacing; Migration Phases #3).

  The lexer produces a source-ordered **list**; this module turns it into the parser's read-only
  view exactly once via `from_list/1`. The **cursor is an integer index `i`** into that view —
  there is no cursor struct, no pushback, no checkpoint object (P6). Advancing is `i + 1`;
  speculation just remembers an earlier `i` and the side-accumulators (parser concern).

  Two structures are built once and never mutated:

  - a **tuple** of tokens, so `kind/2`, `value/2`, `token/2`, `peek_kind/3` are O(1) `elem/2`
    (a list would make lookahead O(n));
  - an **`eol_prefix`** tuple where `eol_prefix[k]` is the number of `:eol` tokens at indices
    `< k`, so `eol_between?/3` answers "is there a newline in this index range" in **O(1)** for
    *any* span. This is the spec's guardrail against `has_eol_between?` becoming a hidden O(n²)
    when called from Pratt / no-parens decisions over growing spans.

  Out-of-range indices read as `:eof` (`kind/2`) — the parser never needs an explicit EOF
  token in the stream and never indexes out of bounds.

  Whitespace-sensitivity (adjacency) for *individual tokens* lives in `Toxic2.Token`; the
  index-based wrappers here (`adjacent?/3`, `separated_on_same_line?/3`, `same_line?/3`) let the
  parser work purely in `(tokens, i)` terms without unpacking raw tuples.
  """

  alias Toxic2.Token

  @opaque t :: {tokens :: tuple(), eol_prefix :: tuple(), size :: non_neg_integer()}

  @doc """
  Build the parser's read-only token view from the lexer's source-ordered list.

  One pass builds the `eol_prefix` index; `List.to_tuple/1` gives O(1) indexed access.
  """
  @spec from_list([Token.t()]) :: t()
  def from_list(tokens) when is_list(tokens) do
    rev_prefix =
      Enum.reduce(tokens, [0], fn tok, [p | _] = acc ->
        [p + eol_inc(tok) | acc]
      end)

    eol_prefix = rev_prefix |> :lists.reverse() |> List.to_tuple()
    toks = List.to_tuple(tokens)
    {toks, eol_prefix, tuple_size(toks)}
  end

  @doc "Convenience: tokenize `source` and build the view. Returns `{view, warnings}`."
  @spec from_source(binary(), keyword()) :: {t(), [term()]}
  def from_source(source, opts \\ []) when is_binary(source) do
    {tokens, warnings} = Toxic2.Lexer.tokenize(source, opts)
    {from_list(tokens), warnings}
  end

  defp eol_inc({:eol, _, _, _, _, _}), do: 1
  defp eol_inc(_), do: 0

  @doc "Number of tokens in the view."
  @spec size(t()) :: non_neg_integer()
  def size({_toks, _eol, size}), do: size

  @doc "`true` when `i` is at or past the end of the stream."
  @spec at_eof?(t(), integer()) :: boolean()
  def at_eof?({_toks, _eol, size}, i), do: i >= size

  @doc "Advance the cursor. (Trivial; provided for symmetry — the cursor is just an integer.)"
  @spec advance(integer()) :: integer()
  def advance(i) when is_integer(i), do: i + 1

  @doc "The token tuple at `i`, or `:eof` when out of range."
  @spec token(t(), integer()) :: Token.t() | :eof
  def token({toks, _eol, size}, i) when i >= 0 and i < size, do: elem(toks, i)
  def token(_t, _i), do: :eof

  @doc "Kind at `i`, or `:eof` when out of range."
  @spec kind(t(), integer()) :: atom()
  def kind({toks, _eol, size}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 0)
  def kind(_t, _i), do: :eof

  @doc "Value at `i`, or `nil` when out of range."
  @spec value(t(), integer()) :: term()
  def value({toks, _eol, size}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 5)
  def value(_t, _i), do: nil

  @doc "Span `{sl, sc, el, ec}` at `i`, or `nil` when out of range."
  @spec span(t(), integer()) :: {pos_integer(), pos_integer(), pos_integer(), pos_integer()} | nil
  def span(t, i) do
    case token(t, i) do
      :eof -> nil
      tok -> Token.span(tok)
    end
  end

  @doc "Kind `n` tokens ahead of `i` (`n` may be 0 or negative); `:eof` past the ends."
  @spec peek_kind(t(), integer(), integer()) :: atom()
  def peek_kind(t, i, n), do: kind(t, i + n)

  @doc """
  `true` iff at least one `:eol` token lies in the index range `[i, j)`. O(1) via `eol_prefix`.

  Use this — not a scan — for any newline question over a span whose width depends on
  subexpression size (operator-newline continuation, no-parens boundaries). `i` is normally a
  real (non-`:eol`) anchor, so `[i, j)` and the strict `(i, j)` agree.
  """
  @spec eol_between?(t(), integer(), integer()) :: boolean()
  def eol_between?({_toks, eol_prefix, _size}, i, j)
      when is_integer(i) and is_integer(j) and i >= 0 and i <= j and j < tuple_size(eol_prefix) do
    elem(eol_prefix, j) - elem(eol_prefix, i) > 0
  end

  # Total like the rest of the cursor: any out-of-range / negative / i > j range → false.
  def eol_between?(_t, _i, _j), do: false

  @doc "`true` iff tokens `i` and `j` are adjacent (no horizontal gap). `false` at either EOF."
  @spec adjacent?(t(), integer(), integer()) :: boolean()
  def adjacent?(t, i, j), do: pair(t, i, j, &Token.adjacent?/2)

  @doc "`true` iff tokens `i` and `j` are on the same line. `false` at either EOF."
  @spec same_line?(t(), integer(), integer()) :: boolean()
  def same_line?(t, i, j), do: pair(t, i, j, &Token.same_line?/2)

  @doc "`true` iff `i` and `j` are on the same line with space between them. `false` at EOF."
  @spec separated_on_same_line?(t(), integer(), integer()) :: boolean()
  def separated_on_same_line?(t, i, j), do: pair(t, i, j, &Token.separated_on_same_line?/2)

  defp pair(t, i, j, fun) do
    a = token(t, i)
    b = token(t, j)
    a != :eof and b != :eof and fun.(a, b)
  end
end
