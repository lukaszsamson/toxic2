defmodule Toxic2.CST do
  @moduledoc """
  Nested green CST: node shapes, bitset flags, and constructors (see `TOXIC_2.md` → Nested Green
  CST; Migration Phases #4).

  **Nested, not an arena.** Recursive descent builds children before parents, so a parent simply
  holds its children directly — no node ids, no `next_id` threading, no id→node resolution.

  Three node shapes (flat tuples, no struct on the hot path):

      {:node, kind, span, children, flags, diag_ids}
      {:token, token_index, flags, diag_ids}
      {:missing, expected_kind, anchor_index, flags, diag_ids}

  `:token` / `:missing` store an **index** into the `Toxic2.Tokens` view, not a span; their span
  is resolved against the view at lowering/diagnostic time. `:node` carries its own span.

  **Flags are a bitset** (an integer), never a map. `has_error`, `contains_eol`, and
  `has_comments` are **inherited** — OR-ed up from children when a `:node` is built — so
  "does this subtree contain an error?" is an O(1) flag read, never a re-walk (P9). `synthetic`
  and the expression class (`matched` / `unmatched` / `no_parens`) are **node-local**: set by the
  builder, not inherited.

  `diag_ids` is `nil | id | [id]` — the common 0/1-diagnostic node avoids a cons cell; a list is
  used only for the rare multi-diagnostic node. `diag_ids/1` always normalizes to a list.
  """

  import Bitwise

  # Bit positions (kept as literals so the attributes need no Bitwise at definition time).
  @flag_has_error 1
  @flag_synthetic 2
  @flag_contains_eol 4
  @flag_has_comments 8
  @flag_matched 16
  @flag_unmatched 32
  @flag_no_parens 64

  # Flags that propagate from children to parent at construction.
  @inheritable @flag_has_error ||| @flag_contains_eol ||| @flag_has_comments

  @type span :: {pos_integer(), pos_integer(), pos_integer(), pos_integer()}
  @type flags :: non_neg_integer()
  @type diag_ids :: nil | pos_integer() | [pos_integer()]
  @type category :: :matched | :unmatched | :no_parens
  @type node_t :: {:node, atom(), span(), [t()], flags(), diag_ids()}
  @type token_t :: {:token, non_neg_integer(), flags(), diag_ids()}
  @type missing_t :: {:missing, atom(), non_neg_integer(), flags(), diag_ids()}
  @type t :: node_t() | token_t() | missing_t()

  @doc """
  Build an internal node. `has_error` / `contains_eol` / `has_comments` are OR-ed up from
  `children` automatically (P9).

  Options: `:category` (`:matched | :unmatched | :no_parens`), `:synthetic` (bool),
  `:contains_eol` (bool, node-local in addition to inherited), `:diag` (single id) or
  `:diags` (list).
  """
  @spec node(atom(), span(), [t()], keyword()) :: node_t()
  def node(kind, span, children, opts \\ []) when is_list(children) do
    base =
      0
      |> set_if(Keyword.get(opts, :synthetic, false), @flag_synthetic)
      |> set_if(Keyword.get(opts, :contains_eol, false), @flag_contains_eol)
      |> bor(category_bit(Keyword.get(opts, :category)))

    {:node, kind, span, children, inherit(base, children), diags_opt(opts)}
  end

  @doc """
  Keyword-free fast constructor for the parser hot path: `category` is an atom
  (`:matched | :unmatched | :no_parens | nil`) and `diag_ids` is `nil | id | [id]`.
  `has_error` / `contains_eol` still inherit from `children` (P9).
  """
  @spec node(atom(), span(), [t()], category() | nil, diag_ids()) :: node_t()
  def node(kind, span, children, category, diag_ids) when is_atom(category) do
    {:node, kind, span, children, inherit(category_bit(category), children), diag_ids}
  end

  @doc """
  Build a leaf referencing token `index` in the `Toxic2.Tokens` view.

  Options: `:error` (bool — set when wrapping a lexer `:error` token), `:synthetic` (bool),
  `:contains_eol` (bool), `:diag` / `:diags`.
  """
  # Hot path: the parser builds the vast majority of token leaves with NO options, so skip the
  # `Keyword.get` flag/diag decoding entirely (it was the dominant `lists:keyfind` source) and build
  # the plain leaf directly: no flags, no diagnostics.
  @spec token(non_neg_integer()) :: token_t()
  def token(index) when is_integer(index) and index >= 0, do: {:token, index, 0, []}

  @spec token(non_neg_integer(), keyword()) :: token_t()
  def token(index, opts) when is_integer(index) and index >= 0 do
    flags =
      0
      |> set_if(Keyword.get(opts, :error, false), @flag_has_error)
      |> set_if(Keyword.get(opts, :synthetic, false), @flag_synthetic)
      |> set_if(Keyword.get(opts, :contains_eol, false), @flag_contains_eol)

    {:token, index, flags, diags_opt(opts)}
  end

  @doc """
  Build a missing-token placeholder anchored at `anchor_index`. Always `synthetic` and
  `has_error` (a missing token is, by definition, an error). Option `:diag` / `:diags`.
  """
  @spec missing(atom(), non_neg_integer(), keyword()) :: missing_t()
  def missing(expected_kind, anchor_index, opts \\ [])
      when is_integer(anchor_index) and anchor_index >= 0 do
    {:missing, expected_kind, anchor_index, @flag_synthetic ||| @flag_has_error, diags_opt(opts)}
  end

  # --- accessors ---------------------------------------------------------

  @spec tag(t()) :: :node | :token | :missing
  def tag(cst), do: elem(cst, 0)

  @doc "Children of a `:node`; `[]` for leaves."
  @spec children(t()) :: [t()]
  def children({:node, _kind, _sp, ch, _f, _d}), do: ch
  def children(_leaf), do: []

  @doc "Kind of a `:node`, expected kind of a `:missing`, or `:token` for a token leaf."
  @spec node_kind(t()) :: atom()
  def node_kind({:node, kind, _sp, _ch, _f, _d}), do: kind
  def node_kind({:missing, expected, _ai, _f, _d}), do: expected
  def node_kind({:token, _i, _f, _d}), do: :token

  @doc "Span of a `:node`; `nil` for `:token` / `:missing` (resolve via the `Toxic2.Tokens` view)."
  @spec span(t()) :: span() | nil
  def span({:node, _kind, sp, _ch, _f, _d}), do: sp
  def span(_leaf), do: nil

  @spec token_index(t()) :: non_neg_integer() | nil
  def token_index({:token, i, _f, _d}), do: i
  def token_index(_), do: nil

  @spec anchor_index(t()) :: non_neg_integer() | nil
  def anchor_index({:missing, _e, ai, _f, _d}), do: ai
  def anchor_index(_), do: nil

  @spec flags(t()) :: flags()
  def flags({:node, _k, _sp, _ch, f, _d}), do: f
  def flags({:token, _i, f, _d}), do: f
  def flags({:missing, _e, _ai, f, _d}), do: f

  @doc "Normalized to a list (`nil → []`, `id → [id]`)."
  @spec diag_ids(t()) :: [pos_integer()]
  def diag_ids({:node, _k, _sp, _ch, _f, d}), do: List.wrap(d)
  def diag_ids({:token, _i, _f, d}), do: List.wrap(d)
  def diag_ids({:missing, _e, _ai, _f, d}), do: List.wrap(d)

  @spec has_error?(t()) :: boolean()
  def has_error?(cst), do: flag?(cst, @flag_has_error)

  @spec synthetic?(t()) :: boolean()
  def synthetic?(cst), do: flag?(cst, @flag_synthetic)

  @spec contains_eol?(t()) :: boolean()
  def contains_eol?(cst), do: flag?(cst, @flag_contains_eol)

  @doc "Expression class, or `nil` if unclassified."
  @spec category(t()) :: category() | nil
  def category(cst) do
    f = flags(cst)

    cond do
      (f &&& @flag_matched) != 0 -> :matched
      (f &&& @flag_unmatched) != 0 -> :unmatched
      (f &&& @flag_no_parens) != 0 -> :no_parens
      true -> nil
    end
  end

  # --- internals ---------------------------------------------------------

  defp flag?(cst, bit), do: (flags(cst) &&& bit) != 0

  defp inherit(base, children) do
    Enum.reduce(children, base, fn child, acc -> bor(acc, flags(child) &&& @inheritable) end)
  end

  defp set_if(flags, true, bit), do: bor(flags, bit)
  defp set_if(flags, false, _bit), do: flags

  defp category_bit(:matched), do: @flag_matched
  defp category_bit(:unmatched), do: @flag_unmatched
  defp category_bit(:no_parens), do: @flag_no_parens
  defp category_bit(nil), do: 0

  defp diags_opt(opts) do
    cond do
      ids = Keyword.get(opts, :diags) -> ids
      id = Keyword.get(opts, :diag) -> id
      true -> nil
    end
  end
end
