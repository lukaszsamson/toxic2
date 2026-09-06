# Performance audit, second pass — 2026-09-06

Companion to `PERF_AUDIT_20260906.md` (same revision, `c924fcf`). That pass found the quadratic
paths; this pass looked at the **constant factors on the hot token path**, using `bin_opt_info`,
`beam_disasm` of the prod build, `tprof` call_time/call_memory, and renamed-module A/B prototypes
(shuffled order, fresh process per pass, 15 rounds, output equality checked on the 105 stdlib
files + all `test/**/*.exs` + 2000 deterministic random token-soup strings). Production source is
untouched; the prototype diff is at the end.

## Headline

| arm | lex median | full median | full vs oracle | lex alloc (words) |
|---|---:|---:|---:|---:|
| shipped `c924fcf` | 124–135 ms | 270 ms | 1.49× | 25.2 M |
| prototype (findings 1–3) | 97–108 ms | 230 ms | **1.27×** | **19.0 M** |

Lex −21 %, full pipeline −15 %, lexer allocation −25 %, zero output differences (tokens, warnings
and the comments API). Absolute numbers drift with thermal state between runs; every delta above
is from an interleaved run.

## 1. The identifier path re-creates a binary match context five times per token (biggest win)

Per lowercase identifier the shipped code does: `word_len` → returns `{n, rest}` (tuple + sub-binary),
`read_name` re-matches `rest` for `?`/`!` (`bs_start_match4`, ~5 words) and slices the name,
`lex/6` matches `after_name` again for `<<cp::utf8>>`, `kw_suffix` matches it again, then
`lex_lower_no_kw`'s first clause matches it again for `@` (`bs_start_match4 no_fail` in the
disassembly), then `bang_before_eq_notice` sets up a 5-slot stack frame and calls `binary:last`
+ `binary:first`, then `lower_token` matches `name` for the keyword trie. Every one of those
`bs_start_match` on a sub-binary allocates a fresh match state; `bin_opt_info` reports all of
these call sites as NOT OPTIMIZED because the callee does not start with a match on that argument.
tprof: `read_name` 17.2 w/call, `lex_lower_no_kw` 12 w/call, `lower_token` 14.7 w/call,
`binary:last` 178 290 calls — ~55 words and 6 calls for a token that needs ~13 words.

Fix (in the diff): keep the byte count from `word_len`, decide `?`/`!` and the following `=` in
one match, then one `case` over the boundary bytes that handles unicode / `::` / kw / kw-nospace /
`@` / plain, and only slice the name at the leaf. `bang_before_eq_notice` disappears from this
path. Result: lex −22 %, `read_name`/`lex_lower_no_kw`/`binary:last` gone from the profile,
`lex/6` itself drops from 9.8 to 6.8 w/call.

Two variants that **lost** and should not be tried again: a single 13-clause `case` doing the
`?`/`!` prefix and boundary in one match (+5.7 % vs the two-stage version — the bigger dispatch
costs more than the saved match state), and replacing the keyword clause trie in `lower_token`
with a compile-time map lookup (+10.8 % — hashing the binary is slower than the trie even though
the trie allocates a match state).

The upper-case alias clause (`word_len` → `binary_part` → utf8 match → `kw_suffix` →
`lex_upper_no_kw` match) has the same shape; only 7 046 aliases in the corpus so it was not
prototyped, but the same rewrite applies.

## 2. Every operator token pays two extra match states for two rare checks (−3.8 % lex)

`emit_operator_or_kw_free` calls `atom_op_kw_len(bin)` (only ever true for `<<>>:` / `..//:`) and
`too_many_same_char_notice(bin, …)` (only for 3-char repeated operators) on every operator. Both
compile to `bs_start_match3` on `bin`, i.e. a fresh match state each, 38 099 times. Guarding them
with the already-known `len`/`kind` (integer compares) measured −3.8 % lex on its own. The
remaining 19 w/call in that function are the `kw_colon_at?` match state, the `rest_at`
sub-binary, the token and the cons.

## 3. Heredoc line start scans the indentation three times (−2 % lex)

