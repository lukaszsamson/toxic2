# Toxic2 — LSP Semantic Tokens Design & Spec

Status: design (no code yet). Target: a `Toxic2.SemanticTokens` module that turns toxic2's
tokens + green CST into an LSP semantic-tokens stream, layered on top of the existing
[vscode-elixir-ls TextMate grammar](/Users/lukaszsamson/vscode-elixir-ls/syntaxes/elixir.json).

Spec reference: LSP 3.18 `textDocument/semanticTokens`
(<https://microsoft.github.io/language-server-protocol/specifications/lsp/3.18/specification/#textDocument_semanticTokens>).

---

## 1. Core principle — a sparse, name-level overlay

VS Code paints the **TextMate grammar first**, then overlays semantic tokens **only where a
token has a matching theme rule or a `semanticTokenScopes` fallback**. Anywhere we emit nothing,
the grammar shows through unchanged.

So the test for every token is **not** "what color is it" but:

> **Does toxic2 know something the regex grammar gets wrong or can't know?**

If not, **emit nothing** and let TextMate keep it. By that test the emit set collapses to
**identity tokens (names) plus a few literals**. Everything *structural* stays with TextMate:

| Stays with TextMate — DO NOT emit | Why |
|---|---|
| operators (`:*_op`, `:dot`) | fixed lexemes; the grammar's `keyword.operator.arithmetic` / `.comparison` sub-scoping is richer than a flat `operator` |
| control/block keywords as rendered (`do end fn` etc.) | regex-reliable on fixed lexemes |
| comments (`# …`) | single-line, regex-perfect; also means the provider never needs comment preservation |
| string / charlist / heredoc **interiors**, escapes, interpolation `#{}`, regex internals | the grammar's nested scoping (`string.regexp.character-class`, `punctuation.section.embedded`, escapes) beats a flat span |
| delimiters / punctuation `( ) [ ] { } << >>`, quotes | regex-trivial |

**Consequence (important):** because we never span a string/heredoc interior, and Elixir comments
are single-line, **every token we emit is single-line and non-overlapping by construction.** The
provider therefore needs neither `multilineTokenSupport` nor `overlappingTokenSupport`, and never
needs the lexer's comment-preservation option.

---

## 2. What is knowable without a symbol table

toxic2's parser builds a CST but does **no name resolution**. Semantic roles here are *syntactic*.
Honest limits:

- **`parameter`** — recoverable in a clause head, but not for the same name's uses in the body
  (needs scope tracking). Partial parameter highlighting is *worse* than uniform `variable`.
  **Deferred to a future symbol-aware pass.**
- **`modification`** (assignment LHS rebind) — needs flow. **Deferred.**
- **local call → user macro vs function** — undecidable without compilation. Honest default for a
  local-call callee is `function`.
- **closed name-sets ARE honest** — special forms, the def-family, and module directives are fixed
  names the compiler treats specially. They can be classified by name without a symbol table.
  This is the only "defaultLibrary knowledge" we rely on.

Also out of scope for v1: `__MODULE__`/`__ENV__`/`__CALLER__`/`__DIR__`/`__STACKTRACE__` (closed
set — defer to TextMate, or a later `variable.defaultLibrary`), and hygiene inside
`quote`/`unquote`.

---

## 3. Legend (client-facing contract)

Advertise **only the types/modifiers we actually emit**. The legend is **append-only forever** —
delta encoding and client caches key on the *index*, so post-ship you may append but never reorder
or remove. Start minimal precisely so you never need to reorder.

```elixir
# Toxic2.SemanticTokens.legend/0
types = ~w(
  namespace type class function method macro property number variable
  atom attribute typespec sigil capture
)   #            ^^^^^^^^                ^^^^ last 5 are custom (extension-defined)
    # `variable` is present only if the clean-subtree gate (§6) ships; drop it if `variable` is deferred.

modifiers = ~w(definition declaration readonly documentation deprecated defaultLibrary)
```

Standard types emitted: `namespace type class function method macro property number variable`.
Custom types emitted: `atom attribute typespec sigil capture`.
**Not** in the legend (never emitted): `operator keyword decorator comment string`.

### Custom-type rationale

- `atom` — toxic2 separates `:atom` from `:kw_identifier` lexically; regex botches this.
- `attribute` — module attribute *names* (`@foo`, `@spec`).
- `typespec` — function name inside `@spec`/`@callback` (the grammar already carves out
  `entity.name.function.typespec.elixir`, so the ecosystem wants spec-names distinct from both
  plain functions and types). Type *names* in `@type`/`@opaque` use the standard `type` instead.
- `sigil` — sigil head only (`~r`, `~w`, `~FOO`).
- `capture` — `&1`, `&fun/arity`.

---

## 4. VS Code manifest (`package.json` → `contributes`)

`semanticTokenScopes` is the load-bearing "play nice" mechanism: it makes every custom **and**
standard type degrade to exactly the scope the grammar would have produced when a theme has no
explicit semantic rule.

```jsonc
{
  "contributes": {
    "semanticTokenTypes": [
      { "id": "atom",      "superType": "enumMember", "description": "Elixir atom literal" },
      { "id": "attribute", "superType": "property",   "description": "Module attribute name" },
      { "id": "typespec",  "superType": "function",   "description": "Function name in @spec/@callback" },
      { "id": "sigil",     "superType": "macro",      "description": "Sigil head (~r, ~w, ~FOO)" },
      { "id": "capture",   "superType": "variable",   "description": "&1 / &fun/arity capture" }
    ],
    "semanticTokenScopes": [
      { "language": "elixir", "scopes": {
        "atom": [
          "constant.language.symbol.elixir",
          "constant.language.symbol.single-quoted.elixir",
          "constant.language.symbol.double-quoted.elixir"
        ],
        "attribute": ["variable.other.constant.elixir"],
        "sigil": [
          "punctuation.definition.string.begin.elixir",
          "punctuation.section.regexp.begin.elixir"
        ],
        "capture": [
          "variable.other.anonymous.elixir",
          "entity.name.function.call.capture.elixir"
        ],
        "typespec": ["entity.name.function.typespec.elixir"],
        "function": [
          "entity.name.function.elixir",
          "entity.name.function.call.local.elixir",
          "entity.name.function.call.local.pipe.elixir"
        ],
        "method":    ["entity.name.function.call.dot.elixir"],
        "class":     ["entity.name.type.module.elixir"],
        "namespace": ["entity.name.type.module.elixir"],
        "type":      ["entity.name.function.typespec.elixir"],
        "property":  ["constant.language.symbol.elixir"],
        "number":    ["constant.numeric.elixir"]
      }}
    ]
  }
}
```

Honor the client's `general.positionEncodings` capability (see §7).

---

## 5. Token → semantic mapping

Grounded in the **real** toxic2 token kinds and CST node kinds (verified by probing the lexer).

### 5a. Lexical defaults — no CST needed (the cheap, high-value wins)

| toxic2 token kind | semantic | note |
|---|---|---|
| `:atom`, quoted atom, operator atom | `atom` (+`readonly`) | the `:atom` vs `:kw_identifier` split regex botches |
| `:kw_identifier` (`foo:`, span `1:1–1:5`, value `"foo"`) | `property` | **length = byte length of the value, not the span** — excludes trailing `:` |
| `:int` `:flt` `:char` | `number` | a char *is* numeric (fallback `constant.numeric`) |
| `:literal` (`true`/`false`/`nil`) | *optional* `keyword`+`readonly`+`defaultLibrary` | closed set — TextMate already gets it; emit only if you want keyword styling. Not in v1 legend by default. |
| `:sigil_start` (value = name, e.g. `"r"`) | `sigil` | **head only**; content stays TextMate |
| `:sigil_end` (value = modifiers, e.g. `"i"`) | *skip or* `sigil` | modifiers ride here |
| `:capture_int` (`&1`) | `capture` (+`readonly`) | |
| `:alias` segment | `class`; non-final segment of a `.`-chain → `namespace` | aliases are per-segment tokens (`:alias "Foo"`, `:dot`, `:alias "Bar"`) — nearly lexical |
| plain `:identifier` (no role) | `variable` — **gated**, see §6 | the one structural case we override; gate it |

### 5b. CST role refinements — single pre-order walk → sparse `token_index → {type, mods}` map

CST role **wins over** the lexical default.

| CST shape (real node kinds) | token affected | semantic |
|---|---|---|
| `{:node, :call, _, [callee \| _]}` / `{:node, :np_call, _, [callee \| _]}`, callee `:identifier` **not in a stop-list (§5c)** | callee | `function` |
| `{:node, :remote_call, _, [base, name \| _]}` | `name` | `method` if remote_call is a callee / has parens-or-np-args; else by base shape (§5d) |
| same | `base` if `:alias` → `class`/`namespace`; if `:identifier` → `variable` |
| call/np_call, callee ∈ **def-family** | target name leaf | `function`/`macro` + `definition` (see §5c) |
| call/np_call, callee ∈ **module-def directives** | target alias | `class` + `definition` |
| `{:node, :unary_op}` with `:at_op` child | following identifier | `attribute` (+`documentation`/`deprecated`/typespec handling, §5e) |
| `:sigil` node / `:op_ref` capture (`&foo/1`) | name token | `capture` (or `function`) |

### 5c. The call-rule stop-list (load-bearing)

`if`, `case`, `unless`, `for`, `with`, `try`, `receive`, `cond`, `quote`, **and `def`** all lex as
`:identifier` (they are macros/special forms, **not reserved words**) and sit in callee position.
A naive "callee → `function`" rule would repaint `if`/`case`/`def` as `function`, overriding
TextMate's `keyword.control` — a visible regression. So the call rule **must** branch on a closed
name-set:

```
callee value ∈ def-family            -> emit nothing for callee;
  {def defp defmacro defmacrop          target leaf -> function|macro + definition
   defguard defguardp}                  (spans :call AND :np_call — `def foo, do:` is no-parens;
                                         skip if target is not a plain identifier leaf, e.g. `def unquote(x)(...)`)

callee value ∈ module directives     -> def*module/protocol/impl: target alias -> class + definition
  {defmodule defprotocol defimpl        alias/import/require/use: directive emits nothing
   alias import require use}            (TextMate `keyword.other.special-method` wins);
                                         module-arg aliases follow the normal alias rule

callee value ∈ control/special forms -> emit NOTHING for callee
  {if unless case cond for with try      (TextMate `keyword.control` is correct and richer)
   receive quote unquote unquote_splicing}

otherwise                            -> function (genuine local call)
```

These sets are closed and version-stable — the honest slice of "defaultLibrary knowledge" that
needs no symbol table.

### 5d. `remote_call` is UX-driven

Elixir's `a.b` is not field access the way many languages have it, but for highlighting:

- `foo.bar()` / `foo.bar arg` → `bar` = `method`
- bare `foo.bar` (no call shape) → `bar` = `property`
- 0-arity ambiguity resolved by base shape: base is an **alias** (`Foo.bar`) → lean `method`
  (capitalized base ⇒ almost always a remote call); base is a **lowercase identifier/variable**
  (`conn.assigns`) → lean `property`. Call-shape (parens / np-args) overrides both to `method`.
- `Foo` in `Foo.bar` follows the alias rule: `class` (final) / `namespace` (prefix segment).

### 5e. Module attributes & typespecs

The attribute name after `@` is recoverable lexically (`:at_op` then `:identifier`):

| attribute | name token | modifiers / extras |
|---|---|---|
| `@moduledoc` `@doc` `@typedoc` | `attribute` | + `documentation` |
| `@deprecated` | `attribute` | + `deprecated` |
| `@spec` `@callback` `@macrocallback` | `attribute`; the **spec'd function name** → `typespec` + `declaration` | |
| `@type` `@typep` `@opaque` | `attribute`; the **type name** → `type` + `declaration` | standard `type`, distinct from `typespec` |
| other `@foo` | `attribute` (+`readonly`) | value follows normal rules |

---

## 6. The `variable` gate

Emitting `variable` for plain identifiers is the headline call-vs-variable win, but unconditionally
emitting it regresses mid-edit code (every incomplete call gets recolored as a variable, and that
fires constantly while typing). toxic2 already carries the tool to resolve this: the CST's
**inherited `@flag_has_error` bit (O(1) per subtree)**.

**Rule:** emit `variable` for an unclassified `:identifier` **only when its enclosing statement is
parsed clean** (no `has_error` in the subtree). In error-recovery / mid-edit regions, suppress and
let TextMate show through.

This captures the win in settled code while avoiding the editing-time regression exactly where it
bites. If minimizing v1 surface is preferred, `variable` may be **deferred entirely** (drop it from
the legend) — but the gate is cheap (one flag read) and reclaims the headline win, so it is the
recommended path.

---

## 7. Provider implementation

```elixir
defmodule Toxic2.SemanticTokens do
  @legend %{
    token_types: ~w(namespace type class function method macro property number variable
                    atom attribute typespec sigil capture),
    token_modifiers: ~w(definition declaration readonly documentation deprecated defaultLibrary)
  }

  def legend, do: @legend

  # → {:ok, [non_neg_integer], [Toxic2.Diagnostic.t]} : the flat LSP 5-int stream
  def encode(source, opts \\ []) do
    {view, _warnings} = Toxic2.Tokens.from_source(source, opts)   # no :comment, no :range needed
    {cst, _diags}     = Toxic2.Parser.parse_tokens(view)
    roles = role_overrides(cst, view)     # %{token_index => {type, mod_bitset}} — one CST walk
    view
    |> classify(roles)                    # token_index -> {type, mods} | :skip  (role ⊕ lexical default)
    |> emit_spans(source)                 # → [{line, start_utf16, len_utf16, type_idx, mod_bits}]
    |> delta_encode()                     # LSP relative encoding
  end
end
```

Pipeline:

1. **Lex + parse.** Deliberately do *not* request comments or source ranges — spans come straight
   off the token tuples `{kind, sl, sc, el, ec, value}`.
2. **Role walk.** One CST pre-order traversal producing a sparse `token_index → {type, mods}`
   override map (calls, remote members, def/defmodule targets, `@`-attributes, captures, alias
   segments). O(nodes). Apply the stop-list (§5c) here.
3. **Classify.** Iterate tokens in source order; for each, role-override-else-lexical-default,
   apply the `variable` gate (§6), drop `:skip` (operators, delimiters, keywords, string interiors,
   comments).
4. **Encode.** Convert to the LSP 5-int relative encoding `[Δline, Δstart, length, typeIdx, modBits]`.

### Position encoding — the one real gotcha

toxic2 columns are **1-based codepoint columns**; LSP defaults to **UTF-16**.

- ASCII line: `startChar = col - 1`, `length = byte_len(value)`.
- Line with any multibyte/astral char: build a per-line codepoint→UTF-16-offset table **once**.
  Reuse the lexer's existing `nonascii_byte?` high-byte gate to skip the table for pure-ASCII lines
  (the overwhelming majority).
- Honor `general.positionEncodings`: if the client advertises `utf-8`, skip conversion.
- `:kw_identifier` length comes from the **value** (`"foo"` → 3), not the span width (4, which
  includes the `:`).

### Requests to wire

- `textDocument/semanticTokens/full` — the pipeline above.
- `textDocument/semanticTokens/range` — re-lex the whole file (sub-ms) then filter spans to range.
- `textDocument/semanticTokens/full/delta` — cache the last token array, diff. Both cheap given
  toxic2's speed.

---

## 8. TextMate grammar changes — additive only

The grammar must stay a good standalone (semantic highlighting can be off; GitHub/markdown use it
raw). **No restructuring.** Two targeted additive changes:

1. **Guarantee a fallback scope exists for every type in `semanticTokenScopes`.** Audit the grammar
   for the cases semantic tokens map to (keyword keys `foo:`, captures `&1`, remote members) and
   ensure each has a dedicated scope so the semantic fallback aligns with what the grammar paints.
   Per the current `elixir.json` most already exist.
2. **Keep the grammar's call-vs-variable guesses conservative.** That guess only matters when
   semantic highlighting is off; the overlay corrects it when on. Do **not** add new aggressive
   `entity.name.function` heuristics "to help" — they create false positives in the semantic-off
   fallback that the overlay can't fix there.

Do **not** round-trip TextMate scopes back into the LSP. toxic2's tokens + CST are a better source
of truth; keep the two systems independent, joined only by the `semanticTokenScopes` fallback.

---

## 9. v1 scope summary

**Emit** semantic tokens for:

- module aliases — `namespace` (prefix segments) / `class` (final segment)
- `defmodule`/`defprotocol`/`defimpl` target → `class` + `definition`
- `def`/`defp` target → `function` + `definition`; `defmacro`/`defmacrop` → `macro` + `definition`;
  `defguard`/`defguardp` → `function`/`macro` + `definition`
- local call callee → `function` (minus the stop-list)
- remote call member → `method` / `property` (§5d)
- keyword keys → `property`
- atoms → `atom` (+`readonly`)
- module attributes → `attribute` (+`documentation`/`deprecated` for known names); spec/type
  targets → `typespec`/`type` + `declaration`
- captures → `capture` (+`readonly`)
- sigil head only → `sigil`
- numbers/chars → `number`
- plain identifiers → `variable`, **gated on a clean subtree** (§6)

**Do not emit** for: operators, control/block keywords, comments, punctuation/delimiters, string &
sigil interiors, interpolation delimiters, escapes, regex internals.

**Deferred to later (symbol-aware) phases:** `parameter`, body-level variable roles, `modification`,
`__MODULE__`-family special forms, `quote`/`unquote` hygiene.

---

## 10. Test plan

- **Parity slice:** a handful of `Toxic2.Conformance.Corpus` snippets with hand-asserted semantic
  spans (`{sl, sc, el, ec, type, mods}` before encoding) — covering atoms, kw-keys, call-vs-variable,
  the stop-list (`if`/`case`/`def` must NOT be `function`), aliases (namespace vs class), attributes,
  typespec vs type, captures, sigil heads.
- **Encoding:** UTF-16 conversion on a line with a multibyte char; `:kw_identifier` length excludes
  the colon; delta encoding round-trips.
- **Totality:** the provider never raises on malformed/incomplete input (inherits toxic2's P5);
  the `variable` gate suppresses inside `has_error` subtrees.
- **No multiline / no overlap:** assert every emitted span is single-line and spans are strictly
  ordered & non-overlapping.
