# Grammar audit findings — toxic2 vs `elixir_parser.yrl`

> **STATUS (2026-06-10): all 13 findings below are FIXED.** Regression tests live in
> `test/toxic2/yrl_edge_cases_test.exs` (§1–§3) and the parity corpus in
> `test/toxic2/token_metadata_test.exs` (§4). The audit harness (`mix run grammar_audit.exs`)
> now reports exactly the 14 known FUZZER_GAPS residuals listed at the bottom (7 cases × 2 modes)
> and nothing else; `mix toxic2.check` green. Fix notes:
> §1.1 ternary_op as Nonassoc-300 prefix (precedence.ex) + dedicated `//` clause in `lower_unary`;
> §1.2 `parse_struct` skips one eol before `{`; §2.1 `:range_op`/`:ellipsis_op` added to
> `@op_ref_kinds` (standalone `..`/`...` keep nullary `[]`); §2.2 `unwrap_splice_head/1` post-pass
> in `lower_stab_args`; §3.1 `not_in?/2` no longer fuses across an eol; §3.2 map entries reuse the
> container `:ambiguous_no_parens` check; §4.1–4.7 in lower.ex per the table.

Differential audit (2026-06-10) of `Toxic2.parse_to_ast/2` against the official grammar at
`~/elixir/lib/elixir/src/elixir_parser.yrl` (Elixir 1.20.0 oracle, `Code.string_to_quoted/2`).

**Method.** 527 cases derived rule-by-rule from every yrl production family (call shapes,
stab/fn/paren-stab, containers, maps/structs, dot forms, kw lists, access, eol rules, nullary ops,
capture) plus the Erlang helper special-cases (`build_unary_op('//')`, `unwrap_splice`,
`build_paren_stab` `?rearrange_uop`, `build_op` `'//'`/`'not in'` rewrites, `error_*` productions).
Each case is run in two modes:

- **default** — structural AST parity (meta stripped, per the P4 no-meta-parity design) +
  error-status parity (oracle `{:error, _}` ⇒ toxic2 must emit ≥1 `:error` diagnostic; oracle
  `{:ok, _}` ⇒ none).
- **token_metadata** — full-fidelity comparison with `token_metadata: true`, `columns: true`, and
  an identical `literal_encoder` on both sides.

Harness: `grammar_audit.exs` (repo root) — `mix run grammar_audit.exs`.