`heredoc_line_start` → `heredoc_terminator?` (`take_hspace` tuple + sub-binary, then
`heredoc_delim3?` match state) → `drop_indent` (another tuple + sub-binary) for each of the
42 297 body lines. A count-only `hspace_len`, one `<<_::binary-size(ws), d, d, d, _>>` check and
one `rest_at(rest, min(ws, strip))` does the same work in one scan. Measured −2.2 % lex.

Further, not prototyped: the indentation pre-scan (`heredoc_indent` / `skip_to_eol`) is a second
full pass over every heredoc body that allocates `{rest}` + a sub-binary per line
(`skip_to_eol` 12.5 w/call, 924 k words, plus 90 k `:binary.match` calls). Walking byte offsets
with `:binary.match(bin, pat, scope: {off, len})` would make the pre-scan allocation-free.

## 4. Confusable-lint gate does a whole-token pass with a `persistent_term` read per identifier

For any file with a non-ASCII byte anywhere (21 of 105 here, e.g. in a docstring),
`any_unicode_name?` runs `Enum.any?` over all tokens and calls `nonascii_byte?` →
`high_byte_pattern()` → `:persistent_term.get` per identifier-shaped token: 166 k fun calls,
57 868 pattern fetches. The lexer already knows when it emitted a unicode name (every such token
goes through `lex_unicode`); carrying that as a flag in the notice channel (or a `w` marker)
removes the pass entirely. Small (est. ≤1 % lex) but free.

## 5. Parser: no-op check helpers allocate a fresh `{diags, nid}` pair per element

`check_kw_last`, `check_kw_value_when`, `check_call_arg_strict`, `check_container_elem_strict`,
`check_eol_comma`, `check_np_comma` each return a new 2-tuple even when nothing was emitted:
100–114 k calls each, 3 w/call, ≈1.6 M words ≈ 3 % of full-pipeline allocation. Threading the
pair as one value (or returning `:ok` on the no-op path) makes them allocation-free. Related:
`tspan`/`cst_span` build a 4-tuple only to compare positions (`np_arg_start?`, `paren_call?` via
`cst_ends_at_token?`): 230 k calls, 766 k words; comparing the token fields directly avoids it.
`absorb_kw_run` → `append_trailing_kw` does `Enum.concat(children, [pair])` and rebuilds the
operator chain per absorbed pair, quadratic in keyword-run length (small n in practice).

## 6. Lowerer: call-argument lowering makes 4–7 passes over each arg list

`lower_call_args` → `pop_do_block` (`:lists.last` + `drop_last`) → `lower_args` (`:lists.last`,
then reverse + `split_while` + reverse + reverse for the kw case) → `Enum.concat(args, [kw])`.
That is where the 110 738 `lists:last/1` calls in the profile come from (2 per call node). A
single reverse-accumulating pass that detects the trailing kw pairs / do-block on the reversed
list replaces all of it. Not prototyped; arg lists are short so expect a few percent of lower.

Tried and **rejected**: `to_atom` via direct `:erlang.binary_to_atom(bin, :utf8)` with a
`byte_size <= 255` guard instead of `String.to_atom` + `rescue` — +1.2 %, i.e. noise. The
`try` frame and the `binary_to_atom/1` → `/2` hop are not measurable.

## 7. Things that look expensive in the profile but are already right

`lex/6` dispatches on the first byte through `select_val`; `plain_run_len`/`word_len`/
`take_hspace` are `bs_start_match4 :resume` + `call_only` loops with no per-byte allocation;
`Precedence.infix/prefix` return literals. The 1.2 M words in `lists:reverse/2` and 655 k in
`list_to_tuple` are the one token-list reverse and the view tuple, inherent to the list→tuple
hand-off (7.5 % of lex allocation) unless the lexer builds the view itself.

## Order of work

1. Land finding 1 + 2 + 3 (the diff below, plus the alias clause). Run the 1 102 tests and both
   grammar harnesses; the A/B equality here is not a substitute.
2. Finding 5 (parser pair threading) and 6 (single-pass arg lowering) — allocation, measure each.
3. Finding 4 and the heredoc pre-scan on offsets.
4. The quadratic paths from the first audit remain valid and independent of the above.

## Prototype diff (`lib/toxic2/lexer.ex`, findings 1–3; `read_name/1` and the
`lex_lower_no_kw` plain clause become dead and should be deleted)

