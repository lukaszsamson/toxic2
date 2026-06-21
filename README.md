# Toxic2

A **tolerant-only** Elixir lexer, parser, and AST lowerer.

Toxic2 tokenizes and parses Elixir source into a nested *green CST*, then lowers that CST to the
standard Elixir AST. It is built for editor- and tooling-grade use: it **never raises** on any
input (valid, invalid, truncated, or arbitrary bytes), produces a best-effort AST plus a
source-ordered diagnostic stream for broken code, and can attach precise source ranges and
Elixir-compatible token metadata.

- **Exact AST parity** for valid code (compared against `Code.string_to_quoted/2` after metadata
  normalization), validated against the full Elixir distribution and a multi-package corpus.
- **Total / never-raising** lexer, parser, and lowerer (verified by fuzzing truncations, deletions,
  random bytes, and invalid UTF-8).
- **Green CST** with a parent-contains-children range invariant — the basis for selection ranges,
  formatting, and refactoring tools.
- **Atom-safe**: `existing_atoms_only` gates every source-derived name.
- **Zero runtime dependencies.**

> Design rationale and the non-negotiable architecture principles live in
> [`TOXIC_2.md`](TOXIC_2.md).

## Installation

Add `toxic2` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:toxic2, "~> 0.1.0"}
  ]
end
```

## Usage

### Source → AST

```elixir
Toxic2.parse_to_ast("a + b * 2")
#=> {{:+, [line: 1, column: 3],
#=>   [{:a, [line: 1, column: 1], nil},
#=>    {:*, [line: 1, column: 7], [{:b, [line: 1, column: 5], nil}, 2]}]}, []}
```

`parse_to_ast/2` returns `{ast, diagnostics}`. For valid code in the supported grammar the `ast`
matches Elixir's own and `diagnostics` is empty. The pipeline is tolerant, so invalid code still
returns a best-effort AST (with `{:__error__, ...}` nodes where needed) alongside a source-ordered
list of `Toxic2.Diagnostic` entries — it does not raise.

### Options

`parse_to_ast/2` (and `string_to_quoted_with_comments/2`) accept:

| Option | Default | Effect |
|---|---|---|
| `:existing_atoms_only` | `false` | Atomize source names with `String.to_existing_atom/1`; missing atoms become `{:__error__, ...}` with a diagnostic (safe for untrusted input). |
| `:range` | `false` | Attach `range: {{start_line, start_col}, {end_line, end_col}}` (end-exclusive) to every AST node that maps to source. A parent's range always contains its children's. |
| `:literal_encoder` | — | `fn value, meta -> {:ok, ast} \| {:error, reason} end`, called for each literal so bare literals can carry position info. Elixir-compatible. |
| `:token_metadata` | `false` | Attach Elixir's `token_metadata: true` keys (`closing:`, `do:`/`end:`, `delimiter:`, `token:`, `newlines:`, `end_of_expression:`, …). |

```elixir
Toxic2.parse_to_ast("if x do y end", token_metadata: true, range: true)
```

### Comments

```elixir
Toxic2.string_to_quoted_with_comments("x = 1 # set x\n")
#=> {ast, diagnostics,
#=>  [%{line: 1, column: 7, text: "# set x", previous_eol_count: 0, next_eol_count: 1}]}
```

### Tokens and CST

```elixir
{tokens, notices}  = Toxic2.tokenize("foo(:bar)")   # batch lexer; notices are out-of-band warnings
{cst, diagnostics} = Toxic2.parse("foo(:bar)")        # green CST + combined diagnostic stream
```

### Source ranges (editor "expand selection")

```elixir
Toxic2.SourceRanges.outer_range("foo(bar)")   #=> {{1, 1}, {1, 9}}
Toxic2.SourceRanges.outer_range("")            #=> nil
```

`Toxic2.SemanticTokens` provides an LSP-style semantic-token view over the same CST.

## Status

0.1.0 — the core (lex → parse → lower) is complete and validated. The public surface is `Toxic2`,
`Toxic2.SourceRanges`, and `Toxic2.SemanticTokens`; diagnostics use the `Toxic2.Diagnostic` shape.
Following the project's design contract, Toxic2 defines its **own** diagnostics — it does not aim
for byte-identical error-message parity with `Code.string_to_quoted` on invalid code.

## License

Apache-2.0 © 2026 Lukasz Samson. See [LICENSE](LICENSE).