Everything already catalogued in `test/toxic2/FUZZER_GAPS.md` is excluded (see "Known gaps
re-confirmed" at the bottom). What follows is **new**. Nothing crashed across the run — the
tolerant-parser invariant held everywhere.

## 1. False errors on valid code

Legal, writable Elixir that toxic2 rejects. Worst class — violates "never false-positive on real
code".

### 1.1 `&//2` — capture of the `/` operator

```elixir
&//2
# oracle: {:&, [l1 c1], [{:/, [l1 c4], [{:/, [l1 c2], nil}, 2]}]}
# toxic2: :unexpected_token (ternary_op) + :unexpected_token (int)
```

The grammar admits `//` as a *unary* (`unary_op_eol -> ternary_op`), and `build_unary_op` has a
dedicated `'//'` clause rewriting it into nested `{:/, _, [{:/, _, nil}, Expr]}` — this is the
documented way to capture `Kernel.//2` (division). Toxic2's `parse_prefix` doesn't accept
`:ternary_op` as a prefix (it is in `@op_ref_kinds` but that path doesn't fire here), so the parse
fails. Note the column trick upstream: outer `/` gets `column: Column+1`, inner gets `Column`.

### 1.2 `%Foo\n{}` — eol between struct name and body

```elixir
%Foo
{}
# oracle: {:%, …, [{:__aliases__, …, [:Foo]}, {:%{}, …, []}]}
# toxic2: :expected_struct_body; lowers to {:%, [], [Foo, __error__]} + a separate {:{}, [], []}
```

yrl rule: `map -> '%' map_base_expr eol map_args` explicitly allows one eol. `parse_struct`
(parser.ex ~1735) checks `tk(t, j) == :"{"` directly after the base without skipping an eol.

## 2. Wrong AST on valid code

### 2.1 `&../2` / `&.../2` / `& ../2` — operator-as-identifier in capture

```elixir
&../2
# oracle: {:&, …, [{:/, …, [{:.., [l1 c2], nil}, 2]}]}    # args nil
# toxic2: {:&, …, [{:/, …, [{:.., [l1 c2], []}, 2]}]}     # args []
```

Elixir's tokenizer re-emits an operator followed by `/arity` in capture position as an
**identifier** token, so the oracle builds `{:.., _, nil}` via `build_identifier`. Toxic2 keeps
`range_op`/`ellipsis_op` and lowers the nullary-op form `{:.., _, []}`. Standalone `..` / `(..)`
correctly stay `[]` on both sides — only the capture context differs. Same for `...`.

### 2.2 `((unquote_splicing([1, 2])) -> :ok)` — `unwrap_splice` through parens

```elixir
((unquote_splicing([1, 2])) -> :ok)
# oracle: [{:->, …, [[{:unquote_splicing, …, [[1, 2]]}], :ok]}]
# toxic2: [{:->, …, [[{:__block__, …, [{:unquote_splicing, …, [[1, 2]]}]}], :ok]}]
```

A lone `(unquote_splicing(x))` is wrapped in `__block__` by `build_block` (correct, and toxic2
does this — lower.ex ~1353/2210). But in `stab_parens_many` the grammar applies `unwrap_splice`
to the head args, which strips that wrapper again. Toxic2 keeps the block as the clause arg.

## 3. Missed errors

Oracle rejects; toxic2 builds a tree with **no** `:error` diagnostic (`:unexpected_valid` in
conformance terms).

### 3.1 `a not\nin b`

```elixir
a not
in b
# oracle: syntax error before: in (line 2) — `not in` must not be split across lines
# toxic2: {:not, [], [{:in, [], [a, b]}]}, diags: []
```

Toxic2 fuses `not` + `in` into `not in` across the newline.

### 3.2 `%{f(a) => g b, c}` — no-parens-many call as assoc value

```elixir
%{f(a) => g b, c}
# oracle: syntax error before: ',' (assoc_expr only admits matched/unmatched exprs)
# toxic2: %{f(a) => g(b, c)}, diags: []
```

Adjacent to the catalogued FUZZER_GAPS bucket "map entry that isn't `key => value`"
(`%{foo bar, baz}`), but this is the assoc-**value** position, which is plausible in real code —
counted as new.

## 4. token_metadata / literal_encoder fidelity

Only visible in `token_metadata: true` mode (default mode strips meta by design, P4) — but that
mode claims oracle parity, so these are bugs against `test/toxic2/token_metadata_test.exs` scope.

| # | Input | Divergence |
|---|-------|------------|
| 4.1 | `fn -> end`, `fn x -> end` | Implicit clause body is `handle_literal(nil, StabToken)` upstream — i.e. **encoded** via the literal encoder with the `->` position. Toxic2 emits bare `nil`. |
| 4.2 | `a[b: 1]`, `x[a: 1, b: 2]` | `build_access_arg` passes a `kw_data` bracket-arg **raw** (it is not a list literal). Toxic2 over-encodes it: `{:__lit__, [closing: …, line:, column:], [[…kw…]]}`. |
| 4.3 | `(1..2)//3` | Oracle's `..//` node keeps the `parens: [closing: …]` annotation inherited from the parenthesized `..` (build_op reuses the `..` node's meta). Toxic2 drops it. |
| 4.4 | `f.(1) do end` | `closing:` should be the `)` at line 1 col 5; toxic2 emits col 12 (inside `end`). Plain `f.(1)` is correct. |
| 4.5 | `'a#{1}b'` | The `{:., _, [List, :to_charlist]}` dot node carries the charlist's line/column upstream (set unconditionally, even without token_metadata). Toxic2 hardcodes `[]` — lower.ex:1024. |
| 4.6 | `a\n.b` | When the dot starts a line, oracle anchors the `.` node at the **dot** (line 2, col 1); toxic2 anchors at the identifier (col 2). All same-line dot cases match. |
| 4.7 | `%{:a\n=> 1}` | `assoc:` meta on the key is missing when a newline precedes `=>` (the `=>`-position scan around lower.ex:2245 appears to stop at the eol). Same-line `=>` is correct. |

## Known gaps re-confirmed (excluded, already in FUZZER_GAPS.md)

The audit independently re-hit these catalogued items; listed only to show the harness sees them:

- newline-before-comma missed errors: `[1\n,2]`, `f(1\n, 2)`, `{1\n, 2}`, `<<1\n, 2>>`,
  `[a: 1\n, b: 2]` (and `f a\n, b` correctly errors on both sides);
- `%`-soup false errors: `%...{}`, `%fn -> 1 end{}` (`:expected_map_or_struct` /
  `:expected_struct_body` bucket). NB `%Foo\n{}` (§1.2) is **not** in that bucket — the base is a
  plain alias and only the eol trips it.

## Severity summary

- §1.1–1.2 break real code (`&//2` is the documented capture of `/`) — fix first.
- §2–3 are correctness/error-parity on plausible-but-rare constructs.
- §4 matters only to token_metadata consumers (formatter-grade tooling).