```diff
--- a/lib/toxic2/lexer.ex
+++ b/lib/toxic2/lexer.ex
@@ -692,25 +692,8 @@
   # If the ascii run flows into a `>127` byte the word is unicode — hand the WHOLE word to the
   # vendored tokenizer (NFC + UTS-39 script checks), so e.g. `café`/`módulo` stay single tokens.
   defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_lower_start(c) do
-    {len, name, after_name} = read_name(bin)
-
-    case after_name do
-      <<cp::utf8, _::binary>> when cp > 127 ->
-        lex_unicode(bin, line, col, acc, w, st)
-
-      _ ->
-        case kw_suffix(after_name) do
-          {:kw, rest} ->
-            cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)
-
-          {:kw_nospace, rest} ->
-            acc = kw_nospace_error(name, line, col, len, acc)
-            cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)
-
-          :no ->
-            lex_lower_no_kw(bin, name, after_name, len, line, col, acc, w, st)
-        end
-    end
+    {wlen, rest} = word_len(bin, 0)
+    lex_lower_after_word(bin, rest, wlen, line, col, acc, w, st)
   end
 
   # --- aliases (Uppercase): kw key or alias ------------------------------
@@ -749,8 +732,48 @@
       {kind, value, len} -> emit_operator_or_kw(bin, kind, value, len, line, col, acc, w, st)
       nil -> lex_op_error(bin, line, col, acc, w, st)
     end
+  end
+
+  # `foo!=1` / `bar?=1`: the ambiguous-bang warning, decided from the two boundary bytes.
+  defp lex_lower_after_word(bin, <<p, ?=, _::binary>> = rest, wlen, line, col, acc, w, st)
+       when p in [??, ?!] do
+    len = wlen + 1
+    w = [{:lexer, :warning, :ambiguous_bang_before_equals, {line, col, line, col + len}, %{}} | w]
+    cont(rest_at(rest, 1), lower_token(binary_part(bin, 0, len), line, col, len), acc, w, st)
   end
 
+  defp lex_lower_after_word(bin, <<p, after_p::binary>>, wlen, line, col, acc, w, st)
+       when p in [??, ?!],
+       do: lex_lower_boundary(bin, after_p, wlen + 1, line, col, acc, w, st)
+
+  defp lex_lower_after_word(bin, rest, wlen, line, col, acc, w, st),
+    do: lex_lower_boundary(bin, rest, wlen, line, col, acc, w, st)
+
+  # ONE binary match over the boundary decides unicode / kw / kw_nospace / `@` / plain.
+  defp lex_lower_boundary(bin, after_name, len, line, col, acc, w, st) do
+    case after_name do
+      <<cp::utf8, _::binary>> when cp > 127 ->
+        lex_unicode(bin, line, col, acc, w, st)
+
+      <<?:, ?:, _::binary>> ->
+        cont(after_name, lower_token(binary_part(bin, 0, len), line, col, len), acc, w, st)
+
+      <<?:, c, _::binary>> when c in [?\s, ?\t, ?\r, ?\n] ->
+        cont(rest_at(after_name, 1), {:kw_identifier, line, col, line, col + len + 1, binary_part(bin, 0, len)}, acc, w, st)
+
+      <<?:, _::binary>> ->
+        name = binary_part(bin, 0, len)
+        acc = kw_nospace_error(name, line, col, len, acc)
+        cont(rest_at(after_name, 1), {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)
+
+      <<?@, _::binary>> ->
+        lex_lower_at(bin, binary_part(bin, 0, len), after_name, len, line, col, acc, w, st)
+
+      _ ->
+        cont(after_name, lower_token(binary_part(bin, 0, len), line, col, len), acc, w, st)
+    end
+  end
+
   defp emit_operator_or_kw(bin, kind, value, len, line, col, acc, w, st) do
     case dot_member_split(kind, acc) do
       # DOT CONTEXT (F2): right after a `.`, only operators legal as remote member names are one
@@ -782,11 +805,12 @@
     # op-ref rule (`op` + `/arity`) sees it whole. The `..` table match (len 2) would
     # otherwise win.
     fused = kind == :range_op and fused_ternary_ref(bin, line, col + 4)
+    sp = if len == 2 and (kind == :range_op or kind == :"<<"), do: atom_op_kw_len(bin), else: nil
 
     cond do
       # `<<>>:` / `..//:` — atom-shaped operator keys whose full length the table's longest match
       # (`<<` / `..`) would shadow; `%{}`/`{}`/`%`/`::` are handled by earlier `lex/6` clauses.
