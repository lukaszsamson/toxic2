defmodule Toxic2.Test.Oracle do
  @moduledoc """
  The ONE sanctioned place tests may call Elixir's built-in parser (see `mix help toxic2.guard`):
  it is the oracle Toxic2 is validated against, never a substitute for Toxic2's own pipeline.
  """

  @doc """
  Parse `source` with `Code.string_to_quoted/2` and `token_metadata: true`, `columns: true`, and the
  given `literal_encoder` — the exact options the token_metadata parity suite compares against.
  Returns the quoted AST (raises on parse error, since the corpus is valid Elixir).
  """
  @spec quoted_with_token_metadata(binary(), (term(), keyword() -> {:ok, term()})) :: Macro.t()
  def quoted_with_token_metadata(source, literal_encoder) do
    {:ok, ast} =
      Code.string_to_quoted(source,
        token_metadata: true,
        columns: true,
        literal_encoder: literal_encoder
      )

    ast
  end
end
