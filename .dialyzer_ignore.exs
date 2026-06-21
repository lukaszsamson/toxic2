# Deliberate, measured optimization: the parser-local token-view readers (tk/tv/tt/t_eof?)
# pattern-match the `Toxic2.Tokens.t()` view tuple `{toks, size, _cont}` directly instead of
# calling the cross-module `Tokens.kind/value/token/at_eof?` accessors. `Tokens.kind/2` alone was
# ~12% of ALL calls; inlining these reads is why the parser meets its perf target. This breaks the
# opacity of `Tokens.t()` by design — see the comment block above `tk/2` in lib/toxic2/parser.ex.
[
  {"lib/toxic2/parser.ex", :opaque_match}
]
