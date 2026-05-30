defmodule Toxic2.Diagnostic do
  @moduledoc """
  A single diagnostic, as a **flat tuple** (no struct/map on the hot path; see `TOXIC_2.md` →
  Diagnostics):

      {id, phase, severity, code, sl, sc, el, ec, details}

  - `id` — monotonic + deterministic within one parse (allocated by `Toxic2.Diagnostics`).
  - `phase` — `:lexer | :parser | :lowerer` (origin in the single combined stream).
  - `severity` — `:error | :warning`. Only `:error` trips strict mode (P1).
  - `code` — a machine atom (own taxonomy; never matched against upstream strings, P4/P10).
  - `sl/sc/el/ec` — bounded source range.
  - `details` — optional map for extras.

  Convert to a public struct only at the API boundary; internally this stays a tuple.
  """

  @type phase :: :lexer | :parser | :lowerer
  @type severity :: :error | :warning
  @type span :: {pos_integer(), pos_integer(), pos_integer(), pos_integer()}
  @type t ::
          {pos_integer(), phase(), severity(), atom(), pos_integer(), pos_integer(),
           pos_integer(), pos_integer(), map()}

  @spec new(pos_integer(), phase(), severity(), atom(), span(), map()) :: t()
  def new(id, phase, severity, code, {sl, sc, el, ec}, details \\ %{}) do
    {id, phase, severity, code, sl, sc, el, ec, details}
  end

  @spec id(t()) :: pos_integer()
  def id(d), do: elem(d, 0)

  @spec phase(t()) :: phase()
  def phase(d), do: elem(d, 1)

  @spec severity(t()) :: severity()
  def severity(d), do: elem(d, 2)

  @spec code(t()) :: atom()
  def code(d), do: elem(d, 3)

  @spec span(t()) :: span()
  def span({_id, _ph, _sev, _code, sl, sc, el, ec, _det}), do: {sl, sc, el, ec}

  @spec details(t()) :: map()
  def details(d), do: elem(d, 8)

  @spec error?(t()) :: boolean()
  def error?(d), do: elem(d, 2) == :error
end
