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
  # `capture_op` (`&`) is a LOW-precedence prefix (90): `&` grabs the whole following expression
  # down to precedence 90, so `& &1 + &2` => `&(&1 + &2)` and `&foo/1 |> g` => `&(foo/1 |> g)`,
  # while `|` (70) / `::` (60) / `when` (50) bind looser and are NOT captured. The `:unary_op` it
  # builds lowers to `{:&, _, [operand]}`; `&N` is the atomic `:capture_int` leaf.
  # `ternary_op` (`//`) is a Nonassoc-300 PREFIX in the yrl (`unary_op_eol -> ternary_op`): this is
  # the documented capture of `Kernel.//2`, `&//2` => `{:/, [c+1], [{:/, [c], nil}, operand]}`.
  @prefix %{unary_op: 300, at_op: 320, dual_op: 300, capture_op: 90, ternary_op: 300}

  # Both lookups are generated atom-dispatch clauses (the `{prec, assoc}` tuples become shared
  # literals) instead of `Map.get` — the Pratt loop probes them on every led/nud step, and the two
  # `Map.get`s were ~4.5% of all parser-stage calls under eprof. The maps stay the single source
  # of truth (they also drive the precedence pin tests).

  @doc "Infix `{precedence, associativity}` for a family, or `nil` if it is not a led operator."
  @spec infix(atom()) :: {pos_integer(), assoc()} | nil
  for {family, pa} <- @infix do
    def infix(unquote(family)), do: unquote(Macro.escape(pa))
  end

  def infix(_family), do: nil

  @doc "Operand binding power for a prefix family, or `nil` if it is not a nud operator."
  @spec prefix(atom()) :: pos_integer() | nil
  for {family, bp} <- @prefix do
    def prefix(unquote(family)), do: unquote(bp)
  end

  def prefix(_family), do: nil
end
