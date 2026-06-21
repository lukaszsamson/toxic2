# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Hex package metadata, `LICENSE` (Apache-2.0), and documentation (`ex_doc`).
- `Toxic2.SemanticTokens` — an LSP-style semantic-token view over the CST.
- Comment collection: `Toxic2.string_to_quoted_with_comments/2`.

### Fixed

- Lexer: identifiers that NFC-normalize to unsupported codepoints are now rejected.
- Lexer: the `:eol`/EOF token after a comment containing multi-byte UTF-8 now gets a codepoint
  (not byte) start column.
- Lexer: confusable-identifier warnings are merged back into source order with in-line warnings.
- `Toxic2.SourceRanges.outer_range/1` now returns `nil` for empty (token-less) input, matching its
  documented contract.

## [0.1.0]

Initial release: a complete tolerant-only Elixir lexer → green CST parser → AST lowerer.

- Exact AST parity for valid code (validated against `Code.string_to_quoted/2`).
- Total / never-raising lexer, parser, and lowerer.
- Source ranges (`range: true`) with a parent-contains-children invariant; Elixir-compatible
  `literal_encoder` and `token_metadata`.
- Atom safety via `existing_atoms_only`.
- Zero runtime dependencies.

[Unreleased]: https://github.com/lukaszsamson/toxic2/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/lukaszsamson/toxic2/releases/tag/v0.1.0
