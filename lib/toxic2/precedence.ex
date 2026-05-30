defmodule Toxic2.Precedence do
  @moduledoc """
  Operator binding powers, **pinned to `elixir_parser.yrl`** (see `TOXIC_2.md` → Pratt scope;
  Migration Phases #5). Keyed by operator **family** — the kind the lexer already tags — so the
  table mirrors yecc's precedence declarations one-to-one:

      Left  40 in_match_op    Right 50 when_op     Right 60 type_op    Right 70 pipe_op
      Right 80 assoc_op       Right 100 match_op   Left 120 or_op      Left 130 and_op
      Left  140 comp_op       Left 150 rel_op      Left 160 arrow_op   Left 170 in_op
      Left  180 xor_op        Right 190 ternary_op Right 200 concat/range
      Left  210 dual_op       Left 220 mult_op     Right 230 power_op
      Nonassoc 300 unary_op   Nonassoc 320 at_op

  Structural / not-yet-supported families (`stab_op` 10, `capture_op`/`ellipsis_op` 90, the
  `dot` family 310) are intentionally absent from the infix table — the Pratt led loop stops at
  them, leaving stabs/captures/dot-calls to their dedicated phases (P8: Pratt is operators only).
  """

  @type assoc :: :left | :right

  # Infix (led) operators: family => {precedence, associativity}.
  @infix %{
    in_match_op: {40, :left},
    when_op: {50, :right},
    type_op: {60, :right},
    pipe_op: {70, :right},
    # assoc_op (`=>`, 80) is intentionally absent: it is only valid inside `%{...}` and is
    # rejected at top level by Elixir. It is handled by the map/keyword grammar routine
    # (phase 7), not the generic expression Pratt loop.
    match_op: {100, :right},
    or_op: {120, :left},
    and_op: {130, :left},
    comp_op: {140, :left},
    rel_op: {150, :left},
    arrow_op: {160, :left},
    in_op: {170, :left},
    xor_op: {180, :left},
    ternary_op: {190, :right},
    concat_op: {200, :right},
    range_op: {200, :right},
    dual_op: {210, :left},
    mult_op: {220, :left},
    # `**` is LEFT-associative in the live oracle (Elixir 1.19.5: `2 ** 3 ** 4` => `(2**3)**4`),
    # though a stale `elixir_parser.yrl` copy declared it Right. The conformance oracle is the
    # arbiter (P10), and the harness caught the discrepancy.
    power_op: {230, :left}
  }

  # Prefix (nud) operators: family => operand binding power. `dual_op` (`+`/`-`) is unary here
  # (300), infix elsewhere (210) — the parser picks by position, no lexer deferral (P2).
  @prefix %{unary_op: 300, at_op: 320, dual_op: 300}

  @doc "Infix `{precedence, associativity}` for a family, or `nil` if it is not a led operator."
  @spec infix(atom()) :: {pos_integer(), assoc()} | nil
  def infix(family), do: Map.get(@infix, family)

  @doc "Operand binding power for a prefix family, or `nil` if it is not a nud operator."
  @spec prefix(atom()) :: pos_integer() | nil
  def prefix(family), do: Map.get(@prefix, family)
end