-      sp = atom_op_kw_len(bin) ->
+      sp != nil ->
         emit_op_kw(bin, sp, line, col, acc, w, st)
 
       match?({:fused, _, _, _}, fused) ->
@@ -807,7 +831,7 @@
 
       true ->
         w = deprecated_op_notice(value, len, line, col, w)
-        w = too_many_same_char_notice(bin, line, col, w)
+        w = if len == 3, do: too_many_same_char_notice(bin, line, col, w), else: w
         cont(rest_at(bin, len), {kind, line, col, line, col + len, value}, acc, w, st)
     end
   end
@@ -1135,7 +1159,7 @@
   # name is the key, R5); otherwise `word@` is an invalid identifier (R15; a `!`/`?` suffix is a
   # real token boundary — `foo!@x` is a call with an `@x` arg). The extended re-scan runs only on
   # this rare `@` path, keeping the per-identifier fast path single-scan.
-  defp lex_lower_no_kw(bin, name, <<?@, _::binary>> = after_name, len, line, col, acc, w, st) do
+  defp lex_lower_at(bin, name, after_name, len, line, col, acc, w, st) do
     case kw_name(bin) do
       {:kw, klen, kname, rest, nospace?} ->
         acc = if nospace?, do: kw_nospace_error(kname, line, col, klen, acc), else: acc
@@ -1147,10 +1171,6 @@
     end
   end
 
-  defp lex_lower_no_kw(_bin, name, after_name, len, line, col, acc, w, st) do
-    w = bang_before_eq_notice(name, after_name, line, col, len, w)
-    cont(after_name, lower_token(name, line, col, len), acc, w, st)
-  end
 
   # `Foo!:` / `Foo?:` / `Foo@bar:` — the alias scanner stops before `!`/`?`/`@`, so only those
   # boundaries can still form an atom-shaped keyword key (R5); everything else is a plain alias.
@@ -1929,10 +1949,13 @@
   # At the start of a body line: the terminator ends the heredoc, otherwise strip the (shared)
   # indentation and keep scanning. Shared by the opener (first line) and the `\n` clause.
   defp heredoc_line_start(rest, line, buf, fs, acc, w, st, {d, _m, _i, strip, _ek, warned?} = hc) do
-    if heredoc_terminator?(rest, d) do
+    ws = hspace_len(rest, 0)
+
+    if delim3_at?(rest, ws, d) do
       heredoc_close(rest, line, buf, fs, acc, w, st, hc)
     else
-      {dropped, rest2} = drop_indent(rest, strip)
+      dropped = min(ws, strip)
+      rest2 = rest_at(rest, dropped)
       w2 = outdented_notice(dropped, strip, rest2, line, warned?, w)
       # Upstream warns ONCE per heredoc, at the first outdented line (K15) — latch the flag.
       hc = if w2 != w, do: put_elem(hc, 5, true), else: hc
@@ -1979,6 +2002,16 @@
     heredoc_delim3?(after_ws, d)
   end
 
+  defp hspace_len(<<c, rest::binary>>, n) when c in [?\s, ?\t], do: hspace_len(rest, n + 1)
+  defp hspace_len(_bin, n), do: n
+
+  defp delim3_at?(bin, off, d) do
+    case bin do
+      <<_::binary-size(off), ^d, ^d, ^d, _::binary>> -> true
+      _ -> false
+    end
+  end
+
   defp heredoc_delim3?(<<d, d, d, _::binary>>, d), do: true
   defp heredoc_delim3?(<<d, d, d>>, d), do: true
   defp heredoc_delim3?(_bin, _d), do: false
```

Harness scripts (`ab.exs`, `ab_full.exs`, `ab_lower.exs`, `profile.exs`) and the renamed
prototype modules are in this session's scratchpad
(`/private/tmp/claude-501/-Users-lukaszsamson-claude-fun-toxic2/0695838d-e6d1-492a-90ac-bbec7708801d/scratchpad`).
