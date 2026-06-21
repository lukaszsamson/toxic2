defmodule Toxic2.Diagnostics do
  @moduledoc """
  The diagnostic accumulator the parser threads (see `TOXIC_2.md` → Diagnostics → Lifecycle
  contract). Not a struct — just functions over a **reversed list** and a monotonic **next-id**
  integer, both carried as plain arguments (P7).

  `emit/7` allocates the next id, builds the diagnostic, prepends it, and returns the allocated
  id (so the caller can attach it to a CST error/missing node's `diag_ids`) alongside the grown
  accumulator and the next id.

  The single combined stream (lexer + parser + lowerer) is assembled at the boundary; `to_list/1`
  reverses to source order, and `merge_sorted/1` orders multiple streams by start position.
  """

  alias Toxic2.Diagnostic

  @type acc :: [Diagnostic.t()]

  @doc "Empty accumulator + first id. Ids start at 1 (deterministic within a parse)."
  @spec new() :: {acc(), pos_integer()}
  def new, do: {[], 1}

  @doc """
  Allocate, build, and prepend a diagnostic. Returns `{allocated_id, acc, next_id}`.

      {diag_id, diags, next_id} =
        Diagnostics.emit(diags, next_id, :parser, :error, :expected_rparen, span)
      CST.missing(:")", i, diag: diag_id)
  """
  @spec emit(
          acc(),
          pos_integer(),
          Diagnostic.phase(),
          Diagnostic.severity(),
          atom(),
          Diagnostic.span(),
          map()
        ) ::
          {pos_integer(), acc(), pos_integer()}
  def emit(acc, next_id, phase, severity, code, span, details \\ %{}) do
    diag = Diagnostic.new(next_id, phase, severity, code, span, details)
    {next_id, [diag | acc], next_id + 1}
  end

  @doc "Reverse the accumulator to source-emission order."
  @spec to_list(acc()) :: [Diagnostic.t()]
  def to_list(acc), do: :lists.reverse(acc)

  @doc "Only the `:error`-severity diagnostics (what the strict wrapper checks — P1)."
  @spec errors([Diagnostic.t()]) :: [Diagnostic.t()]
  def errors(diags), do: Enum.filter(diags, &Diagnostic.error?/1)

  @doc """
  Number a list of id-less lexer notices (`{phase, severity, code, span, details}`, in source order)
  into full diagnostics, allocating ids from `start_id`. Returns `{diagnostics, next_id}`.

  Lexer WARNINGS ride the lexer's out-of-band notice channel (the lexer returns `{tokens, notices}`;
  they are never put in the token stream); `Tokens.from_source` passes the notices through alongside
  the token view. Their ids are allocated here, AFTER the parser's, so the combined stream stays
  unique (lexer ERRORS keep their own transport — an in-stream `:error` token the parser converts).
  """
  @spec number([tuple()], pos_integer()) :: {[Diagnostic.t()], pos_integer()}
  def number(notices, start_id) do
    {rev, nid} =
      Enum.reduce(notices, {[], start_id}, fn {phase, severity, code, span, details}, {acc, id} ->
        {[Diagnostic.new(id, phase, severity, code, span, details) | acc], id + 1}
      end)

    {:lists.reverse(rev), nid}
  end

  @doc "One past the highest id in `diags` (1 when empty) — the next free id."
  @spec next_id([Diagnostic.t()]) :: pos_integer()
  def next_id(diags) do
    # Fold an explicit integer accumulator rather than `max/2` + 1: `max/2`'s success typing
    # widens to `number()`, so dialyzer infers a spurious `float()` return for the trailing `+ 1`.
    Enum.reduce(diags, 1, fn d, acc ->
      id = Diagnostic.id(d)
      if id >= acc, do: id + 1, else: acc
    end)
  end

  @doc "Merge already-source-ordered streams into one, stably ordered by start position."
  @spec merge_sorted([[Diagnostic.t()]]) :: [Diagnostic.t()]
  def merge_sorted(streams) do
    streams
    |> Enum.concat()
    |> Enum.sort_by(fn d -> {elem(d, 4), elem(d, 5)} end)
  end
end
