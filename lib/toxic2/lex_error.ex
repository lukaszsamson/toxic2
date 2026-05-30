defmodule Toxic2.LexError do
  @moduledoc """
  Payload of an `:error` token — the **sole transport** for lexer diagnostics (P3, and
  `TOXIC_2.md` → Diagnostics → Lifecycle contract). The lexer never returns a separate error
  list; a lexical error travels inside `{:error, sl, sc, el, ec, %Toxic2.LexError{}}` and the
  parser is the component that turns it into exactly one diagnostic + an error/missing CST node.
  """

  @type t :: %__MODULE__{code: atom(), details: map()}

  @enforce_keys [:code]
  defstruct code: nil, details: %{}

  @spec new(atom(), map()) :: t()
  def new(code, details \\ %{}) when is_atom(code) and is_map(details),
    do: %__MODULE__{code: code, details: details}
end
