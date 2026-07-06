# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Parser: a kw-only no-parens call as a keyword value in a parens call / list / tuple / bitstring /
  access / map now absorbs the rest of the trailing keyword run into the inner call, matching the
  oracle (`quote(do: defstruct a: 1, b: 2)` no longer false-errors with `:no_parens_kw_not_last`).
- Parser: bare map/struct entries (incl. update entries) rooted at a binary operator, a no-parens
  call, a capture, or a do-block call now emit the new `:invalid_map_entry` error, matching the
  oracle's `map_base_expr` rule (`%User{name = "x"}`, `%{state | count + 1}` were silently
  accepted); grammar-valid shorthands (`%{name}`, `%{user.id}`, `%{m | name}`, unary chains) stay
  clean.
- Parser: `%//x{}` (a prefix-`//` struct base) is accepted like every other unary base.
- Parser: an operator-embedded trailing no-parens call followed by a comma is now rejected with
  `:ambiguous_no_parens` in every non-first comma-separated position, matching the oracle's
  `error_no_parens_many_strict` (`assert x == y, "expected " <> inspect x, label: "x"`,
  `f(1, 2 + bar 3, 4)`, `[1, 2 + bar 3, 4]`, map values, `fn` heads with ≥2 patterns);
  first/last/rightmost positions, do-block operands, sealed parens, and do-block clause heads
  stay valid.
- Parser: the keyword-run absorption now descends operator chains to the rightmost kw-only
  no-parens call (`f(a: 2 + g x: 1, b: 2)` => `g(x: 1, b: 2)`, previously a silently different
  AST) and also applies to bare container elements (`[render x: 1, y: 2]` was a false error),
  assoc values (`%{k => g x: 1, y: 2}`), and access indices (`m[foo x: 1, y: 2]` was a false
  error).

## [0.1.0] - 2026-06-21

Initial release: a complete tolerant-only Elixir lexer → green CST parser → AST lowerer.

### Core

- Exact AST parity for valid code (validated against `Code.string_to_quoted/2`), across the full
  Elixir distribution and a multi-package corpus.
- Total / never-raising lexer, parser, and lowerer (fuzzed against truncations, deletions, random
  bytes, and invalid UTF-8).
- Source ranges (`range: true`) with a parent-contains-children invariant; Elixir-compatible
  `literal_encoder` and `token_metadata`.
- Atom safety via `existing_atoms_only`.
- `Toxic2.SemanticTokens` — an LSP-style semantic-token view over the CST.
- Comment collection: `Toxic2.string_to_quoted_with_comments/2`.
- Zero runtime dependencies.

### Fixed

- Lexer: identifiers that NFC-normalize to unsupported codepoints are now rejected.
- Lexer: the `:eol`/EOF token after a comment containing multi-byte UTF-8 now gets a codepoint
  (not byte) start column.
- Lexer: confusable-identifier warnings are merged back into source order with in-line warnings.
- `Toxic2.SourceRanges.outer_range/1` returns `nil` for empty (token-less) input, matching its
  documented contract.

### Packaging

- Hex package metadata, `LICENSE` (Apache-2.0), and documentation (`ex_doc`).

[0.1.0]: https://github.com/lukaszsamson/toxic2/releases/tag/v0.1.0
