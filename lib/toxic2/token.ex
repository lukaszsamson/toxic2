defmodule Toxic2.Token do
  @moduledoc """
  Helpers over the flat hot-path token tuple defined in `TOXIC_2.md`.

      {kind, sl, sc, el, ec, value}

  - `kind`   — an atom; one kind per lexical category (see `TOXIC_2.md` → Token categories).
  - `sl/sc`  — 1-based start line/column.
  - `el/ec`  — 1-based end line/column, **end-exclusive** (`ec` is the column *after* the
               last character; for a 1-char token at column `c`, `ec == c + 1`).
  - `value`  — parsed payload or `nil`.

  The tuple is intentionally flat (no nested span tuple): one fewer allocation per token
  (P7 / Performance rules). These helpers exist for readability and tests; the hot lexer/
  parser loops may pattern-match the tuple directly.
  """

  @type kind :: atom()
  @type t :: {kind(), pos_integer(), pos_integer(), pos_integer(), pos_integer(), term()}

  @doc "Construct a token. Prefer building the tuple inline in hot loops."
  @spec new(kind(), pos_integer(), pos_integer(), pos_integer(), pos_integer(), term()) :: t()
  def new(kind, sl, sc, el, ec, value), do: {kind, sl, sc, el, ec, value}

  @spec kind(t()) :: kind()
  def kind({k, _, _, _, _, _}), do: k

  @spec value(t()) :: term()
  def value({_, _, _, _, _, v}), do: v

  @doc "Returns `{sl, sc, el, ec}` (end-exclusive)."
  @spec span(t()) :: {pos_integer(), pos_integer(), pos_integer(), pos_integer()}
  def span({_, sl, sc, el, ec, _}), do: {sl, sc, el, ec}

  @spec start_line(t()) :: pos_integer()
  def start_line({_, sl, _, _, _, _}), do: sl

  @spec start_col(t()) :: pos_integer()
  def start_col({_, _, sc, _, _, _}), do: sc

  @spec end_line(t()) :: pos_integer()
  def end_line({_, _, _, el, _, _}), do: el

  @spec end_col(t()) :: pos_integer()
  def end_col({_, _, _, _, ec, _}), do: ec

  @doc """
  `true` iff `a` ends exactly where `b` starts (no horizontal gap) — `foo(` vs `foo (`.
  Adjacency, not token kind, drives all whitespace sensitivity (see `TOXIC_2.md` → Cursor
  and Spacing). Phase 1 ships this helper; the parser (phase 3+) consumes it.
  """
  @spec adjacent?(t(), t()) :: boolean()
  def adjacent?({_, _, _, ael, aec, _}, {_, bsl, bsc, _, _, _}), do: ael == bsl and aec == bsc

  @spec same_line?(t(), t()) :: boolean()
  def same_line?({_, _, _, ael, _, _}, {_, bsl, _, _, _, _}), do: ael == bsl

  @doc "`true` iff `a` and `b` are on the same line with at least one space between them."
  @spec separated_on_same_line?(t(), t()) :: boolean()
  def separated_on_same_line?({_, _, _, ael, aec, _}, {_, bsl, bsc, _, _, _}),
    do: ael == bsl and aec < bsc
end
