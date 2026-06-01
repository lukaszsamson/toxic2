defmodule Toxic2.Tokens do
  @moduledoc """
  Token source + cursor primitives (see `TOXIC_2.md` → Cursor and Spacing; Migration Phases #3).

  The lexer produces a source-ordered **list**; this module turns it into the parser's read-only
  view exactly once via `from_list/1`. The **cursor is an integer index `i`** into that view —
  there is no cursor struct, no pushback, no checkpoint object (P6). Advancing is `i + 1`;
  speculation just remembers an earlier `i` and the side-accumulators (parser concern).

  The view is a **tuple** of tokens (built once via `from_list/1`), so `kind/2`, `value/2`,
  `token/2`, `peek_kind/3` are O(1) `elem/2` (a list would make lookahead O(n)).

  Out-of-range indices read as `:eof` (`kind/2`) — the parser never needs an explicit EOF
  token in the stream and never indexes out of bounds.

  > `eol_between?/3` was once backed by an eagerly-built per-token `:eol`-count prefix index (an
  > O(1) guardrail against an O(n²) caller). Profiling showed it was dead weight — built on every
  > parse, never called by the parser — so the index is gone and `eol_between?/3` now scans the
  > range on demand. If a hot caller ever appears, reinstate the prefix tuple in `from_list/1`.

  Whitespace-sensitivity (adjacency) for *individual tokens* lives in `Toxic2.Token`; the
  index-based wrappers here (`adjacent?/3`, `separated_on_same_line?/3`, `same_line?/3`) let the
  parser work purely in `(tokens, i)` terms without unpacking raw tuples.
  """

  alias Toxic2.Token

  @opaque t :: {tokens :: tuple(), size :: non_neg_integer()}

  @doc """
  Build the parser's read-only token view from the lexer's source-ordered list. `List.to_tuple/1`
  gives O(1) indexed access.
  """
  @spec from_list([Token.t()]) :: t()
  def from_list(tokens) when is_list(tokens) do
    toks = List.to_tuple(tokens)
    {toks, tuple_size(toks)}
  end

  @doc "Convenience: tokenize `source` and build the view. Returns `{view, warnings}`."
  @spec from_source(binary(), keyword()) :: {t(), [term()]}
  def from_source(source, opts \\ []) when is_binary(source) do
    {tokens, warnings} = Toxic2.Lexer.tokenize(source, opts)
    {from_list(tokens), warnings}
  end

  @doc "Number of tokens in the view."
  @spec size(t()) :: non_neg_integer()
  def size({_toks, size}), do: size

  @doc "`true` when `i` is at or past the end of the stream."
  @spec at_eof?(t(), integer()) :: boolean()
  def at_eof?({_toks, size}, i), do: i >= size

  @doc "Advance the cursor. (Trivial; provided for symmetry — the cursor is just an integer.)"
  @spec advance(integer()) :: integer()
  def advance(i) when is_integer(i), do: i + 1

  @doc "The token tuple at `i`, or `:eof` when out of range."
  @spec token(t(), integer()) :: Token.t() | :eof
  def token({toks, size}, i) when i >= 0 and i < size, do: elem(toks, i)
  def token(_t, _i), do: :eof

  @doc "Kind at `i`, or `:eof` when out of range."
  @spec kind(t(), integer()) :: atom()
  def kind({toks, size}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 0)
  def kind(_t, _i), do: :eof

  @doc "Value at `i`, or `nil` when out of range."
  @spec value(t(), integer()) :: term()
  def value({toks, size}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 5)
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
  `true` iff at least one `:eol` token lies in the index range `[i, j)`. Scans the range (the old
  O(1) prefix index was removed as dead weight — no hot caller; see the moduledoc note).
  """
  @spec eol_between?(t(), integer(), integer()) :: boolean()
  def eol_between?({toks, size}, i, j)
      when is_integer(i) and is_integer(j) and i >= 0 and i <= j and j <= size do
    scan_eol(toks, i, j)
  end

  # Total like the rest of the cursor: any out-of-range / negative / i > j range → false.
  def eol_between?(_t, _i, _j), do: false

  defp scan_eol(_toks, i, j) when i >= j, do: false

  defp scan_eol(toks, i, j) do
    case elem(toks, i) do
      {:eol, _, _, _, _, _} -> true
      _ -> scan_eol(toks, i + 1, j)
    end
  end

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
