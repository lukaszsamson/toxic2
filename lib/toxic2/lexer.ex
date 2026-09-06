defmodule Toxic2.Lexer do
  @moduledoc """
  Batch lexer (see `TOXIC_2.md` → Migration Phases #1–#2).

  Phase 2 rounds out the **non-string** lexicon: numbers (int/float, `0x`/`0o`/`0b`), char
  literals, atoms, keyword keys, `true`/`false`/`nil`, the full operator family set, `<<`/`>>`,
  `%`, and comments.

  Phase 10 adds **double-quoted strings with interpolation** in the linear source-ordered form:
  `:string_start`, `:string_fragment` (escapes processed), `:begin_interpolation` /
  `:end_interpolation` wrapping the interpolation's ordinary tokens, and `:string_end`. The
  interpolation-closing `}` is told apart from a brace-closing `}` by a small terminator stack
  (`st`); see the note above `lex/6`. The same linear shape covers **charlists** `'...'`
  (`read_quoted`), **sigils** `~name<delim>...<delim>mods` (`read_sigil`, raw content + optional
  interpolation, trailing modifiers on `:sigil_end`), and **heredocs** `\"""`/`'''` (`read_heredoc`,
  line-spanning with lexical indentation stripping), including sigil heredocs. Also: quoted atoms
  (`:"..."` via a `:quoted_atom` marker), quoted keyword keys (`"foo":` via a `:kw_quote` marker),
  operator-named atoms (`:<<>>`, `:%{}`, `:..//`), operator-named keyword keys (`<<>>: 1`,
  `+: 1`, `%{}: 1` — an operator/bracket name before a separator colon), `@`-bearing atom names
  (`:nonode@nohost`), and `\`-newline line continuation in code. **Unicode identifiers/atoms**
  (`café`, `:αβγ`) are lexed via the vendored `Toxic2.String.Tokenizer` (NFC + UTS-39 checks).

  Architecture invariants this locks in:

  - **Batch, source-ordered** output (P2): one call, whole input, tokens in source order.
  - **Flat token tuples** `{kind, sl, sc, el, ec, value}` (Performance rules): no nested span,
    no structs on the hot path. Plain-args recursive `lex/5`; prepend + reverse once.
  - **No deferrals / no lookbehind rewrites** (P2): identifiers stay `:identifier`; `not`/`in`
    are separate tokens (never fused `not in`); newlines are an explicit coalesced `:eol`.
  - **No source atom interning** (review #1): source-derived names (`:identifier`, `:alias`,
    `:atom`, `:kw_identifier`) carry **binary** values; atomization is a *lowering* concern with
    an explicit atom policy, so tolerant lexing / fuzzing of untrusted input can't grow the atom
    table. Only **closed-set** lexemes carry atoms: operators (`value` = the operator atom),
    `true`/`false`/`nil` (`:literal`), and block labels (`:block_label`).
  - **Codepoint-aware errors** (review #2): an unknown but valid UTF-8 codepoint is one `:error`
    token advancing one column; the byte fallback fires only for invalid UTF-8.
  - **Tolerant via sole transport** (P3): errors are `:error` tokens; `tokenize/2` returns only
    `{tokens, warnings}`.

  Operator family tags are ported from Toxic's tokenizer (the source of truth); precedence is
  pinned against `elixir_parser.yrl` in phase 5, not here.
  """

  alias Toxic2.LexError

  # Narrow inlining of tiny, hot, LOCAL helpers (cross-module calls are unaffected). Recursive
  # scanners (`lex/6`, `word_len/2`, `read_atom_name/1`, `consume_eols/4`, `plain_run_len/4`) are
  # deliberately excluded — inlining them risks code growth / worse i-cache. A/B-measured.
  @compile {:inline, rest_at: 2, kw_suffix: 1, kw_colon_at?: 2, cont: 5}

  @type token :: Toxic2.Token.t()
  # An id-less lexer warning notice; numbered into a `Diagnostic` at the parse boundary.
  @type warning ::
          {:lexer, :warning, atom(), {pos_integer(), pos_integer(), pos_integer(), pos_integer()},
           map()}

  # Longest-match operator/structural table. Operator `value` is the (closed-set) operator atom.
  # `<<`/`>>` are structural delimiters that live here so `<<<`/`>>>`/`<<~` win by length.
  # `::`, `:` (atoms), `&`/`&n`, `%`, and single delimiters are handled by dedicated clauses.
  @op_table %{
    # 3-char
    "+++" => {:concat_op, :+++},
    "---" => {:concat_op, :---},
    "..." => {:ellipsis_op, :...},
    "<<<" => {:arrow_op, :<<<},
    ">>>" => {:arrow_op, :>>>},
    "~>>" => {:arrow_op, :~>>},
    "<<~" => {:arrow_op, :<<~},
    "<~>" => {:arrow_op, :<~>},
    "<|>" => {:arrow_op, :"<|>"},
    "===" => {:comp_op, :===},
    "!==" => {:comp_op, :!==},
    "&&&" => {:and_op, :&&&},
    "|||" => {:or_op, :|||},
    "~~~" => {:unary_op, :"~~~"},
    "^^^" => {:xor_op, :"^^^"},
    # 2-char
    "++" => {:concat_op, :++},
    "--" => {:concat_op, :--},
    "<>" => {:concat_op, :<>},
    "**" => {:power_op, :**},
    "<=" => {:rel_op, :<=},
    ">=" => {:rel_op, :>=},
    "==" => {:comp_op, :==},
    "=~" => {:comp_op, :=~},
    "!=" => {:comp_op, :!=},
    "//" => {:ternary_op, :"//"},
    "&&" => {:and_op, :&&},
    "||" => {:or_op, :||},
    "->" => {:stab_op, :->},
    "<-" => {:in_match_op, :<-},
    "\\\\" => {:in_match_op, :"\\\\"},
    "|>" => {:arrow_op, :|>},
    "~>" => {:arrow_op, :~>},
    "<~" => {:arrow_op, :<~},
    ".." => {:range_op, :..},
    "=>" => {:assoc_op, :"=>"},
    "<<" => {:"<<", nil},
    ">>" => {:">>", nil},
    # 1-char
    "+" => {:dual_op, :+},
    "-" => {:dual_op, :-},
    "*" => {:mult_op, :*},
    "/" => {:mult_op, :/},
    "=" => {:match_op, :=},
    "<" => {:rel_op, :<},
    ">" => {:rel_op, :>},
    "|" => {:pipe_op, :|},
    "!" => {:unary_op, :!},
    "^" => {:unary_op, :^},
    "@" => {:at_op, :@},
    "&" => {:capture_op, :&},
    "." => {:dot, :.}
  }

  @char_escapes %{
    ?n => ?\n,
    ?t => ?\t,
    ?r => ?\r,
    ?s => ?\s,
    ?0 => 0,
    ?a => 7,
    ?b => ?\b,
    ?d => 127,
    ?e => 27,
    ?f => ?\f,
    ?v => ?\v,
    ?\\ => ?\\,
    ?" => ?",
    ?' => ?'
  }

  # Operators Elixir still parses but deprecates (warned only when emitted as an OPERATOR, never as
  # a keyword key — matching elixir_tokenizer's handle_op, where the kw_identifier clause returns
  # before the deprecation case). Value → toxic2 warning code.
  @deprecated_ops %{
    :"~~~" => :deprecated_op_bnot,
    :"^^^" => :deprecated_op_xor,
    :"<|>" => :deprecated_op_pipe
  }

  @reserved_ops %{
    "not" => {:unary_op, :not},
    "and" => {:and_op, :and},
    "or" => {:or_op, :or},
    "when" => {:when_op, :when},
    "in" => {:in_op, :in}
  }

  @terminators %{"do" => :do, "end" => :end, "fn" => :fn}
  @block_labels %{
    "else" => :else,
    "catch" => :catch,
    "rescue" => :rescue,
    "after" => :after
  }
  @value_literals %{"true" => true, "false" => false, "nil" => nil}

  defguardp is_digit(c) when c in ?0..?9
  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F
  defguardp is_lower_start(c) when c in ?a..?z or c == ?_
  defguardp is_upper_start(c) when c in ?A..?Z
  defguardp is_word(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  # Bidirectional formatting controls (Elixir's `?bidi` macro): rejected in comments and strings
  # because they can visually reorder source against its logical meaning (a security hazard).
  # A `defguardp` (not a `defp`): every call site is boolean body/guard position, so this expands
  # inline (`in` → `andalso`/comparison chain) with no function call. Never used as a capture.
  defguardp bidi?(c)
            when c in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

  # Unsupported line-break characters (Elixir's `?break` macro, 1.20): VT, FF, CR, NEL, LS, PS.
  # Rejected (an ERROR) in comments and strings/sigils/heredocs — they'd be invisible line breaks.
  # A bare CR (0x0D) is only valid as part of a CRLF, which every call site handles BEFORE this check.
  defguardp break?(c) when c in [0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029]

  # Sigil-modifier char class. `defguardp` (defined here, ahead of every use) so the membership
  # test inlines in guard/body position (the radix digit classes live in `digit_run/4`'s guards).
  defguardp mod_char?(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9

  @doc """
  Tokenize `source` into `{tokens, notices}`, both in **source order**.

  `tokens` may contain `:error` tokens (tolerant mode is the only mode — P1): lexical ERRORS travel
  in-stream as `:error` tokens so the parser can convert each to a diagnostic and recover. `notices`
  is the out-of-band WARNING channel — a list of id-less `{:lexer, :warning, code, {sl,sc,el,ec},
  details}` tuples (charlist/quote deprecations, ambiguous-pipe-adjacent lexical warnings, unusual
  char literals, …). They stay OUT of the token stream and are numbered into diagnostics at the
  parse boundary (`Diagnostics.number/2`).
  """
  @spec tokenize(binary(), keyword()) :: {[token()], [warning()]}
  def tokenize(source, _opts \\ []) when is_binary(source) do
    {tokens, warnings, _comments} = do_tokenize(source, false)
    {tokens, warnings}
  end

  @doc """
  Like `tokenize/2` but also returns the source-ordered list of comments collected by the lexer.

  Each comment is `{:comment, line, column, text, previous_eol_count, next_eol_count}` (1-based
  position of the `#`; `text` includes the leading `#`, excludes the trailing newline). Mirrors the
  data `Code.string_to_quoted_with_comments/2` collects via `:preserve_comments`.
  """
  @spec tokenize_with_comments(binary(), keyword()) :: {[token()], [warning()], [tuple()]}
  def tokenize_with_comments(source, _opts \\ []) when is_binary(source),
    do: do_tokenize(source, true)

  # `keep_comments?` is the ONLY difference between the two entry points: `tokenize/2` used to build
  # a `"#" <> body` binary, a six-field tuple and a `next_eol_count/2` scan for every comment only to
  # throw the lot away. The flag rides the BOTTOM of the terminator stack `st` rather than as a 7th
  # argument to the whole `lex/6` family — `st` is only ever matched at its HEAD (`:brace` /
  # `{:interp, _}`), so a bottom element is invisible to every push and pop, and the hot per-token
  # clauses keep their argument count (and register allocation) unchanged.
  defp do_tokenize(source, keep_comments?) do
    {rev_tokens, rev_notices} = lex(source, 1, 1, [], [], [keep_comments?])
    tokens = :lists.reverse(rev_tokens)

    # Comments and the `:unicode_name` marker ride the `w` channel alongside lexer warnings; one
    # reverse-consing walk splits all three back out AND restores source order (the channel is
    # accumulated most-recent-first), replacing the old `split_with` + two `:lists.reverse` calls.
    {comments, warnings, unicode_name?} = split_notices(rev_notices, [], [], false)

    # UTS-39 confusable-identifier lint: a whole-file pass, run only when a non-ASCII IDENTIFIER was
    # emitted (matching Elixir's `ascii_identifiers_only` gate — keeps the ASCII-only hot path free).
    # The lexer sets `unicode_name?` at the emit site (see `uni_w/2`), so no whole-token rescan is
    # needed here. Confusable lint is a SEPARATE whole-file pass, so its warnings have to be merged
    # back into source order with the in-line lexer warnings (each list is already source-ordered) —
    # otherwise a confusable on an earlier line would sort after a later-line in-line warning.
    # `sort_by/2` is stable, so warnings sharing a start position keep their relative order.
    warnings =
      if unicode_name?,
        do:
          Enum.sort_by(
            Enum.concat(warnings, confusable_lint(tokens)),
            fn {_p, _s, _c, sp, _d} -> sp end
          ),
        else: warnings

    {tokens, warnings, comments}
  end

  defp split_notices([], comments, warnings, uni?), do: {comments, warnings, uni?}

  defp split_notices([{:comment, _, _, _, _, _} = c | t], comments, warnings, uni?),
    do: split_notices(t, [c | comments], warnings, uni?)

  defp split_notices([:unicode_name | t], comments, warnings, _uni?),
    do: split_notices(t, comments, warnings, true)

  defp split_notices([n | t], comments, warnings, uni?),
    do: split_notices(t, comments, [n | warnings], uni?)

  # `:binary.match/2` against a compiled Boyer–Moore pattern of every high byte (0x80–0xFF) is a
  # C-implemented scan (~17× faster than an Elixir byte recursion), making the pure-ASCII fast
  # reject for the confusable lint effectively free. The pattern is a reference (not a literal), so
  # it's compiled once and cached in `:persistent_term` (O(1) reads; a single one-time `put`).
  defp nonascii_byte?(source), do: :binary.match(source, high_byte_pattern()) != :nomatch

  defp high_byte_pattern do
    key = {__MODULE__, :high_byte_pattern}

    case :persistent_term.get(key, nil) do
      nil ->
        pattern = :binary.compile_pattern(Enum.map(128..255, &<<&1>>))
        :persistent_term.put(key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  # Significant bytes for the heredoc indentation pre-scan at depth 0: a newline ends the physical
  # line, a `\` may be a line continuation, and `#{` opens interpolation. Compile-once cached.
  defp heredoc_sig_pattern do
    key = {__MODULE__, :heredoc_sig_pattern}

    case :persistent_term.get(key, nil) do
      nil ->
        pattern = :binary.compile_pattern(["\n", "\\", "\#{"])
        :persistent_term.put(key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  # Bytes that could carry a comment bidi/break lint: VT/FF/CR (`0x0B..0x0D`, the only sub-ASCII
  # break chars) plus every high byte (`0x80..0xFF`) — NEL/LS/PS and the bidi controls are all
  # multi-byte UTF-8, so each has a high byte. A comment slice matching none of these is provably
  # lint-free, letting `lex(?#, …)` skip the precise scan. Same compile-once `:persistent_term` cache.
  defp comment_suspicious_pattern do
    key = {__MODULE__, :comment_suspicious_pattern}

    case :persistent_term.get(key, nil) do
      nil ->
        pattern =
          :binary.compile_pattern(Enum.map([0x0B, 0x0C, 0x0D | Enum.to_list(128..255)], &<<&1>>))

        :persistent_term.put(key, pattern)
        pattern

      pattern ->
        pattern
    end
  end

  # Mark the notice channel when a unicode NAME token is emitted: `Security.lint/1` only inspects
  # identifier/alias/atom/kw-name tokens, and every non-ASCII one of those comes through a
  # `lex_unicode*` path, so the gate can be decided here instead of by a whole-token pass in
  # `tokenize_with_comments/2`. The test is on the EMITTED (NFC-normalized) name, not on the source
  # bytes, exactly as the old pass did — NFC can turn a non-ASCII word into an ASCII name (U+212A
  # KELVIN SIGN normalizes to `K`), and such a token is not a unicode name for lint purposes.
  defp uni_w(name, w), do: if(nonascii_byte?(name), do: [:unicode_name | w], else: w)

  defp confusable_lint(tokens), do: Toxic2.String.Tokenizer.Security.lint(tokens)

  # `st` is a terminator stack used ONLY to tell an interpolation-closing `}` (which ends a
  # string interpolation and resumes string scanning) apart from a `}` that closes a `{`. `{`
  # pushes `:brace`; `#{` inside a string pushes `:interp` (see `read_string`). It is NOT the
  # parser's delimiter matcher — unbalanced delimiters are the parser's concern; this only
  # disambiguates the lexer's two meanings of `}`.

  # --- EOF ---------------------------------------------------------------
  defp lex(<<>>, _line, _col, acc, w, _st), do: {acc, w}

  # --- horizontal whitespace ---------------------------------------------
  # A pure zero-alloc tail call per space/tab — measured optimal. Both a count-the-run variant
  # (allocates a tuple/slice per run) and multi-byte clauses (`<<c,c,c,c,…>>` consuming 2/4/8 at
  # once) were A/B'd in isolation and BOTH regressed monotonically: inter-token runs are mostly
  # length 1 (leading indentation is coalesced by `consume_eols`), advancing the match context one
  # byte is nearly free on BEAM, and the extra clauses' equality checks + partial-run fall-through
  # cascade never pay back — even on aligned/indented input with runs of 4–8.
  defp lex(<<c, rest::binary>>, line, col, acc, w, st) when c in [?\s, ?\t],
    do: lex(rest, line, col + 1, acc, w, st)

  # --- end of line (coalesced run, explicit token) -----------------------
  defp lex(<<"\r\n", _::binary>> = bin, line, col, acc, w, st),
    do: do_eol(bin, line, col, acc, w, st)

  defp lex(<<"\n", _::binary>> = bin, line, col, acc, w, st),
    do: do_eol(bin, line, col, acc, w, st)

  # --- comments (dropped unless preserved; phase 2 drops) ----------------
  # The comment body was scanned TWICE: once byte-by-byte to find the newline, once more for the
  # bidi/break lint. Find the newline with a C-level `:binary.match` instead, and gate the lint scan
  # behind a `:binary.match` pre-check — every bidi/break codepoint has a byte in `0x0B..0x0D` or
  # `0x80..0xFF` (NEL/LS/PS/bidi controls are all multi-byte UTF-8), so a slice with none of those
  # can't carry a lint and the second scan is skipped for ordinary ASCII comments (the common case).
  defp lex(<<?#, rest::binary>>, line, col, acc, w, st) do
    drop_len =
      case :binary.match(rest, "\n") do
        {pos, _} -> pos
        :nomatch -> byte_size(rest)
      end

    # The suspicious-byte pre-check (high bytes + VT/FF/CR) gates the lint scan AND tells us whether
    # the comment is plain ASCII: when nothing matched, bytes == codepoints so the column advance can
    # skip the codepoint walk (the common case). High bytes are part of the pattern, so any multi-byte
    # comment trips it.
    suspicious? =
      :binary.match(rest, comment_suspicious_pattern(), scope: {0, drop_len}) != :nomatch

    acc =
      if suspicious?,
        do: comment_bidi_check(rest, line, col + 1, acc),
        else: acc

    after_comment = rest_at(rest, drop_len)

    # comments are dropped from the token stream (the parser never sees them); they ride the
    # out-of-band `w` channel as `{:comment, line, col, text, previous_eol_count, next_eol_count}`
    # and `tokenize_with_comments/2` partitions them back out. `tokenize/2` discards comments, so it
    # builds none at all (see `do_tokenize/2`) — the lint above and the column advance below still
    # run in both modes.
    w =
      if keep_comments?(st),
        do: [comment_notice(rest, drop_len, after_comment, line, col, acc) | w],
        else: w

    # Advance by the comment's CODEPOINT width, not its byte width: a multi-byte comment (`# café`)
    # would otherwise hand the following `:eol`/EOF token a byte-based start column.
    comment_cols =
      if suspicious?,
        do: cp_width(binary_part(rest, 0, drop_len), 0),
        else: drop_len

    lex(after_comment, line, col + 1 + comment_cols, acc, w, st)
  end

  # --- line continuation: a `\` right before a newline joins the lines (no :eol emitted) ----
  # Since Elixir 1.20 a SPACE-preceded `\`-newline is horizontal whitespace, so `foo \⏎+1` =>
  # `foo(+1)` (like `foo +1`), distinct from the no-space `foo\⏎+1` => `foo + 1`. After the join
  # the two forms have identical token spans, so we emit a zero-width `:cont` marker for the
  # space-preceded form; `Tokens.from_list/1` partitions it out of the stream into a side-set the
  # parser's no-parens-arg check consults (it never reaches the parser as a token).
  # A continuation with NOTHING after it (`x\⏎<eof>`) is upstream's hard "invalid escape \\ at
  # end of file" error (R14) — the terminal clauses come first, mirroring elixir_tokenizer.
  defp lex(<<?\\, ?\r, ?\n>>, line, col, acc, w, st),
    do: lex(<<>>, line, col, cont_eof_error(acc, line, col), w, st)

  defp lex(<<?\\, ?\n>>, line, col, acc, w, st),
    do: lex(<<>>, line, col, cont_eof_error(acc, line, col), w, st)

  defp lex(<<?\\, ?\r, ?\n, rest::binary>>, line, col, acc, w, st),
    do: lex(rest, line + 1, 1, cont_marker(acc, line, col), w, st)

  defp lex(<<?\\, ?\n, rest::binary>>, line, col, acc, w, st),
    do: lex(rest, line + 1, 1, cont_marker(acc, line, col), w, st)

  # --- heredocs: `"""` / `'''` (before the single-quote clauses) ---------
  defp lex(<<?", ?", ?", rest::binary>>, line, col, acc, w, st),
    do: open_heredoc(rest, line, col, acc, w, st, ?")

  defp lex(<<?', ?', ?', rest::binary>>, line, col, acc, w, st),
    do: open_heredoc(rest, line, col, acc, charlist_notice(w, acc, line, col, 3), st, ?')

  # --- quoted literals: linear form (start, fragments, interp, end) ------
  # The quote warning (charlist / keyword / call deprecations, unnecessary quotes) is deferred to
  # `close_quoted`, where the role and full content are known. The role is computed here: a literal
  # right after a `.` is a CALL name (`a."foo"()`), otherwise a bare string (maybe a keyword key).
  defp lex(<<?", rest::binary>>, line, col, acc, w, st) do
    start = {:string_start, line, col, line, col + 1, nil}
    lit = {:dquote, quote_role(acc, line, col)}
    read_quoted(rest, line, col + 1, [], {line, col + 1}, [start | acc], w, st, lit)
  end

  defp lex(<<?', rest::binary>>, line, col, acc, w, st) do
    start = {:charlist_start, line, col, line, col + 1, nil}
    lit = {:charlist, quote_role(acc, line, col)}
    read_quoted(rest, line, col + 1, [], {line, col + 1}, [start | acc], w, st, lit)
  end

  # --- sigils: ~name<delim>...<delim>modifiers ---------------------------
  defp lex(<<?~, c, _::binary>> = bin, line, col, acc, w, st)
       when c in ?a..?z or c in ?A..?Z do
    namelen = sigil_name(rest_at(bin, 1), 0)
    name = binary_part(bin, 1, namelen)
    ncol = col + 1 + namelen
    acc = sigil_name_check(name, line, col, ncol, acc)
    start = {:sigil_start, line, col, line, ncol, name}
    begin_sigil(rest_at(bin, 1 + namelen), line, ncol, [start | acc], w, st, name)
  end

  # --- char literals: ?\<esc> and ?<codepoint> ---------------------------
  # A bare carriage return after `?` / `?\` is rejected since Elixir 1.20 (CR is only valid as part
  # of a CRLF line ending); the char-literal clauses below handle `?\<LF>` and other codepoints.
  defp lex(<<??, ?\\, ?\r, rest::binary>>, line, col, acc, w, st) do
    err = {:error, line, col, line, col + 3, LexError.new(:bare_carriage_return, %{})}
    lex(rest, line, col + 3, [err | acc], w, st)
  end

  defp lex(<<??, ?\r, rest::binary>>, line, col, acc, w, st) do
    err = {:error, line, col, line, col + 2, LexError.new(:bare_carriage_return, %{})}
    lex(rest, line, col + 2, [err | acc], w, st)
  end

  # `?\<newline>` is a valid char (value `\n`) that CONSUMES the newline — the token spans onto the
  # next line, so line state advances and no trailing `:eol` is emitted (matching Elixir). A `\r`
  # escape (`?\r`, the letter) is the ordinary one-char case below — value `\r`, no consume.
  # Like any named-escape special char, Elixir warns to write `?\n` instead.
  defp lex(<<??, ?\\, ?\n, rest::binary>>, line, col, acc, w, st),
    do:
      cont(
        rest,
        {:char, line, col, line + 1, 1, ?\n},
        acc,
        char_escape_notice(?\n, line, col, 2, w),
        st
      )

  # The escaped char is a full CODEPOINT (`?\é` is 233, not the first UTF-8 byte of `é`; K3),
  # and the column advances by 3 codepoints. A raw bidi control / line break after `?\` is
  # rejected like in strings (R7). The byte fallback keeps invalid UTF-8 tolerant.
  defp lex(<<??, ?\\, e::utf8, rest::binary>>, line, col, acc, w, st) do
    cond do
      bidi?(e) or break?(e) ->
        code = if bidi?(e), do: :invalid_bidi, else: :invalid_break
        err = {:error, line, col, line, col + 3, LexError.new(code, %{codepoint: e})}
        cont(rest, err, acc, w, st)

      true ->
        value = char_escape_value(e)
        w = char_escape_notice(e, line, col, 3, w)
        cont(rest, {:char, line, col, line, col + 3, value}, acc, w, st)
    end
  end

  defp lex(<<??, ?\\, b, rest::binary>>, line, col, acc, w, st) do
    value = char_escape_value(b)
    w = char_escape_notice(b, line, col, 3, w)
    cont(rest, {:char, line, col, line, col + 3, value}, acc, w, st)
  end

  defp lex(<<??, cp::utf8, rest::binary>>, line, col, acc, w, st) do
    w = unusual_char_notice(cp, line, col, 2, w)
    cont(rest, {:char, line, col, line, col + 2, cp}, acc, w, st)
  end

  # --- numbers: 0x / 0o / 0b ---------------------------------------------
  # `digit_run/4` fuses the old run_len + valid_underscores? double pass (each a captured-fun call
  # per byte, plus a validation-only `binary_part` slice) into ONE direct-guard pass per radix.
  # Only LOWERCASE radix prefixes exist upstream — `0XFF`/`0O17`/`0B101` hit the invalid
  # character-after-number error, so uppercase falls through to the decimal clause (OX2).
  defp lex(<<?0, b, rest::binary>> = bin, line, col, acc, w, st)
       when b in [?x, ?o, ?b] do
    {class, base} = radix(b)
    {rlen, ok, after_digits} = digit_run(rest, class, 0, :start)

    if ok do
      total = 2 + rlen
      value = bin |> binary_part(2, rlen) |> strip_underscores() |> String.to_integer(base)
      cont(after_digits, {:int, line, col, line, col + total, value}, acc, w, st)
    else
      num_error(bin, 2 + rlen, line, col, acc, w, st)
    end
  end

  # --- numbers: decimal int / float --------------------------------------
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_digit(c) do
    {ilen, int_ok, after_int} = digit_run(bin, ?9, 0, :start)

    case after_int do
      <<?., d, _::binary>> when is_digit(d) ->
        {flen, frac_ok, after_frac} = digit_run(rest_at(after_int, 1), ?9, 0, :start)
        {elen, exp_ok} = scan_exp(after_frac)
        total = ilen + 1 + flen + elen

        # `String.to_float/1` raises on overflow (`1.0e309` → infinity); stay total and diagnose it.
        with true <- int_ok and frac_ok and exp_ok,
             {:ok, value} <- safe_to_float(strip_underscores(binary_part(bin, 0, total))) do
          cont(rest_at(bin, total), {:flt, line, col, line, col + total, value}, acc, w, st)
        else
          _ -> num_error(bin, total, line, col, acc, w, st)
        end

      _ ->
        if int_ok do
          value = bin |> binary_part(0, ilen) |> strip_underscores() |> String.to_integer()
          cont(after_int, {:int, line, col, line, col + ilen, value}, acc, w, st)
        else
          num_error(bin, ilen, line, col, acc, w, st)
        end
    end
  end

  # --- type operator :: (before the atom `:` clause) ---------------------
  # `:::` is NOT `::` + `:`; it's the atom `:"::"` (a leading `:` taking `::` as its operator
  # name). Elixir accepts it but warns it should be written `:"::"` to avoid ambiguity.
  defp lex(<<?:, ?:, ?:, rest::binary>>, line, col, acc, w, st) do
    w = [{:lexer, :warning, :ambiguous_quoted_atom, {line, col, line, col + 3}, %{}} | w]
    cont(rest, {:atom, line, col, line, col + 3, "::"}, acc, w, st)
  end

  # `::` followed by a non-`:` byte is the type operator (the `:::` atom case is handled above).
  defp lex(<<?:, ?:, next, _::binary>> = bin, line, col, acc, w, st) when next != ?:,
    do: cont(rest_at(bin, 2), {:type_op, line, col, line, col + 2, :"::"}, acc, w, st)

  defp lex(<<?:, ?:>>, line, col, acc, w, st),
    do: cont(<<>>, {:type_op, line, col, line, col + 2, :"::"}, acc, w, st)

  # --- quoted atoms `:"..."` / `:'...'` (a `:quoted_atom` marker + the quoted literal's tokens) --
  # Quoted atoms carry the `:atom` role; their warnings (single-quote deprecation, unnecessary
  # quotes) are emitted at `close_quoted` once the content is known.
  defp lex(<<?:, ?", rest::binary>>, line, col, acc, w, st) do
    marker = {:quoted_atom, line, col, line, col + 1, nil}
    start = {:string_start, line, col + 1, line, col + 2, nil}
    lit = {:dquote, {:atom, line, col}}
    read_quoted(rest, line, col + 2, [], {line, col + 2}, [start, marker | acc], w, st, lit)
  end

  defp lex(<<?:, ?', rest::binary>>, line, col, acc, w, st) do
    marker = {:quoted_atom, line, col, line, col + 1, nil}
    start = {:charlist_start, line, col + 1, line, col + 2, nil}
    lit = {:charlist, {:atom, line, col}}
    read_quoted(rest, line, col + 2, [], {line, col + 2}, [start, marker | acc], w, st, lit)
  end

  # --- atoms: :name and :<operator> -------------------------------------
  # Unlike identifiers, an atom name may contain `@` (`:nonode@nohost`, `:foo@`).
  defp lex(<<?:, c, _::binary>> = bin, line, col, acc, w, st)
       when is_lower_start(c) or is_upper_start(c) do
    {wlen, after_name} = read_atom_name(rest_at(bin, 1))

    case after_name do
      <<cp::utf8, _::binary>> when cp > 127 ->
        lex_unicode_atom(rest_at(bin, 1), line, col, acc, w, st)

      _ ->
        total = 1 + wlen
        name = binary_part(bin, 1, wlen)
        w = bang_before_eq_notice(name, after_name, line, col, total, w)

        cont(
          rest_at(bin, total),
          {:atom, line, col, line, col + total, name},
          acc,
          w,
          st
        )
    end
  end

  # unicode-started atom name (`:café`, `:αβγ`, `:Σ` — incl. unicode-uppercase, valid as an atom)
  defp lex(<<?:, cp::utf8, _::binary>> = bin, line, col, acc, w, st) when cp > 127,
    do: lex_unicode_atom(rest_at(bin, 1), line, col, acc, w, st)

  defp lex(<<?:, rest::binary>> = bin, line, col, acc, w, st) do
    case op_atom_len(rest) do
      nil ->
        err = LexError.new(:unexpected_colon, %{})
        cont(rest_at(bin, 1), {:error, line, col, line, col + 1, err}, acc, w, st)

      oplen ->
        total = 1 + oplen

        cont(
          rest_at(bin, total),
          {:atom, line, col, line, col + total, binary_part(bin, 1, oplen)},
          acc,
          w,
          st
        )
    end
  end

  # --- capture int &1 (before the `&` operator in the table) -------------
  # Upstream emits `capture_int` then tokenizes the integer NORMALLY, so radix forms and
  # underscores are valid capture arguments: `&0x0A`, `&0o12`, `&0b1010`, `&1_0` (R13).
  defp lex(<<?&, d, _::binary>> = bin, line, col, acc, w, st) when is_digit(d) do
    case capture_int_scan(rest_at(bin, 1)) do
      {:ok, nlen, value} ->
        tok = {:capture_int, line, col, line, col + 1 + nlen, value}
        cont(rest_at(bin, 1 + nlen), tok, acc, w, st)

      {:error, nlen} ->
        num_error(bin, 1 + nlen, line, col, acc, w, st)
    end
  end

  # --- percent (parser combines with `{`/alias for maps/structs) ---------
  # `% {` — a map opener with a space before the brace is invalid (`%{...}` must be adjacent; a
  # space is fine before an alias, `% Foo{}`). Emit an error, then lex the `%` as usual (tolerant).
  defp lex(<<?%, c, _::binary>> = bin, line, col, acc, w, st) when c in [?\s, ?\t] do
    if match?(<<?{, _::binary>>, skip_spaces_tabs(rest_at(bin, 1))) do
      acc = [{:error, line, col, line, col + 1, LexError.new(:space_before_curly, %{})} | acc]
      cont(rest_at(bin, 1), {:percent, line, col, line, col + 1, nil}, acc, w, st)
    else
      cont(rest_at(bin, 1), {:percent, line, col, line, col + 1, nil}, acc, w, st)
    end
  end

  # `%{}:`/`%:` followed by a kw separator are operator keyword keys (handled via op_kw_len).
  defp lex(<<?%, _::binary>> = bin, line, col, acc, w, st) do
    case op_kw_len(bin) do
      nil -> cont(rest_at(bin, 1), {:percent, line, col, line, col + 1, nil}, acc, w, st)
      len -> emit_op_kw(bin, len, line, col, acc, w, st)
    end
  end

  # --- `{` opens a brace frame (so the matching `}` isn't mistaken for an interp close) ---
  # `{}:` followed by a kw separator is an operator keyword key.
  defp lex(<<?{, _::binary>> = bin, line, col, acc, w, st) do
    case op_kw_len(bin) do
      nil -> cont(rest_at(bin, 1), {:"{", line, col, line, col + 1, nil}, acc, w, [:brace | st])
      len -> emit_op_kw(bin, len, line, col, acc, w, st)
    end
  end

  # --- `}` ends an interpolation (resume the string) OR closes a brace ---
  defp lex(<<?}, rest::binary>>, line, col, acc, w, [{:interp, resume} | st]) do
    token = {:end_interpolation, line, col, line, col + 1, nil}
    resume_interp(resume, rest, line, col + 1, [token | acc], w, st)
  end

  defp lex(<<?}, rest::binary>>, line, col, acc, w, [:brace | st]),
    do: cont(rest, {:"}", line, col, line, col + 1, nil}, acc, w, st)

  defp lex(<<?}, rest::binary>>, line, col, acc, w, st),
    do: cont(rest, {:"}", line, col, line, col + 1, nil}, acc, w, st)

  # `;` is an end-of-expression separator, but two CONSECUTIVE semicolons (with only
  # whitespace/newlines between — newlines fold into the preceding `;` in Elixir) are rejected:
  # `;;`, `a;\n;b`. A single/leading/trailing `;` is fine. Tolerant: record the error, keep the `;`.
  defp lex(<<?;, rest::binary>>, line, col, acc, w, st) do
    acc =
      if prev_semicolon?(acc),
        do: [{:error, line, col, line, col + 1, LexError.new(:unexpected_semicolon, %{})} | acc],
        else: acc

    cont(rest, {:";", line, col, line, col + 1, nil}, acc, w, st)
  end

  # --- other single-char delimiters / separators ------------------------
  defp lex(<<c, rest::binary>>, line, col, acc, w, st) when c in [?(, ?), ?[, ?], ?,],
    do: cont(rest, {delim_kind(c), line, col, line, col + 1, nil}, acc, w, st)

  # --- identifiers (lowercase/_) : kw key, reserved op, literal, or name --
  # If the ascii run flows into a `>127` byte the word is unicode — hand the WHOLE word to the
  # vendored tokenizer (NFC + UTS-39 script checks), so e.g. `café`/`módulo` stay single tokens.
  #
  # PERF: every `bs_start_match` on a sub-binary allocates a fresh match state, and a callee that
  # does not start by matching its binary argument cannot inherit the caller's match context
  # (`bin_opt_info` reports each such call site NOT OPTIMIZED). The old shape re-matched the tail
  # five times per identifier (the old `read_name`, the utf8 peek, `kw_suffix`, the `@` test, and
  # `binary:last`/`first`). Now `word_len/2` returns the byte count and its own tail, ONE
  # match over the two boundary bytes decides the `?`/`!` suffix and the ambiguous `=`, and ONE
  # `case` over the boundary decides unicode / `::` / kw / kw-nospace / `@` / plain. The name is
  # sliced only at the leaf that emits it.
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_lower_start(c) do
    {wlen, rest} = word_len(bin, 0)
    lex_lower_after_word(bin, rest, wlen, line, col, acc, w, st)
  end

  # --- aliases (Uppercase): kw key or alias ------------------------------
  # Same single-match restructure as the lowercase path above; the alias scanner takes no trailing
  # `?`/`!`, so the boundary case is entered directly from `word_len/2`.
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_upper_start(c) do
    {len, after_name} = word_len(bin, 0)
    lex_upper_boundary(bin, after_name, len, line, col, acc, w, st)
  end

  # --- unicode-started identifiers (`αβγ`, `привет`) --------------------
  defp lex(<<cp::utf8, _::binary>> = bin, line, col, acc, w, st) when cp > 127,
    do: lex_unicode(bin, line, col, acc, w, st)

  # --- operators (longest match) + tolerant UTF-8/byte error fallback ----
  # Match the operator ONCE, then decide operator-token vs operator keyword-key from that single
  # result (the old path matched the table twice: once via `op_kw_len`/`op_atom_len`, again here).
  defp lex(bin, line, col, acc, w, st) do
    case match_op(bin) do
      {kind, value, len} -> emit_operator_or_kw(bin, kind, value, len, line, col, acc, w, st)
      nil -> lex_op_error(bin, line, col, acc, w, st)
    end
  end

  # `foo!=1` / `bar?=1` — an identifier ending in `!`/`?` immediately followed by `=` is ambiguous
  # (`foo! = 1` vs `foo != 1`); Elixir warns. Both boundary bytes are read in this one match, so
  # the warning costs nothing extra on the ~99% of identifiers that don't end in `?`/`!`.
  defp lex_lower_after_word(bin, <<p, ?=, _::binary>> = rest, wlen, line, col, acc, w, st)
       when p in [??, ?!] do
    len = wlen + 1
    w = [{:lexer, :warning, :ambiguous_bang_before_equals, {line, col, line, col + len}, %{}} | w]
    cont(rest_at(rest, 1), lower_token(binary_part(bin, 0, len), line, col, len), acc, w, st)
  end

  defp lex_lower_after_word(bin, <<p, after_p::binary>>, wlen, line, col, acc, w, st)
       when p in [??, ?!],
       do: lex_lower_boundary(bin, after_p, wlen + 1, line, col, acc, w, st)

  defp lex_lower_after_word(bin, rest, wlen, line, col, acc, w, st),
    do: lex_lower_boundary(bin, rest, wlen, line, col, acc, w, st)

  # ONE binary match over the boundary decides unicode / `::` / kw / kw_nospace / `@` / plain.
  # (`::` must be rejected before the kw clauses: `foo::t` is a type operator, not a keyword key.)
  defp lex_lower_boundary(bin, after_name, len, line, col, acc, w, st) do
    case after_name do
      <<cp::utf8, _::binary>> when cp > 127 ->
        lex_unicode(bin, line, col, acc, w, st)

      <<?:, ?:, _::binary>> ->
        cont(after_name, lower_token(binary_part(bin, 0, len), line, col, len), acc, w, st)

      <<?:, c, _::binary>> when c in [?\s, ?\t, ?\r, ?\n] ->
        tok = {:kw_identifier, line, col, line, col + len + 1, binary_part(bin, 0, len)}
        cont(rest_at(after_name, 1), tok, acc, w, st)

      <<?:, _::binary>> ->
        name = binary_part(bin, 0, len)
        acc = kw_nospace_error(name, line, col, len, acc)
        tok = {:kw_identifier, line, col, line, col + len + 1, name}
        cont(rest_at(after_name, 1), tok, acc, w, st)

      <<?@, _::binary>> ->
        lex_lower_at(bin, binary_part(bin, 0, len), after_name, len, line, col, acc, w, st)

      _ ->
        cont(after_name, lower_token(binary_part(bin, 0, len), line, col, len), acc, w, st)
    end
  end

  defp lex_upper_boundary(bin, after_name, len, line, col, acc, w, st) do
    case after_name do
      <<cp::utf8, _::binary>> when cp > 127 ->
        lex_unicode(bin, line, col, acc, w, st)

      <<?:, ?:, _::binary>> ->
        tok = {:alias, line, col, line, col + len, binary_part(bin, 0, len)}
        cont(after_name, tok, acc, w, st)

      <<?:, c, _::binary>> when c in [?\s, ?\t, ?\r, ?\n] ->
        tok = {:kw_identifier, line, col, line, col + len + 1, binary_part(bin, 0, len)}
        cont(rest_at(after_name, 1), tok, acc, w, st)

      <<?:, _::binary>> ->
        name = binary_part(bin, 0, len)
        acc = kw_nospace_error(name, line, col, len, acc)
        tok = {:kw_identifier, line, col, line, col + len + 1, name}
        cont(rest_at(after_name, 1), tok, acc, w, st)

      <<c, _::binary>> when c in [?!, ??, ?@] ->
        lex_upper_bang(bin, after_name, len, line, col, acc, w, st)

      _ ->
        tok = {:alias, line, col, line, col + len, binary_part(bin, 0, len)}
        cont(after_name, tok, acc, w, st)
    end
  end

  defp emit_operator_or_kw(bin, kind, value, len, line, col, acc, w, st) do
    case dot_member_split(kind, acc) do
      # DOT CONTEXT (F2): right after a `.`, only operators legal as remote member names are one
      # token — `//`, `->`, `=>` are not, so upstream's handle_dot emits their FIRST char as the
      # member and re-lexes the rest (`foo.//1` => `(foo./()) / 1`, `foo.->1` => `(foo.-()) > 1`).
      {k1, v1} ->
        cont(rest_at(bin, 1), {k1, line, col, line, col + 1, v1}, acc, w, st)

      nil ->
        emit_operator_or_kw_free(bin, kind, value, len, line, col, acc, w, st)
    end
  end

  defp dot_member_split(kind, [{:dot, _, _, _, _, _} | _acc])
       when kind in [:ternary_op, :stab_op, :assoc_op] do
    case kind do
      :ternary_op -> {:mult_op, :/}
      :stab_op -> {:dual_op, :-}
      :assoc_op -> {:match_op, :=}
    end
  end

  defp dot_member_split(_kind, _acc), do: nil

  defp emit_operator_or_kw_free(bin, kind, value, len, line, col, acc, w, st) do
    # `..//` followed — across horizontal space and `\`-newline continuations — by `/` fuses
    # into ONE `:ternary_op` token (`&..///3`, `&..//\<nl>/3`): upstream re-emits the ternary
    # operator as a single identifier-shaped token exactly in this shape, so the parser's
    # op-ref rule (`op` + `/arity`) sees it whole. The `..` table match (len 2) would
    # otherwise win.
    fused = kind == :range_op and fused_ternary_ref(bin, line, col + 4)

    # PERF: `atom_op_kw_len/1` and `too_many_same_char_notice/4` each start with a binary match on
    # `bin`, i.e. a fresh match state per operator token, for checks that can only fire for two
    # 2-byte table matches (`..` / `<<`, the prefixes of `..//` / `<<>>`) and for 3-char operators
    # respectively. The `kind`/`len` we already have decide that with integer/atom compares.
    sp = atom_op_kw_at(kind, len, bin)

    cond do
      # `<<>>:` / `..//:` — atom-shaped operator keys whose full length the table's longest match
      # (`<<` / `..`) would shadow; `%{}`/`{}`/`%`/`::` are handled by earlier `lex/6` clauses.
      sp != nil ->
        emit_op_kw(bin, sp, line, col, acc, w, st)

      match?({:fused, _, _, _}, fused) ->
        {:fused, rest, l2, c2} = fused
        tok = {:ternary_op, line, col, line, col + 4, :..//}
        lex(rest, l2, c2, [tok | acc], w, st)

      # Adjacent `..//` in any OTHER shape (`a ..// b`) is a tokenizer error upstream — never a
      # `..` + `//` pair — tolerated here as one 4-column `:error` token.
      fused == :error ->
        err = LexError.new(:unexpected_token, %{token: "..//"})
        cont(rest_at(bin, 4), {:error, line, col, line, col + 4, err}, acc, w, st)

      # a table operator directly followed by a keyword colon is an operator keyword key (`+: 1`),
      # EXCEPT `//` (the ternary step op) which is never an atom/keyword (`a // b: c` is `a // (b: c)`).
      kind != :ternary_op and kw_colon_at?(bin, len) ->
        emit_op_kw(bin, len, line, col, acc, w, st)

      true ->
        w = deprecated_op_notice(value, len, line, col, w)
        w = if len == 3, do: too_many_same_char_notice(bin, line, col, w), else: w
        cont(rest_at(bin, len), {kind, line, col, line, col + len, value}, acc, w, st)
    end
  end

  # `:foo!=1` / `:bar?=1` — an ATOM ending in `!`/`?` immediately followed by `=` is ambiguous
  # (`:foo! = 1` vs `:foo != 1`); Elixir warns. A space on either side removes it. The identifier
  # path decides the same thing from its boundary match (see `lex_lower_after_word/8`); the atom
  # path keeps this helper because `read_atom_name/1` returns only a length, not the boundary byte.
  #
  # Check the NAME's last byte first (`:binary.last`, a BIF — no allocation, short-circuits for the
  # ~99% of atoms not ending in `?`/`!`), THEN peek the next source byte, rather than matching
  # `<<?=, _::binary>>` in a clause head (whose `bs_start_match4` would allocate a fresh match
  # context on EVERY atom just to test one byte).
  defp bang_before_eq_notice(name, after_bin, line, col, len, w) do
    last = :binary.last(name)

    if (last == ?? or last == ?!) and after_bin != <<>> and :binary.first(after_bin) == ?= do
      [{:lexer, :warning, :ambiguous_bang_before_equals, {line, col, line, col + len}, %{}} | w]
    else
      w
    end
  end

  defp deprecated_op_notice(value, len, line, col, w) do
    case @deprecated_ops do
      %{^value => code} -> [{:lexer, :warning, code, {line, col, line, col + len}, %{}} | w]
      _ -> w
    end
  end

  # A 3-char repeated-char operator (`&&&`/`|||`/`^^^`/`+++`/`---`) directly followed by a 4th
  # occurrence of the same char (`&&&&`, `++++`) — Elixir warns to put a space between them.
  defp too_many_same_char_notice(<<c, c, c, c, _::binary>>, line, col, w)
       when c in [?&, ?|, ?^, ?+, ?-],
       do: [{:lexer, :warning, :too_many_same_char, {line, col, line, col + 3}, %{char: c}} | w]

  defp too_many_same_char_notice(_bin, _line, _col, w), do: w

  # Only the 2-byte `..` / `<<` table matches can be the prefix of an atom-shaped operator key, so
  # every other operator skips `atom_op_kw_len/1` (and the match state its binary head allocates).
  defp atom_op_kw_at(kind, 2, bin) when kind in [:range_op, :"<<"], do: atom_op_kw_len(bin)
  defp atom_op_kw_at(_kind, _len, _bin), do: nil

  defp atom_op_kw_len(<<"<<>>", _::binary>> = bin), do: if(kw_colon_at?(bin, 4), do: 4)
  defp atom_op_kw_len(<<"..//", _::binary>> = bin), do: if(kw_colon_at?(bin, 4), do: 4)
  defp atom_op_kw_len(_), do: nil

  # `..//` + horizontal space (spaces/tabs and non-EOF `\`-newline continuations, exactly
  # upstream's `strip_horizontal_space`) + `/` → `{:fused, rest_at_slash, line, col}`. An
  # adjacent `..//` in any other shape is `:error` (upstream's tokenizer rejects it outright);
  # nil when the input doesn't start with `..//` at all.
  defp fused_ternary_ref(<<"..//", rest::binary>>, line, col) do
    case fused_ternary_ws(rest, line, col) do
      nil -> :error
      {rest2, l2, c2} -> {:fused, rest2, l2, c2}
    end
  end

  defp fused_ternary_ref(_bin, _line, _col), do: nil

  defp fused_ternary_ws(<<c, rest::binary>>, line, col) when c in [?\s, ?\t],
    do: fused_ternary_ws(rest, line, col + 1)

  defp fused_ternary_ws(<<"\\\r\n", rest::binary>>, line, _col) when rest != <<>>,
    do: fused_ternary_ws(rest, line + 1, 1)

  defp fused_ternary_ws(<<"\\\n", rest::binary>>, line, _col) when rest != <<>>,
    do: fused_ternary_ws(rest, line + 1, 1)

  defp fused_ternary_ws(<<?/, _::binary>> = rest, line, col), do: {rest, line, col}
  defp fused_ternary_ws(_rest, _line, _col), do: nil

  # --- unicode identifier/atom tokenization (vendored Toxic2.String.Tokenizer) -----------------
  # The tokenizer returns {kind, nfc_name, rest, codepoint_len, ascii?, special}. `kind` is
  # `:identifier` (usable as a name), `:alias` (Module-like), or `:atom` (unicode-uppercase —
  # valid ONLY as an atom name, not a standalone identifier). Columns advance by codepoint count.

  # Identifier position (start of a word). `:atom`-kind words and tokenizer errors are rejected.
  defp lex_unicode(bin, line, col, acc, w, st) do
    case Toxic2.String.Tokenizer.tokenize(bin) do
      {:identifier, name, rest, len, _ascii?, special} ->
        emit_unicode_name(name, rest, len, special, line, col, acc, w, st)

      {:alias, name, rest, len, _ascii?, _special} ->
        emit_unicode_alias(name, rest, len, line, col, acc, w, st)

      {:atom, name, rest, len, _ascii?, _special} ->
        # A unicode-uppercase word is valid only as an atom name — `Σ` alone is rejected, but as a
        # keyword KEY it's fine (`[Ólá: 0]` => `[{:Ólá, 0}]`).
        case kw_suffix(rest) do
          {:kw, r} ->
            cont(
              r,
              {:kw_identifier, line, col, line, col + len + 1, name},
              acc,
              uni_w(name, w),
              st
            )

          {:kw_nospace, r} ->
            acc = kw_nospace_error(name, line, col, len, acc)

            cont(
              r,
              {:kw_identifier, line, col, line, col + len + 1, name},
              acc,
              uni_w(name, w),
              st
            )

          :no ->
            unicode_error(bin, line, col, acc, w, st)
        end

      # The leading codepoint is not an identifier start at all (a stray symbol like `√`): defer
      # to the operator/byte fallback, which emits a precise one-codepoint `:unexpected_char`.
      {:error, :empty} ->
        lex_operator(bin, line, col, acc, w, st)

      {:error, _reason} ->
        unicode_error(bin, line, col, acc, w, st)
    end
  end

  # A unicode word with an uppercase-ASCII start (`Café`, `Foó`) is `:alias`-kind, but aliases must
  # be pure ASCII — Elixir rejects them. As a keyword KEY it's fine, though (`[Café: 1]` is a valid
  # atom keyword), so only the non-keyword alias usage errors. Reaching here implies a >127
  # codepoint, so the alias is always invalid.
  defp emit_unicode_alias(name, rest, len, line, col, acc, w, st) do
    case kw_suffix(rest) do
      {:kw, r} ->
        cont(r, {:kw_identifier, line, col, line, col + len + 1, name}, acc, uni_w(name, w), st)

      {:kw_nospace, r} ->
        acc = kw_nospace_error(name, line, col, len, acc)
        cont(r, {:kw_identifier, line, col, line, col + len + 1, name}, acc, uni_w(name, w), st)

      :no ->
        err = LexError.new(:invalid_alias, %{name: name})
        cont(rest, {:error, line, col, line, col + len, err}, acc, w, st)
    end
  end

  # Only `lex_unicode/6`'s `:identifier` branch reaches here, so the token kind is fixed (the `kind`
  # parameter it used to take was always `:identifier`).
  defp emit_unicode_name(name, rest, len, special, line, col, acc, w, st) do
    case kw_suffix(rest) do
      {:kw, r} ->
        cont(r, {:kw_identifier, line, col, line, col + len + 1, name}, acc, uni_w(name, w), st)

      {:kw_nospace, r} ->
        acc = kw_nospace_error(name, line, col, len, acc)
        cont(r, {:kw_identifier, line, col, line, col + len + 1, name}, acc, uni_w(name, w), st)

      :no ->
        # `é@bar` — upstream checks HasAt after the keyword-suffix check: an `@`-bearing name is
        # valid only as an atom or keyword key (R15). Keep the token for a tolerant tree.
        acc =
          if :at in special do
            [{:error, line, col, line, col + len, LexError.new(:invalid_identifier, %{})} | acc]
          else
            acc
          end

        cont(rest, {:identifier, line, col, line, col + len, name}, acc, uni_w(name, w), st)
    end
  end

  # Atom-literal position (`:` already at `col`; `wordbin` is one past the colon). Every word
  # kind — including `:atom` (`:Σ`) — is a valid atom name here.
  defp lex_unicode_atom(wordbin, line, col, acc, w, st) do
    case Toxic2.String.Tokenizer.tokenize(wordbin) do
      {kind, name, rest, len, _ascii?, _special} when kind in [:identifier, :alias, :atom] ->
        cont(rest, {:atom, line, col, line, col + 1 + len, name}, acc, uni_w(name, w), st)

      {:error, _reason} ->
        {clen, rest} = ident_run(wordbin)
        err = LexError.new(:unexpected_token, %{})
        cont(rest, {:error, line, col, line, col + 1 + clen, err}, acc, w, st)
    end
  end

  # Tolerant resync for a rejected unicode word (mixed-script, disallowed codepoint, …): emit one
  # `:error` token and consume the whole identifier-ish run so the lexer makes progress.
  defp unicode_error(bin, line, col, acc, w, st) do
    {clen, rest} = ident_run(bin)
    err = LexError.new(:unexpected_token, %{})
    cont(rest, {:error, line, col, line, col + clen, err}, acc, w, st)
  end

  # Codepoint length + remaining binary of the maximal identifier-ish run (ascii word chars and
  # non-ascii codepoints). Used only for error resync, so it errs toward consuming the whole run.
  defp ident_run(<<c, rest::binary>>) when is_word(c) do
    {n, r} = ident_run(rest)
    {n + 1, r}
  end

  defp ident_run(<<cp::utf8, rest::binary>>) when cp > 127 do
    {n, r} = ident_run(rest)
    {n + 1, r}
  end

  defp ident_run(rest), do: {0, rest}

  # An operator name immediately followed by a keyword-separator colon is a keyword KEY —
  # `<<>>:`, `+:`, `.:`, `&:`, `..//:`, `&&&:`, `%{}:`, `{}:` => `[{:"<<>>", _}, ...]`.
  # `::` (`:::`) and `//` are never valid keys.
  defp op_kw_len(bin) do
    case op_atom_len(bin) do
      nil ->
        nil

      len ->
        # the `::` reject is a prefix match (only op_atom_len's dedicated clause yields it at 2);
        # both checks are alloc-free — no `binary_part`/`rest_at` slice per candidate.
        if kw_colon_at?(bin, len) and not match?(<<"::", _::binary>>, bin), do: len, else: nil
    end
  end

  defp emit_op_kw(bin, len, line, col, acc, w, st) do
    tok = {:kw_identifier, line, col, line, col + len + 1, binary_part(bin, 0, len)}
    cont(rest_at(bin, len + 1), tok, acc, w, st)
  end

  # A keyword-key colon is `:` followed by a clear separator (whitespace / closer / EOF).
  # `:` followed by a name char starts an `:atom` operand instead — `&:foo`, `+:erlang` (a capture).
  # Checked AT an offset with a `_::binary-size(len)` skip-match: the compiler advances the match
  # context without building the sub-binary a `kw_colon?(rest_at(bin, len))` peek used to allocate
  # on EVERY operator token just to inspect one or two bytes.
  defp kw_colon_at?(bin, len) do
    case bin do
      <<_::binary-size(^len), ?:, c, _::binary>>
      when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v, ?], ?}, ?), ?,, ?;] ->
        true

      <<_::binary-size(^len), ?:>> ->
        true

      _ ->
        false
    end
  end

  defp lex_operator(bin, line, col, acc, w, st) do
    case match_op(bin) do
      {kind, value, len} ->
        cont(rest_at(bin, len), {kind, line, col, line, col + len, value}, acc, w, st)

      nil ->
        lex_op_error(bin, line, col, acc, w, st)
    end
  end

  # Not an operator: a stray valid codepoint is one `:unexpected_char`, an invalid byte one
  # `:invalid_byte` — each advances a single column (tolerant; never raises).
  defp lex_op_error(<<cp::utf8, rest::binary>>, line, col, acc, w, st) do
    err = LexError.new(:unexpected_char, %{codepoint: cp})
    cont(rest, {:error, line, col, line, col + 1, err}, acc, w, st)
  end

  defp lex_op_error(<<byte, rest::binary>>, line, col, acc, w, st) do
    err = LexError.new(:invalid_byte, %{byte: byte})
    cont(rest, {:error, line, col, line, col + 1, err}, acc, w, st)
  end

  # --- classification of a lowercase word --------------------------------

  # Classify a lowercase word. Generated as direct binary-pattern clauses from the closed-set maps
  # (so BEAM dispatches via a compiled byte trie + catch-all) instead of 4 runtime map lookups per
  # identifier — the common `:identifier` case is the fast fall-through.
  for {name, {kind, atom}} <- @reserved_ops do
    defp lower_token(unquote(name), l, c, n), do: {unquote(kind), l, c, l, c + n, unquote(atom)}
  end

  for {name, kind} <- @terminators do
    defp lower_token(unquote(name), l, c, n), do: {unquote(kind), l, c, l, c + n, nil}
  end

  for {name, value} <- @value_literals do
    defp lower_token(unquote(name), l, c, n),
      do: {:literal, l, c, l, c + n, unquote(value)}
  end

  for {name, atom} <- @block_labels do
    defp lower_token(unquote(name), l, c, n),
      do: {:block_label, l, c, l, c + n, unquote(atom)}
  end

  # `__aliases__` / `__block__` are reserved (they name AST nodes) and cannot be used as plain
  # identifiers; emit a lexer error (tolerant: the parser reports it and recovers).
  defp lower_token(name, l, c, n) when name in ["__aliases__", "__block__"],
    do: {:error, l, c, l, c + n, LexError.new(:reserved_token, %{name: name})}

  defp lower_token(name, l, c, n), do: {:identifier, l, c, l, c + n, name}

  # `foo:` keyword key iff a single `:` follows (not `::`). Works for reserved words too
  # (`do:` is a keyword key, not the `do` terminator).
  # A keyword key colon must be followed by `is_space` (space/tab/CR/LF) — `foo:bar`/`foo:1`/`foo:`
  # at EOF are rejected by Elixir ("keyword argument must be followed by space"). `foo::` is the
  # type operator, never a keyword.
  # Char-literal codepoints Elixir suggests writing with a named escape (`? `→`?\s`, raw tab, …):
  # null/alert/bs/tab/lf/vt/ff/cr/esc/space/del. Applies to `?<c>` and `?\<c>` alike.
  @named_escape_chars [0, 7, 8, 9, 10, 11, 12, 13, 27, 32, 127]

  # `?\<c>` value: the fixed escapes as generated clauses (mirrors `esc/1`), any other char is
  # itself.
  for {e, v} <- @char_escapes do
    defp char_escape_value(unquote(e)), do: unquote(v)
  end

  defp char_escape_value(e), do: e

  # `?\X` warnings: `X` a special char that has a named escape (`?\<space>`) → use `?\s`; or `X` an
  # ASCII letter that ISN'T a recognised escape (`?\q`, `?\x`) → use `?X`. Digits/punctuation don't.
  defp char_escape_notice(e, line, col, len, w) when e in @named_escape_chars,
    do: [{:lexer, :warning, :unusual_char_literal, {line, col, line, col + len}, %{char: e}} | w]

  defp char_escape_notice(e, line, col, len, w)
       when (e in ?a..?z or e in ?A..?Z) and not is_map_key(@char_escapes, e),
       do: [
         {:lexer, :warning, :unknown_char_escape, {line, col, line, col + len}, %{char: e}} | w
       ]

  defp char_escape_notice(_e, _line, _col, _len, w), do: w

  # A bare `?<c>` where `c` is a control/space char Elixir suggests writing with a named escape.
  defp unusual_char_notice(cp, line, col, len, w) when cp in @named_escape_chars,
    do: [{:lexer, :warning, :unusual_char_literal, {line, col, line, col + len}, %{char: cp}} | w]

  defp unusual_char_notice(_cp, _line, _col, _len, w), do: w

  # Look back past any `:eol` tokens (newlines fold into a preceding `;` in Elixir) for a `;`.
  defp prev_semicolon?([{:eol, _, _, _, _, _} | rest]), do: prev_semicolon?(rest)
  defp prev_semicolon?([{:";", _, _, _, _, _} | _]), do: true
  defp prev_semicolon?(_), do: false

  defp kw_suffix(<<?:, ?:, _::binary>>), do: :no

  defp kw_suffix(<<?:, c, _::binary>> = bin) when c in [?\s, ?\t, ?\r, ?\n],
    do: {:kw, rest_at(bin, 1)}

  defp kw_suffix(<<?:, _::binary>> = bin), do: {:kw_nospace, rest_at(bin, 1)}
  defp kw_suffix(_), do: :no

  # An `@` at the boundary may still make a keyword key (`foo@bar:` — the FULL atom-shaped name is
  # the key, R5); otherwise `word@` is an invalid identifier (R15; a `!`/`?` suffix is a real token
  # boundary — `foo!@x` is a call with an `@x` arg). The extended re-scan runs only on this rare
  # `@` path, keeping the per-identifier fast path single-scan.
  defp lex_lower_at(bin, name, after_name, len, line, col, acc, w, st) do
    case kw_name(bin) do
      {:kw, klen, kname, rest, nospace?} ->
        acc = if nospace?, do: kw_nospace_error(kname, line, col, klen, acc), else: acc
        cont(rest, {:kw_identifier, line, col, line, col + klen + 1, kname}, acc, w, st)

      :no ->
        acc = at_in_name_error(name, after_name, line, col, len, acc)
        cont(after_name, lower_token(name, line, col, len), acc, w, st)
    end
  end

  # `Foo!:` / `Foo?:` / `Foo@bar:` — the alias scanner stops before `!`/`?`/`@`, so only those
  # boundaries can still form an atom-shaped keyword key (R5); everything else is a plain alias.
  defp lex_upper_bang(bin, after_name, len, line, col, acc, w, st) do
    case kw_name(bin) do
      {:kw, klen, kname, rest, nospace?} ->
        acc = if nospace?, do: kw_nospace_error(kname, line, col, klen, acc), else: acc
        cont(rest, {:kw_identifier, line, col, line, col + klen + 1, kname}, acc, w, st)

      :no ->
        tok = {:alias, line, col, line, col + len, binary_part(bin, 0, len)}
        cont(after_name, tok, acc, w, st)
    end
  end

  # A keyword key reads the FULL atom-shaped name — word chars and `@`, then an optional trailing
  # `?`/`!` — before checking for the colon, mirroring upstream's suffix check ordering: `foo@bar:`
  # and `Foo!:` are ordinary keyword keys even though `foo@bar` / `Foo!` are invalid bare names.
  defp kw_name(bin) do
    {klen, after_name} = read_atom_name(bin)

    case kw_suffix(after_name) do
      {:kw, rest} -> {:kw, klen, binary_part(bin, 0, klen), rest, false}
      {:kw_nospace, rest} -> {:kw, klen, binary_part(bin, 0, klen), rest, true}
      :no -> :no
    end
  end

  defp at_in_name_error(name, <<?@, _::binary>>, line, col, len, acc) do
    if String.ends_with?(name, "!") or String.ends_with?(name, "?") do
      acc
    else
      [{:error, line, col, line, col + len + 1, LexError.new(:invalid_identifier, %{})} | acc]
    end
  end

  defp at_in_name_error(_name, _after, _line, _col, _len, acc), do: acc

  # `foo:bar` — keep the keyword interpretation (tolerant: the tree stays `[foo: bar]`) but record
  # the missing-space error so strict mode rejects it, matching the oracle.
  defp kw_nospace_error(name, line, col, len, acc),
    do: [
      {:error, line, col, line, col + len + 1, LexError.new(:kw_missing_space, %{name: name})}
      | acc
    ]

  # --- longest-match operator lookup -------------------------------------

  # The operator-name length an atom may carry after `:`. Bracket/percent operators (`<<>>`,
  # `%{}`, `{}`, `%`, `..//`) aren't in @op_table, so they're matched first (longest first); `//`
  # alone is NOT a valid atom (`://` is rejected — `//` is only the range step); everything else
  # falls back to the longest-match operator table (`:++`, `:when`, `:|>`, `:.`, ...).
  defp op_atom_len(<<"<<>>", _::binary>>), do: 4
  defp op_atom_len(<<"..//", _::binary>>), do: 4
  defp op_atom_len(<<"%{}", _::binary>>), do: 3
  defp op_atom_len(<<"{}", _::binary>>), do: 2
  defp op_atom_len(<<"%", _::binary>>), do: 1
  defp op_atom_len(<<"::", _::binary>>), do: 2
  defp op_atom_len(<<?/, ?/, _::binary>>), do: nil

  defp op_atom_len(rest) do
    case match_op(rest) do
      {_kind, _value, oplen} -> oplen
      nil -> nil
    end
  end

  # Longest-match operator dispatch as direct binary-prefix clauses generated from `@op_table`,
  # ordered longest-first so the BEAM's binary matcher prefers the longer operator. This replaces a
  # `binary_part` + map lookup per length (which allocated a throwaway sub-binary each try); the
  # generated clauses match bytes directly with zero allocation. `@op_table` stays the single source
  # of truth (it also drives `op_atom_len`/the precedence pin).
  for {str, {kind, value}} <- Enum.sort_by(@op_table, fn {s, _} -> -byte_size(s) end) do
    defp match_op(<<unquote(str), _::binary>>),
      do: {unquote(kind), unquote(value), unquote(byte_size(str))}
  end

  defp match_op(_), do: nil

  # --- shared continuation -----------------------------------------------

  # Continue lexing from `rest`, advancing the cursor to the token's end position.
  defp cont(rest, {_kind, _sl, _sc, el, ec, _v} = token, acc, w, st),
    do: lex(rest, el, ec, [token | acc], w, st)

  # --- quoted literals (phase 10): linear, interpolation-aware -----------
  # Shared scanner for `"..."` (`qk = :dquote`) and `'...'` (`qk = :charlist`). The opener token
  # is emitted in `lex`; this emits `*_fragment` runs (escapes processed) interleaved with
  # `:begin_interpolation` / interpolation tokens / `:end_interpolation`, and a closer. On `#{` it
  # flushes the pending fragment, pushes `{:interp, qk}`, and hands control to `lex`; the matching
  # `}` (recognised in `lex`) emits `:end_interpolation` and resumes the right scanner. Quoted
  # literals MAY span newlines (Elixir accepts `"a\nb"`); only EOF before the closer is
  # unterminated. Escapes (`\n`, `\xHH`, `\u{..}`, line-continuation `\<newline>`, …) are decoded
  # by `decode_escape`. `fs = {line, col}` is the start of the fragment accumulated in `buf`.
  # `lit = {qk, role}` bundles the quote kind (`:dquote`/`:charlist`) and the role (`{:atom|:call|
  # :string, open_line, open_col}`) so the scanner stays within Credo's arity budget; `qk` is
  # destructured locally where the close char / fragment kind is needed.
  defp read_quoted(<<?\\, rest::binary>>, line, col, buf, fs, acc, w, st, lit) do
    {app, rest2, line2, col2, err} = decode_escape(rest, line, col)

    case err do
      nil ->
        read_quoted(rest2, line2, col2, [app | buf], fs, acc, w, st, lit)

      {code, details} ->
        {qk, _role} = lit
        acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
        acc = [{:error, line, col, line2, col2, LexError.new(code, details)} | acc]
        read_quoted(rest2, line2, col2, [app], {line2, col2}, acc, w, st, lit)
    end
  end

  defp read_quoted(<<?#, ?{, rest::binary>>, line, col, buf, fs, acc, w, st, {qk, _role} = lit) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
    acc = [{:begin_interpolation, line, col, line, col + 2, nil} | acc]
    lex(rest, line, col + 2, acc, w, [{:interp, {:quoted, lit}} | st])
  end

  # CRLF is a normal newline kept verbatim (handled before the bare-CR `?break` error below).
  defp read_quoted(<<?\r, ?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, lit),
    do: read_quoted(rest, line + 1, 1, [<<?\r, ?\n>> | buf], fs, acc, w, st, lit)

  defp read_quoted(<<?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, lit),
    do: read_quoted(rest, line + 1, 1, [<<?\n>> | buf], fs, acc, w, st, lit)

  defp read_quoted(<<>>, line, col, buf, fs, acc, w, _st, {qk, _role}) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
    err = {:error, line, col, line, col, LexError.new(:string_missing_terminator, %{})}
    {[{end_kind(qk), line, col, line, col, nil}, err | acc], w}
  end

  # Fast path: slice a maximal run of ordinary printable-ASCII content bytes in ONE `binary_part`
  # instead of one `<<c>>`+cons per char (the dominant string/heredoc allocation — see tprof). The
  # guard also matches the close quote (a printable ASCII byte); the run scanner stops at it, so a
  # 0-length run means "the close is here" and we hand off to `close_quoted`.
  defp read_quoted(<<c, _::binary>> = bin, line, col, buf, fs, acc, w, st, {qk, _role} = lit)
       when c >= 32 and c < 128 and c != ?\\ and c != ?# do
    close = close_char(qk)

    if c == close do
      close_quoted(rest_at(bin, 1), line, col, buf, fs, acc, w, st, lit)
    else
      n = plain_run_len(bin, close, close, 0)

      read_quoted(
        rest_at(bin, n),
        line,
        col + n,
        [binary_part(bin, 0, n) | buf],
        fs,
        acc,
        w,
        st,
        lit
      )
    end
  end

  defp read_quoted(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, {qk, _role} = lit) do
    cond do
      c == close_char(qk) ->
        close_quoted(rest, line, col, buf, fs, acc, w, st, lit)

      # bidi controls and unsupported line breaks (incl. a bare CR) are both rejected in a string
      # (Elixir 1.20 — previously `?break` was a warning); the char is kept for a best-effort tree.
      bidi?(c) or break?(c) ->
        code = if bidi?(c), do: :invalid_bidi, else: :invalid_break
        acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
        acc = [{:error, line, col, line, col + 1, LexError.new(code, %{codepoint: c})} | acc]
        read_quoted(rest, line, col + 1, [<<c::utf8>>], {line, col + 1}, acc, w, st, lit)

      true ->
        {cbin, rest, dc} = gc_step(rest, c, buf)
        read_quoted(rest, line, col + dc, [cbin | buf], fs, acc, w, st, lit)
    end
  end

  # A stray non-UTF-8 byte inside a quoted literal: keep it verbatim and keep scanning (tolerant).
  defp read_quoted(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, lit) do
    read_quoted(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, lit)
  end

  # Close a quoted literal: flush the pending fragment, emit the end token, then decide keyword-key
  # vs literal and emit any quote warning (charlist / single-quote / unnecessary-quote) now that the
  # role and full content are known. `simple?` (no interpolation) is read off `acc` BEFORE flushing
  # — the start token is still at the head only when the literal had a single fragment.
  defp close_quoted(rest, line, col, buf, fs, acc, w, st, {qk, _role} = lit) do
    simple? = single_part?(acc)
    acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
    acc = [{end_kind(qk), line, col, line, col + 1, nil} | acc]
    close_kw_colon(rest, line, col + 1, acc, w, st, lit, simple?, buf)
  end

  defp single_part?([{:string_start, _, _, _, _, _} | _]), do: true
  defp single_part?([{:charlist_start, _, _, _, _, _} | _]), do: true
  defp single_part?(_), do: false

  # A `:` + whitespace after the close quote makes a `:string`-role literal a quoted keyword KEY
  # (`"foo": 1`): emit a `:kw_quote` marker the parser pairs with the preceding literal. A `:` +
  # non-space (not `::`) is the keyword-missing-space error (`"foo":bar`). `:atom`/`:call` roles are
  # never keyword keys, so they fall to the final clause.
  defp close_kw_colon(
         <<?:, c, _::binary>> = rest,
         line,
         col,
         acc,
         w,
         st,
         {_, {:string, _, _}} = lit,
         simple?,
         buf
       )
       when c in [?\s, ?\t, ?\r, ?\n] do
    w = emit_quote_warnings(lit, true, simple?, buf, w)
    tok = {:kw_quote, line, col, line, col + 1, nil}
    lex(rest_at(rest, 1), line, col + 1, [tok | acc], w, st)
  end

  defp close_kw_colon(
         <<?:, c, _::binary>> = rest,
         line,
         col,
         acc,
         w,
         st,
         {_, {:string, _, _}} = lit,
         simple?,
         buf
       )
       when c != ?: do
    w = emit_quote_warnings(lit, true, simple?, buf, w)
    err = {:error, line, col, line, col + 1, LexError.new(:kw_missing_space, %{})}
    tok = {:kw_quote, line, col, line, col + 1, nil}
    lex(rest_at(rest, 1), line, col + 1, [tok, err | acc], w, st)
  end

  defp close_kw_colon(<<?:>>, line, col, acc, w, st, {_, {:string, _, _}} = lit, simple?, buf) do
    w = emit_quote_warnings(lit, true, simple?, buf, w)
    lex(<<>>, line, col + 1, [{:kw_quote, line, col, line, col + 1, nil} | acc], w, st)
  end

  defp close_kw_colon(rest, line, col, acc, w, st, lit, simple?, buf) do
    w = emit_quote_warnings(lit, false, simple?, buf, w)
    lex(rest, line, col, acc, w, st)
  end

  # Quote warnings, mirroring elixir_tokenizer: an atom/call may carry BOTH the single-quote
  # deprecation and an unnecessary-quote note; a keyword takes unnecessary-OR-single-quote (not
  # both); a bare string/charlist only the charlist deprecation. `qk == :charlist` ⟺ single quotes.
  # `unnecessary?/2` is computed lazily per clause so the common bare-double-quoted string (which
  # needs no warning) never touches `buf`.
  defp emit_quote_warnings({qk, {kind, ol, oc}}, is_kw, simple?, buf, w),
    do: quote_warn(kind, qk == :charlist, is_kw, simple?, buf, ol, oc, w)

  defp quote_warn(:atom, single?, _kw, simple?, buf, ol, oc, w) do
    w = if single?, do: qn(:deprecated_quoted_atom, ol, oc, w), else: w
    if unnecessary?(simple?, buf), do: qn(:unnecessary_quoted_atom, ol, oc, w), else: w
  end

  defp quote_warn(:call, single?, _kw, simple?, buf, ol, oc, w) do
    w = if single?, do: qn(:deprecated_quoted_call, ol, oc, w), else: w
    if unnecessary?(simple?, buf), do: qn(:unnecessary_quoted_call, ol, oc, w), else: w
  end

  defp quote_warn(:string, single?, true, simple?, buf, ol, oc, w) do
    cond do
      unnecessary?(simple?, buf) -> qn(:unnecessary_quoted_keyword, ol, oc, w)
      single? -> qn(:deprecated_quoted_keyword, ol, oc, w)
      true -> w
    end
  end

  defp quote_warn(:string, single?, false, _simple?, _buf, ol, oc, w),
    do: if(single?, do: qn(:deprecated_charlist, ol, oc, w), else: w)

  defp qn(code, ol, oc, w), do: [{:lexer, :warning, code, {ol, oc, ol, oc + 1}, %{}} | w]

  # The quotes are unnecessary when the (single-fragment, no-interpolation) content is itself a
  # valid ASCII identifier with no leftover and no `@` — matching elixir_tokenizer's
  # `is_unnecessary_quote/2`.
  defp unnecessary?(false, _buf), do: false

  defp unnecessary?(true, buf),
    do: ascii_identifier?(:erlang.iolist_to_binary(:lists.reverse(buf)))

  # The vendored tokenizer assumes valid UTF-8 (it is total only there), so guard invalid bytes —
  # they are never an unnecessary quote anyway.
  defp ascii_identifier?(content) do
    if String.valid?(content) do
      case Toxic2.String.Tokenizer.tokenize(content) do
        {:identifier, _, "", _, true, special} -> :at not in special
        _ -> false
      end
    else
      false
    end
  end

  defp close_char(:dquote), do: ?"
  defp close_char(:charlist), do: ?'
  defp frag_kind(:dquote), do: :string_fragment
  defp frag_kind(:charlist), do: :charlist_fragment
  defp end_kind(:dquote), do: :string_end
  defp end_kind(:charlist), do: :charlist_end

  # Decode one escape (`rest` is just past the `\`, at `(line, col)` of the backslash). Returns
  # `{appended_bytes, rest_after, line_after, col_after}`. Covers `\xH`/`\xHH` (raw byte),
  # `\x{H..}` and `\uHHHH`/`\u{H..}` (codepoint → UTF-8), the line-continuation `\<newline>` (emits
  # nothing, the newline is swallowed), the fixed one-byte escapes (`\n`, `\t`, …), and a trailing
  # `\` at EOF (kept literal). Tolerant: a malformed `\x`/`\u` falls back to the literal letter.
  defp decode_escape(rest, line, col) do
    case esc(rest) do
      {app, rest2, :newline, err} ->
        {app, rest2, line + 1, 1, err}

      {app, rest2, :sameline, err} ->
        # Column advance counts CODEPOINTS of the consumed escape text (`\é` is 2 columns, not
        # 1 + the 2 UTF-8 bytes of `é`) — a byte count silently shifts every later column.
        consumed = binary_part(rest, 0, byte_size(rest) - byte_size(rest2))
        {app, rest2, line, col + 1 + cp_width(consumed, 0), err}
    end
  end

  # `\x{H..}` — a codepoint (deprecated form). Empty braces (`\x{}`) are invalid.
  # `\x{H..}` was a (deprecated) codepoint form; since Elixir 1.20 it is an ERROR — only `\xHH`
  # (a byte) or `\uHHHH`/`\u{H..}` (a codepoint) are accepted. Consume the braces, then flag it.
  defp esc(<<?x, ?{, rest::binary>>) do
    {_hex, rest2} = take_hex(rest, <<>>)
    {<<>>, drop_rbrace(rest2), :sameline, {:invalid_hex_escape, %{}}}
  end

  defp esc(<<?x, a, b, rest::binary>>) when is_hex(a) and is_hex(b),
    do: {<<hex_val(a) * 16 + hex_val(b)>>, rest, :sameline, nil}

  # `\xH` (a single hex digit) was a byte; since Elixir 1.20 it is an ERROR (use `\xHH`).
  defp esc(<<?x, a, rest::binary>>) when is_hex(a),
    do: {<<>>, rest, :sameline, {:invalid_hex_escape, %{}}}

  # `\x` not followed by a hex digit or `{` (e.g. `\xG`) — invalid (Elixir rejects it).
  defp esc(<<?x, rest::binary>>), do: {<<?x>>, rest, :sameline, {:invalid_hex_escape, %{}}}

  # `\u{H..}` — a codepoint: upstream requires ONE TO SIX hex digits IMMEDIATELY followed by `}`
  # (R6) — `\u{41`, `\u{41x}`, and `\u{0000041}` are all errors, not a silent "A".
  defp esc(<<?u, ?{, rest::binary>>) do
    {hex, rest2} = take_hex(rest, <<>>)

    case rest2 do
      <<?}, rest3::binary>> when hex != <<>> and byte_size(hex) <= 6 ->
        wrap_cp(cp_to_utf8(hex), rest3)

      _ ->
        {<<>>, drop_rbrace(rest2), :sameline, {:invalid_unicode_escape, %{}}}
    end
  end

  defp esc(<<?u, a, b, c, d, rest::binary>>)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d),
       do: wrap_cp(cp_to_utf8(<<a, b, c, d>>), rest)

  # `\u` not followed by 4 hex digits or `{` (e.g. `\uZ`, `\u1F`) — invalid.
  defp esc(<<?u, rest::binary>>), do: {<<?u>>, rest, :sameline, {:invalid_unicode_escape, %{}}}

  defp esc(<<?\r, ?\n, rest::binary>>), do: {<<>>, rest, :newline, nil}
  defp esc(<<?\n, rest::binary>>), do: {<<>>, rest, :newline, nil}

  # The fixed escapes (`\n`, `\t`, `\\`, `\"`, …) as generated clauses returning LITERAL binaries —
  # module constants, shared, zero allocation per escape. The old `<<Map.get(@char_escapes, e, e)
  # ::utf8>>` body paid a UTF-8 decode + a map lookup + a fresh heap binary per escape, and escapes
  # break the plain-run fast path, so escape-dense strings concentrate exactly here.
  for {e, v} <- @char_escapes do
    defp esc(<<unquote(e), rest::binary>>), do: {unquote(<<v>>), rest, :sameline, nil}
  end

  # Any other codepoint after `\` is kept as itself (no escape processing) — but a RAW bidi
  # control or unsupported line break stays forbidden even behind a backslash (R7); the textual
  # `\u202E` escape is unaffected.
  defp esc(<<e::utf8, rest::binary>>) do
    cond do
      bidi?(e) -> {<<e::utf8>>, rest, :sameline, {:invalid_bidi, %{codepoint: e}}}
      break?(e) -> {<<e::utf8>>, rest, :sameline, {:invalid_break, %{codepoint: e}}}
      true -> {<<e::utf8>>, rest, :sameline, nil}
    end
  end

  # Tolerant (totality): `\` before an invalid UTF-8 byte keeps that byte literally (never raise).
  defp esc(<<byte, rest::binary>>), do: {<<byte>>, rest, :sameline, nil}

  defp esc(<<>>), do: {<<?\\>>, <<>>, :sameline, nil}

  # A decoded codepoint: `:error` (out of range / surrogate) becomes an invalid-codepoint diagnostic.
  defp wrap_cp({:ok, bytes}, rest), do: {bytes, rest, :sameline, nil}
  defp wrap_cp(:error, rest), do: {<<>>, rest, :sameline, {:invalid_unicode_codepoint, %{}}}

  defp take_hex(<<c, rest::binary>>, acc) when is_hex(c), do: take_hex(rest, <<acc::binary, c>>)
  defp take_hex(bin, acc), do: {acc, bin}

  defp drop_rbrace(<<?}, rest::binary>>), do: rest
  defp drop_rbrace(bin), do: bin

  defp hex_val(c) when c in ?0..?9, do: c - ?0
  defp hex_val(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_val(c) when c in ?A..?F, do: c - ?A + 10

  # A codepoint from collected hex digits, UTF-8 encoded: `{:ok, bytes}`, or `:error` when the value
  # is out of range (> 0x10FFFF) or a surrogate (which `<<cp::utf8>>` rejects with ArgumentError).
  defp cp_to_utf8(hex) do
    {:ok, <<String.to_integer(hex, 16)::utf8>>}
  rescue
    ArgumentError -> :error
  end

  # An interpolation's matching `}` resumes whatever literal it opened inside (P3: one scanner).
  defp resume_interp({:quoted, lit}, rest, line, col, acc, w, st),
    do: read_quoted(rest, line, col, [], {line, col}, acc, w, st, lit)

  defp resume_interp({:sigil, sm}, rest, line, col, acc, w, st),
    do: read_sigil(rest, line, col, [], {line, col}, acc, w, st, sm)

  defp resume_interp({:heredoc, hc}, rest, line, col, acc, w, st),
    do: read_heredoc(rest, line, col, [], {line, col}, acc, w, st, hc)

  # --- sigils (phase 10): ~name<delim>content<delim>modifiers ------------
  # Unlike `"`/`'`, sigil content is kept RAW at parse time (the sigil macro unescapes later); the
  # ONLY parse-time rewrites are `\<close>` → the delimiter, and — for a lowercase-named sigil —
  # `#{...}` interpolation. Paired delimiters do NOT nest (first unescaped close ends it). The
  # opener token (`:sigil_start`, value = name) is emitted in `lex`; `:sigil_end` carries the
  # trailing modifier letters (value = binary). `sm = {close_char, interp?}`.

  # `\<close>` → literal delimiter (drop the backslash). In a NON-interpolating (uppercase) sigil
  # this is the deprecated way to escape the closing delimiter — Elixir warns; in a lowercase sigil
  # `\<close>` is a normal escape, no warning.
  defp read_sigil(<<?\\, c, rest::binary>>, line, col, buf, fs, acc, w, st, {close, interp?} = sm)
       when c == close do
    w =
      if interp?,
        do: w,
        else: [{:lexer, :warning, :deprecated_sigil_escape, {line, col, line, col + 2}, %{}} | w]

    read_sigil(rest, line, col + 2, [<<c::utf8>> | buf], fs, acc, w, st, sm)
  end

  # any other `\x` is kept verbatim (no parse-time unescape for sigils). The escaped char is a
  # full CODEPOINT (`~s/\é/` keeps `é`'s bytes as-is — re-encoding its lead byte with `::utf8`
  # would corrupt the content); a `\` before an invalid UTF-8 byte keeps that byte verbatim.
  defp read_sigil(<<?\\, c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, sm)
       when c != ?\n and c != ?\r do
    acc =
      if bidi?(c) or break?(c) do
        code = if bidi?(c), do: :invalid_bidi, else: :invalid_break
        [{:error, line, col, line, col + 2, LexError.new(code, %{codepoint: c})} | acc]
      else
        acc
      end

    read_sigil(rest, line, col + 2, [<<c::utf8>>, <<?\\>> | buf], fs, acc, w, st, sm)
  end

  defp read_sigil(<<?\\, b, rest::binary>>, line, col, buf, fs, acc, w, st, sm)
       when b != ?\n and b != ?\r,
       do: read_sigil(rest, line, col + 2, [<<b>>, <<?\\>> | buf], fs, acc, w, st, sm)

  # interpolation, lowercase sigils only.
  defp read_sigil(<<?#, ?{, rest::binary>>, line, col, buf, fs, acc, w, st, {_close, true} = sm) do
    acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
    acc = [{:begin_interpolation, line, col, line, col + 2, nil} | acc]
    lex(rest, line, col + 2, acc, w, [{:interp, {:sigil, sm}} | st])
  end

  # newlines are literal content (non-heredoc sigils may span lines); CRLF before the bare-CR check.
  defp read_sigil(<<?\r, ?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, sm),
    do: read_sigil(rest, line + 1, 1, [<<?\r, ?\n>> | buf], fs, acc, w, st, sm)

  defp read_sigil(<<?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, sm),
    do: read_sigil(rest, line + 1, 1, [<<?\n>> | buf], fs, acc, w, st, sm)

  defp read_sigil(<<>>, line, col, buf, fs, acc, w, _st, _sm) do
    acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
    err = {:error, line, col, line, col, LexError.new(:sigil_missing_terminator, %{})}
    {[{:sigil_end, line, col, line, col, ""}, err | acc], w}
  end

  # Fast path (mirrors `read_quoted`/`read_heredoc`): slice a maximal run of ordinary printable-ASCII
  # content bytes in ONE `binary_part` instead of one `<<c>>`+cons per char. Sigil content was the
  # last hot reader still building its fragment a byte at a time — the BEAM-appropriate version of
  # the bulk-slice win in OTP's JSON encoder / cowlib HTTP parsers (register-SWAR on top is a no-op
  # here: BEAM's binary match context already makes the byte scan allocation-free). `\`/`#`/newline/
  # the close delimiter still end the run (handled by the clauses above + the `c != close` guard).
  defp read_sigil(<<c, _::binary>> = bin, line, col, buf, fs, acc, w, st, {close, _} = sm)
       when c >= 32 and c < 128 and c != ?\\ and c != ?# and c != close do
    n = plain_run_len(bin, close, close, 0)

    read_sigil(
      rest_at(bin, n),
      line,
      col + n,
      [binary_part(bin, 0, n) | buf],
      fs,
      acc,
      w,
      st,
      sm
    )
  end

  defp read_sigil(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, {close, _} = sm) do
    if c == close do
      acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
      {mlen, after_mods} = take_mods(rest, 0)
      mods = binary_part(rest, 0, mlen)
      acc = [{:sigil_end, line, col, line, col + 1 + mlen, mods} | acc]
      lex(after_mods, line, col + 1 + mlen, acc, w, st)
    else
      if bidi?(c) or break?(c) do
        code = if bidi?(c), do: :invalid_bidi, else: :invalid_break
        acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
        acc = [{:error, line, col, line, col + 1, LexError.new(code, %{codepoint: c})} | acc]
        read_sigil(rest, line, col + 1, [<<c::utf8>>], {line, col + 1}, acc, w, st, sm)
      else
        {cbin, rest, dc} = gc_step(rest, c, buf)
        read_sigil(rest, line, col + dc, [cbin | buf], fs, acc, w, st, sm)
      end
    end
  end

  defp read_sigil(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, sm),
    do: read_sigil(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, sm)

  # A sigil name is the run of letters/digits after `~` (single lowercase, or one-or-more
  # uppercase — the oracle judges validity; we just measure the run). Returns its length.
  defp sigil_name(<<c, rest::binary>>, n) when c in ?a..?z or c in ?A..?Z or c in ?0..?9,
    do: sigil_name(rest, n + 1)

  defp sigil_name(_bin, n), do: n

  # Scan a (to-be-dropped) comment for a bidi/break control; emit a lexer error at the first one.
  defp comment_bidi_check(bin, line, col, acc) do
    case find_comment_lint(bin, col) do
      nil -> acc
      {bcol, code} -> [{:error, line, bcol, line, bcol + 1, LexError.new(code, %{})} | acc]
    end
  end

  # A trailing CRLF / LF ends the comment (no error); a BARE CR inside it is a `?break` error.
  defp find_comment_lint(<<?\r, ?\n, _::binary>>, _col), do: nil
  defp find_comment_lint(<<?\n, _::binary>>, _col), do: nil
  defp find_comment_lint(<<>>, _col), do: nil

  defp find_comment_lint(<<c::utf8, rest::binary>>, col) do
    cond do
      bidi?(c) -> {col, :invalid_bidi}
      break?(c) -> {col, :invalid_break}
      true -> find_comment_lint(rest, col + 1)
    end
  end

  # A stray non-UTF-8 byte in a comment: keep scanning (tolerant — never raise).
  defp find_comment_lint(<<_, rest::binary>>, col), do: find_comment_lint(rest, col + 1)

  # A sigil name is either a single lowercase letter or an uppercase letter followed by uppercase
  # letters / digits (`~r`, `~S`, `~A1`); anything else (`~foo`, `~ab`, `~Ab`, `~A1b`) is invalid.
  # Tolerant: emit a lexer error token before the sigil but keep lexing the sigil itself.
  defp sigil_name_check(name, line, col, ncol, acc) do
    if valid_sigil_name?(name),
      do: acc,
      else: [
        {:error, line, col, line, ncol, LexError.new(:invalid_sigil_name, %{name: name})} | acc
      ]
  end

  defp valid_sigil_name?(<<c>>) when c in ?a..?z, do: true
  defp valid_sigil_name?(<<c, rest::binary>>) when c in ?A..?Z, do: upper_digits?(rest)
  defp valid_sigil_name?(_name), do: false

  defp upper_digits?(<<c, rest::binary>>) when c in ?A..?Z or c in ?0..?9, do: upper_digits?(rest)
  defp upper_digits?(<<>>), do: true
  defp upper_digits?(_rest), do: false

  # An uppercase-named sigil is "raw" (no interpolation); a lowercase-named one interpolates.
  defp sigil_interp?(<<c, _::binary>>) when c in ?A..?Z, do: false
  defp sigil_interp?(_name), do: true

  defp sigil_close(?(), do: ?)
  defp sigil_close(?[), do: ?]
  defp sigil_close(?{), do: ?}
  defp sigil_close(?<), do: ?>
  defp sigil_close(c), do: c

  # The delimiter follows the name. A triple `"`/`'` is a sigil heredoc (shares `read_heredoc`,
  # raw mode); a single paired/char delimiter is an ordinary sigil; anything else is a tolerant
  # error. The `:sigil_start` opener is already on `acc`.
  defp begin_sigil(<<a, b, c, rest::binary>>, line, col, acc, w, st, name)
       when a in [?", ?'] and a == b and b == c do
    spec = {a, :raw, sigil_interp?(name), :sigil_end}
    heredoc_body(rest, line, col + 3, acc, w, st, spec)
  end

  defp begin_sigil(<<d, rest::binary>>, line, col, acc, w, st, name)
       when d in [?(, ?[, ?{, ?<, ?/, ?|, ?", ?'] do
    read_sigil(
      rest,
      line,
      col + 1,
      [],
      {line, col + 1},
      acc,
      w,
      st,
      {sigil_close(d), sigil_interp?(name)}
    )
  end

  # A sigil name sitting immediately at EOF (no delimiter at all) is dropped wholesale: the
  # reference tokenizer yields nothing for a trailing `~x` (the program is empty), so we pop the
  # already-emitted `:sigil_start` and stop. A non-EOF invalid delimiter (e.g. `~x `) still errors.
  defp begin_sigil(<<>>, _line, _col, [{:sigil_start, _, _, _, _, _} | acc], w, _st, _name),
    do: {acc, w}

  defp begin_sigil(other, line, col, acc, w, st, _name) do
    err = {:error, line, col, line, col, LexError.new(:invalid_sigil_delimiter, %{})}
    lex(other, line, col, [err | acc], w, st)
  end

  # --- heredocs (phase 10): triple-quoted, indentation-stripped ----------
  # `read_heredoc` scans a `"""` / `'''` body emitting the SAME linear tokens as a string/charlist
  # (so lowering is shared). `hc = {delim_char, mode, interp?, strip, end_kind, outdent_warned?}`: `mode` is
  # `:full` (unescape via @char_escapes, like a string) or `:raw` (keep verbatim, for uppercase
  # sigil heredocs); `strip` is the closing delimiter's indentation, removed from each line's
  # start. The opener and `strip` are computed in `open_heredoc`. A line `\s*<delim>x3` terminates.
  # `\`-newline inside a `:full` heredoc is a line continuation: the newline is dropped from the
  # content, but the NEXT physical line still gets terminator + indentation handling — so route to
  # `heredoc_line_start`. The empty `<<>>` mirrors the string path's `decode_escape`: it vanishes
  # when fragments are concatenated, but keeps the trailing `""` segment an interpolated heredoc
  # ending in `#{…}\<newline>` needs (matching the reference). `:raw` heredocs keep `\` verbatim.
  defp read_heredoc(
         <<?\\, ?\r, ?\n, rest::binary>>,
         line,
         _col,
         buf,
         fs,
         acc,
         w,
         st,
         {_d, :full, _i, _s, _ek, _ow} = hc
       ),
       do: heredoc_line_start(rest, line + 1, [<<>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(
         <<?\\, ?\n, rest::binary>>,
         line,
         _col,
         buf,
         fs,
         acc,
         w,
         st,
         {_d, :full, _i, _s, _ek, _ow} = hc
       ),
       do: heredoc_line_start(rest, line + 1, [<<>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(
         <<?\\, rest::binary>>,
         line,
         col,
         buf,
         fs,
         acc,
         w,
         st,
         {_d, :full, _i, _s, ek, _ow} = hc
       ) do
    {app, rest2, line2, col2, err} = decode_escape(rest, line, col)

    case err do
      nil ->
        read_heredoc(rest2, line2, col2, [app | buf], fs, acc, w, st, hc)

      {code, details} ->
        acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
        acc = [{:error, line, col, line2, col2, LexError.new(code, details)} | acc]
        read_heredoc(rest2, line2, col2, [app], {line2, col2}, acc, w, st, hc)
    end
  end

  # In a raw (`~S"""`) heredoc, a `\` before the full delimiter escapes it: `\"""` keeps `"""` as
  # content (the only escape raw heredocs honour). `:full` heredocs reach `decode_escape` above.
  defp read_heredoc(<<?\\, a, b, c, rest::binary>>, line, col, buf, fs, acc, w, st, hc)
       when a == elem(hc, 0) and b == a and c == a and elem(hc, 1) == :raw do
    read_heredoc(rest, line, col + 4, [<<a, b, c>> | buf], fs, acc, w, st, hc)
  end

  # In a raw (sigil, `~s"""`) heredoc, `\#{` keeps the backslash literal AND suppresses the
  # interpolation: the content is `\#{...}` verbatim (the `~s` macro unescapes later), matching
  # `read_sigil`'s `\<char>` behaviour. `:full` heredocs reach `decode_escape` above instead.
  defp read_heredoc(
         <<?\\, ?#, ?{, rest::binary>>,
         line,
         col,
         buf,
         fs,
         acc,
         w,
         st,
         {_d, :raw, _i, _s, _ek, _ow} = hc
       ),
       do: read_heredoc(rest, line, col + 3, [<<?\\, ?#, ?{>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(
         <<?#, ?{, rest::binary>>,
         line,
         col,
         buf,
         fs,
         acc,
         w,
         st,
         {_d, _m, true, _s, ek, _ow} = hc
       ) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
    acc = [{:begin_interpolation, line, col, line, col + 2, nil} | acc]
    lex(rest, line, col + 2, acc, w, [{:interp, {:heredoc, hc}} | st])
  end

  # CRLF is the line ending (kept verbatim), handled before the bare-CR `?break` error below.
  defp read_heredoc(<<?\r, ?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, hc),
    do: heredoc_line_start(rest, line + 1, [<<?\r, ?\n>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(<<?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, hc),
    do: heredoc_line_start(rest, line + 1, [<<?\n>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(<<>>, line, col, buf, fs, acc, w, _st, {_d, _m, _i, _s, ek, _ow}) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
    err = {:error, line, col, line, col, LexError.new(:heredoc_missing_terminator, %{})}
    {[{ek, line, col, line, col, nil}, err | acc], w}
  end

  # Fast path: slice a maximal run of ordinary printable-ASCII content in ONE `binary_part` (the
  # heredoc terminator and quote chars are only special at line start, so `"`/`'` ARE content here —
  # no `stop` bytes). `\`/`#`/newline still end the run (handled by the clauses above). tprof showed
  # per-char heredoc content reading was ~20% of all lexer allocation.
  defp read_heredoc(<<c, _::binary>> = bin, line, col, buf, fs, acc, w, st, hc)
       when c >= 32 and c < 128 and c != ?\\ and c != ?# do
    n = plain_run_len(bin, 0, 0, 0)

    read_heredoc(
      rest_at(bin, n),
      line,
      col + n,
      [binary_part(bin, 0, n) | buf],
      fs,
      acc,
      w,
      st,
      hc
    )
  end

  defp read_heredoc(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, hc) do
    if bidi?(c) or break?(c) do
      {_d, _m, _i, _s, ek, _ow} = hc
      code = if bidi?(c), do: :invalid_bidi, else: :invalid_break
      acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
      acc = [{:error, line, col, line, col + 1, LexError.new(code, %{codepoint: c})} | acc]
      read_heredoc(rest, line, col + 1, [<<c::utf8>>], {line, col + 1}, acc, w, st, hc)
    else
      {cbin, rest, dc} = gc_step(rest, c, buf)
      read_heredoc(rest, line, col + dc, [cbin | buf], fs, acc, w, st, hc)
    end
  end

  defp read_heredoc(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, hc),
    do: read_heredoc(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, hc)

  # At the start of a body line: the terminator ends the heredoc, otherwise strip the (shared)
  # indentation and keep scanning. Shared by the opener (first line) and the `\n` clause.
  defp heredoc_line_start(rest, line, buf, fs, acc, w, st, {d, _m, _i, strip, _ek, warned?} = hc) do
    # PERF: one scan of the indentation, not three. `heredoc_terminator?` (take_hspace tuple +
    # sub-binary, then a `heredoc_delim3?` match state) followed by `drop_indent` (another tuple +
    # sub-binary) ran per body line; a count-only `hspace_len`, a skip-match at that offset and one
    # `rest_at` do the same work without allocating an intermediate tail per line.
    ws = hspace_len(rest, 0)

    if delim3_at?(rest, ws, d) do
      heredoc_close(rest, line, buf, fs, acc, w, st, hc)
    else
      dropped = min(ws, strip)
      rest2 = rest_at(rest, dropped)
      w2 = outdented_notice(dropped, strip, rest2, line, warned?, w)
      # Upstream warns ONCE per heredoc, at the first outdented line (K15) — latch the flag.
      hc = if w2 != w, do: put_elem(hc, 5, true), else: hc
      read_heredoc(rest2, line, 1 + dropped, buf, fs, acc, w2, st, hc)
    end
  end

  # A content line indented LESS than the closing delimiter (`dropped < strip`, and it isn't a blank
  # line) is an outdented heredoc line — Elixir warns; contents should be indented at least as much
  # as the closing `"""`.
  defp outdented_notice(dropped, strip, rest2, line, false, w) when dropped < strip do
    case rest2 do
      <<?\n, _::binary>> -> w
      <<?\r, _::binary>> -> w
      <<>> -> w
      _ -> [{:lexer, :warning, :outdented_heredoc, {line, 1, line, 1 + dropped}, %{}} | w]
    end
  end

  defp outdented_notice(_dropped, _strip, _rest2, _line, _warned?, w), do: w

  # The closer is `\s*<delim>x3` at the start of a line; consume it and emit the end token.
  defp heredoc_close(rest, line, buf, fs, acc, w, st, {_d, _m, _i, _strip, ek, _ow}) do
    {ws, rest2} = take_hspace(rest, 0)
    <<_::binary-size(3), rest3::binary>> = rest2
    col = 1 + ws
    acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
    {mlen, after_mods, mods} = heredoc_mods(ek, rest3)
    acc = [{ek, line, col, line, col + 3 + mlen, mods} | acc]
    lex(after_mods, line, col + 3 + mlen, acc, w, st)
  end

  # Only a sigil heredoc takes trailing modifier letters after the closing `"""`.
  defp heredoc_mods(:sigil_end, rest) do
    {mlen, after_mods} = take_mods(rest, 0)
    {mlen, after_mods, binary_part(rest, 0, mlen)}
  end

  defp heredoc_mods(_ek, rest), do: {0, rest, nil}

  # Length of the leading spaces/tabs run — count only, no tail (see `heredoc_line_start/8`).
  defp hspace_len(<<c, rest::binary>>, n) when c in [?\s, ?\t], do: hspace_len(rest, n + 1)
  defp hspace_len(_bin, n), do: n

  # A line is the terminator when, after its indentation (`off` bytes), it begins with delimiter*3.
  # The `_::binary-size(off)` skip advances the match context without building the intermediate tail.
  defp delim3_at?(bin, off, d) do
    case bin do
      <<_::binary-size(^off), ^d, ^d, ^d, _::binary>> -> true
      _ -> false
    end
  end

  defp heredoc_delim3?(<<d, d, d, _::binary>>, d), do: true
  defp heredoc_delim3?(<<d, d, d>>, d), do: true
  defp heredoc_delim3?(_bin, _d), do: false

  # A bare `"""` / `'''` heredoc: emit the opener, then open the body. `spec = {delim, mode,
  # interp?, end_kind}` (sigil heredocs reuse `heredoc_body` with a `:sigil_end` spec).
  defp open_heredoc(rest, line, col, acc, w, st, ?") do
    start = {:string_start, line, col, line, col + 3, nil}
    heredoc_body(rest, line, col + 3, [start | acc], w, st, {?", :full, true, :string_end})
  end

  defp open_heredoc(rest, line, col, acc, w, st, ?') do
    start = {:charlist_start, line, col, line, col + 3, nil}
    heredoc_body(rest, line, col + 3, [start | acc], w, st, {?', :full, true, :charlist_end})
  end

  # Consume the rest of the opening line (only whitespace allowed before the newline), pre-scan the
  # body for the closing delimiter's indentation (`strip`), and begin. The opener token is already
  # on `acc`; `col` is just past the opening `"""`.
  defp heredoc_body(rest, line, col, acc, w, st, {delim, mode, interp?, end_kind} = spec) do
    {ows, after_ws} = take_hspace(rest, 0)

    case after_ws do
      <<?\r, ?\n, body::binary>> ->
        heredoc_start_body(body, line, acc, w, st, spec)

      <<?\n, body::binary>> ->
        heredoc_start_body(body, line, acc, w, st, spec)

      _ ->
        # content on the opening line is invalid — tolerant: flag it, scan from here, strip 0.
        err = {:error, line, col, line, col, LexError.new(:heredoc_start_line, %{})}
        hc = {delim, mode, interp?, 0, end_kind, false}
        read_heredoc(rest, line, col + ows, [], {line, col}, [err | acc], w, st, hc)
    end
  end

  defp heredoc_start_body(body, line, acc, w, st, {delim, mode, interp?, end_kind}) do
    strip = heredoc_indent(body, delim, interp?, heredoc_sig_pattern())
    hc = {delim, mode, interp?, strip, end_kind, false}

    # Seed an empty fragment: a heredoc always opens with a fragment, so an immediate `#{…}` keeps
    # the leading `""` the reference emits (`\"\"\"\n#{x}…` => `["", interp, …]`); for ordinary
    # leading text the empty chunk simply merges into the first fragment.
    heredoc_line_start(body, line + 1, [<<>>], {line + 1, 1}, acc, w, st, hc)
  end

  # Pre-scan the body for the closing delimiter's indentation. Interpolation-aware (R3): `#{...}`
  # opens a code region ONLY when the heredoc interpolates (a raw `~S`/`~W` heredoc's literal `#{`
  # is plain text), and inside a real interpolation the brace count ignores braces that sit in
  # nested strings, charlists, comments, and `?{`-style char literals — upstream extracts the
  # interpolation with the tokenizer before stripping indentation. Returns 0 if no terminator.
  # `pat` is the compiled `heredoc_sig_pattern/0` (the `\n`/`\`/`#{` needle), fetched ONCE by the
  # caller and threaded through so the per-line scan never re-reads it from `:persistent_term`.
  defp heredoc_indent(bin, delim, interp?, pat) do
    {ws, after_ws} = take_hspace(bin, 0)

    cond do
      heredoc_delim3?(after_ws, delim) -> ws
      true -> heredoc_indent_skip(after_ws, delim, interp?, pat)
    end
  end

  defp heredoc_indent_skip(bin, delim, interp?, pat) do
    case skip_to_eol(bin, interp?, pat) do
      :eof -> 0
      {rest} -> heredoc_indent(rest, delim, interp?, pat)
    end
  end

  # Scan to the next newline (consumed), entering `#{…}` code regions when interpolation is on.
  defp skip_to_eol(<<>>, _interp?, _pat), do: :eof
  defp skip_to_eol(<<?\n, rest::binary>>, _interp?, _pat), do: {rest}
  # A `\`-newline is a content line continuation, but the closing `"""` still lives on its own
  # physical line — so for the indentation pre-scan it counts as a line boundary, not an escape.
  defp skip_to_eol(<<?\\, ?\r, ?\n, rest::binary>>, _interp?, _pat), do: {rest}
  defp skip_to_eol(<<?\\, ?\n, rest::binary>>, _interp?, _pat), do: {rest}
  defp skip_to_eol(<<?\\, _c, rest::binary>>, interp?, pat), do: skip_to_eol(rest, interp?, pat)

  defp skip_to_eol(<<?#, ?{, rest::binary>>, true, pat) do
    case skip_interp(rest, 1, pat) do
      :eof -> :eof
      {rest2} -> skip_to_eol(rest2, true, pat)
    end
  end

  # Fast path: outside interpolation the only bytes that matter are `\n` / `\` / `#{`, so jump
  # straight to the next one with a C-level `:binary.match` instead of byte-recursing the whole
  # line. The 2-byte `#{` needle means lone `#`s (common in markdown heredocs) are skipped for
  # free; in a RAW heredoc the `#{` clause above doesn't match and the fallback steps past it.
  defp skip_to_eol(<<c, _::binary>> = bin, interp?, pat) when c != ?\n and c != ?\\ and c != ?# do
    case :binary.match(bin, pat) do
      :nomatch -> :eof
      {pos, _} -> skip_to_eol(rest_at(bin, pos), interp?, pat)
    end
  end

  defp skip_to_eol(<<_c, rest::binary>>, interp?, pat), do: skip_to_eol(rest, interp?, pat)

  # Skip a `#{…}` interpolation body during the indentation pre-scan, brace-counting only braces
  # that are CODE: nested strings/charlists (with their own escapes and nested interpolations),
  # comments, and `?{` / `?\{` char literals are consumed without counting. Newlines inside the
  # interpolation are part of it, not heredoc line boundaries. (A sigil or nested heredoc inside
  # the interpolation is not modeled — upstream fully tokenizes here; those stay approximate.)
  defp skip_interp(<<>>, _depth, _pat), do: :eof
  defp skip_interp(<<?}, rest::binary>>, 1, _pat), do: {rest}
  defp skip_interp(<<?}, rest::binary>>, depth, pat), do: skip_interp(rest, depth - 1, pat)
  defp skip_interp(<<?{, rest::binary>>, depth, pat), do: skip_interp(rest, depth + 1, pat)

  defp skip_interp(<<??, ?\\, _c, rest::binary>>, depth, pat), do: skip_interp(rest, depth, pat)

  defp skip_interp(<<??, c, rest::binary>>, depth, pat) when c in [?{, ?}, ?", ?', ?#],
    do: skip_interp(rest, depth, pat)

  defp skip_interp(<<q, rest::binary>>, depth, pat) when q in [?", ?'] do
    case skip_interp_str(rest, q, pat) do
      :eof -> :eof
      {rest2} -> skip_interp(rest2, depth, pat)
    end
  end

  defp skip_interp(<<?#, rest::binary>>, depth, pat) do
    case :binary.match(rest, "\n") do
      :nomatch -> :eof
      {pos, _} -> skip_interp(rest_at(rest, pos + 1), depth, pat)
    end
  end

  defp skip_interp(<<_c, rest::binary>>, depth, pat), do: skip_interp(rest, depth, pat)

  # A string/charlist inside the interpolation: escapes are skipped and a nested `#{…}` recurses.
  defp skip_interp_str(<<>>, _q, _pat), do: :eof
  defp skip_interp_str(<<q, rest::binary>>, q, _pat), do: {rest}

  defp skip_interp_str(<<?\\, _c, rest::binary>>, q, pat), do: skip_interp_str(rest, q, pat)

  defp skip_interp_str(<<?#, ?{, rest::binary>>, q, pat) do
    case skip_interp(rest, 1, pat) do
      :eof -> :eof
      {rest2} -> skip_interp_str(rest2, q, pat)
    end
  end

  defp skip_interp_str(<<_c, rest::binary>>, q, pat), do: skip_interp_str(rest, q, pat)

  defp frag_of(:string_end), do: :string_fragment
  defp frag_of(:charlist_end), do: :charlist_fragment
  defp frag_of(:sigil_end), do: :string_fragment

  # A fragment token is emitted only for a non-empty run, spanning `fs`..(el, ec).
  defp flush_fragment([], _fs, _el, _ec, acc, _kind), do: acc

  # Single-chunk fast path: after the plain-run bulk slicing, most fragments are exactly one
  # binary — use it directly, skipping the reverse + iodata flatten (which would copy it).
  defp flush_fragment([value], {fl, fc}, el, ec, acc, kind) when is_binary(value),
    do: [{kind, fl, fc, el, ec, value} | acc]

  defp flush_fragment(buf, {fl, fc}, el, ec, acc, kind) do
    value = IO.iodata_to_binary(:lists.reverse(buf))
    [{kind, fl, fc, el, ec, value} | acc]
  end

  # Length of a maximal run of ordinary printable-ASCII content bytes (32..127, none of `\`/`#`/the
  # up-to-two `stop` bytes). Newlines and other control bytes (<32) and UTF-8 lead bytes (>=128) end
  # the run too, so a slice of this length is exactly one column per byte. Lets the string/heredoc
  # readers take one `binary_part` per run instead of `<<c>>`+cons per char (toxic-style fast path).
  defp plain_run_len(<<c, rest::binary>>, s1, s2, n)
       when c >= 32 and c < 128 and c != ?\\ and c != ?# and c != s1 and c != s2,
       do: plain_run_len(rest, s1, s2, n + 1)

  defp plain_run_len(_bin, _s1, _s2, n), do: n

  # An atom name: word chars and `@` (`:nonode@nohost`, `:foo@`), then an optional trailing `?`/`!`.
  # Reuse the rest `atom_word_len/2` already returns instead of re-slicing with `rest_at`; the
  # optional trailing `?`/`!` consumes one more byte, whose tail we also reuse.
  defp read_atom_name(bin) do
    case atom_word_len(bin, 0) do
      {wlen, <<p, after_p::binary>>} when p in [??, ?!] -> {wlen + 1, after_p}
      {wlen, rest} -> {wlen, rest}
    end
  end

  defp atom_word_len(<<c, rest::binary>>, n) when is_word(c) or c == ?@,
    do: atom_word_len(rest, n + 1)

  defp atom_word_len(rest, n), do: {n, rest}

  defp rest_at(bin, len), do: binary_part(bin, len, byte_size(bin) - len)

  # The comment text excludes the trailing newline; a CRLF leaves a `\r` just before the `\n` which
  # is also excluded (matching Code, whose `tokenize_comment` stops before `\r\n`).
  # `previous_eol_count` mirrors Elixir: the preceding `:eol` run's newline count, 1 at the start of
  # input, else 0.
  defp comment_notice(rest, drop_len, after_comment, line, col, acc) do
    text_len =
      if drop_len > 0 and binary_part(rest, drop_len - 1, 1) == "\r",
        do: drop_len - 1,
        else: drop_len

    {:comment, line, col, "#" <> binary_part(rest, 0, text_len), comment_previous_eol_count(acc),
     next_eol_count(after_comment, 0)}
  end

  # The comment-collection flag sits at the bottom of the terminator stack (see `do_tokenize/2`).
  defp keep_comments?([flag]) when is_boolean(flag), do: flag
  defp keep_comments?([_frame | st]), do: keep_comments?(st)

  # comment `previous_eol_count` (mirrors Code): the preceding `:eol` run's newline count, 1 at the
  # start of input, else 0.
  defp comment_previous_eol_count([{:eol, _, _, _, _, count} | _]), do: count
  defp comment_previous_eol_count([]), do: 1
  defp comment_previous_eol_count(_), do: 0

  # comment `next_eol_count` (mirrors Code's `next_eol_count/2`): skip spaces/tabs, count newlines,
  # stop at the next token.
  defp next_eol_count(<<?\s, rest::binary>>, count), do: next_eol_count(rest, count)
  defp next_eol_count(<<?\t, rest::binary>>, count), do: next_eol_count(rest, count)
  defp next_eol_count(<<?\r, ?\n, rest::binary>>, count), do: next_eol_count(rest, count + 1)
  defp next_eol_count(<<?\n, rest::binary>>, count), do: next_eol_count(rest, count + 1)
  defp next_eol_count(_rest, count), do: count

  # --- end-of-line coalescing --------------------------------------------

  # The terminal clause emits the `:eol` token and re-enters `lex/6` directly (instead of
  # returning a `{rest, line, col, count}` 4-tuple to `do_eol` — one throwaway tuple per eol run,
  # and eol runs are one of the commonest events in real code). `sl`/`sc` ride along as the token's
  # start position.
  defp do_eol(bin, sl, sc, acc, w, st), do: consume_eols(bin, sl, sc, 0, sl, sc, acc, w, st)

  defp consume_eols(<<"\r\n", rest::binary>>, line, _col, count, sl, sc, acc, w, st),
    do: consume_eols(rest, line + 1, 1, count + 1, sl, sc, acc, w, st)

  defp consume_eols(<<"\n", rest::binary>>, line, _col, count, sl, sc, acc, w, st),
    do: consume_eols(rest, line + 1, 1, count + 1, sl, sc, acc, w, st)

  defp consume_eols(<<c, rest::binary>>, line, col, count, sl, sc, acc, w, st)
       when c in [?\s, ?\t],
       do: consume_eols(rest, line, col + 1, count, sl, sc, acc, w, st)

  defp consume_eols(rest, line, col, count, sl, sc, acc, w, st),
    do: lex(rest, line, col, [{:eol, sl, sc, line, col, count} | acc], w, st)

  # --- scanners ----------------------------------------------------------

  defp word_len(<<c, rest::binary>>, n) when is_word(c), do: word_len(rest, n + 1)
  defp word_len(rest, n), do: {n, rest}

  # Grapheme-cluster step for string/charlist/sigil/heredoc CONTENT columns. Upstream's extract
  # walks the content with `unicode_util:gc`, so one grapheme cluster is ONE column — `"é"` as
  # `e` + U+0301 is one column, and a ZWJ emoji sequence is one column. Takes the ALREADY-DECODED
  # head codepoint `c` and the binary after it, and returns `{cluster_bytes, rest, col_delta}` for
  # the cluster starting (or continuing) at `c`; `col_delta` is 0 when `c` extends the PREVIOUS
  # char's cluster (`prev` = the last codepoint already emitted into the fragment buffer, or nil).
  #
  # PERF: the callers used to hand over `<<c::utf8, rest::binary>>` and the slow path prepended
  # `prev` the same way. Both are real `bs_create_bin` constructions that COPY the whole unconsumed
  # source, so a literal of n unicode chars copied O(n²) bytes (32k `👩‍💻` took 794 ms; it now takes
  # ~11). Nothing here reconstructs a tail: `c` travels as an integer, `unicode_util:gc/1` probes
  # through a chardata list whose tail is the untouched sub-binary, and the new tail is a
  # `binary_part` of `rest`.
  #
  # FAST PATH: no cluster-extending codepoint (combining marks, ZWJ/ZWNJ, variation selectors,
  # regional indicators, …) exists below U+0300, so when both the head codepoint and the next one
  # are below it (ASCII included) no grapheme machinery is needed — one codepoint, one column.
  # This keeps ordinary Latin-supplement text (é, ü, ñ …) off the `unicode_util:gc` path.
  # `rest` is the FIRST argument and every fast clause head matches it, so the caller's match
  # context (it just took `<<c::utf8, rest::binary>>` off the content) flows straight in.
  defp gc_step(<<n, _::binary>> = rest, c, _buf) when c < 0x0300 and n < 0xCC,
    do: {<<c::utf8>>, rest, 1}

  defp gc_step(<<>>, c, _buf) when c < 0x0300, do: {<<c::utf8>>, <<>>, 1}

  defp gc_step(<<n::utf8, _::binary>> = rest, c, _buf) when c < 0x0300 and n < 0x0300,
    do: {<<c::utf8>>, rest, 1}

  defp gc_step(rest, c, buf), do: gc_step_slow(c, rest, buf_last_cp(buf))

  # `[prev, c | rest]` / `[c | rest]` are chardata: `unicode_util:gc/1` walks the leading integers
  # and only decodes into `rest` if the cluster continues there, so the tail is never copied. The
  # binary tail makes them improper lists on purpose (`unicode:chardata()` allows it) — tell
  # dialyzer so it does not flag the cons.
  @dialyzer {:no_improper_lists, gc_step_slow: 3}
  # The consumed byte count is `byte_size(cluster) - byte_size(c)`, because the returned cluster
  # always starts with `c` (in the `prev` case, with `prev` stripped off first).
  defp gc_step_slow(c, rest, prev) do
    clen = utf8_size(c)

    with false <- prev == nil,
         [[^prev | cont] | _] <- uu_gc([prev, c | rest]),
         cbin when is_binary(cbin) <- :unicode.characters_to_binary(cont) do
      {cbin, rest_at(rest, byte_size(cbin) - clen), 0}
    else
      _ ->
        case uu_gc([c | rest]) do
          [gc | _] ->
            cbin = :unicode.characters_to_binary(List.wrap(gc))
            {cbin, rest_at(rest, byte_size(cbin) - clen), 1}

          _ ->
            {<<c::utf8>>, rest, 1}
        end
    end
  end

  defp utf8_size(c) when c < 0x80, do: 1
  defp utf8_size(c) when c < 0x800, do: 2
  defp utf8_size(c) when c < 0x10000, do: 3
  defp utf8_size(_c), do: 4

  # `unicode_util:gc/1` raises/returns `{:error, _}` on invalid trailing bytes; treat that as a
  # single-codepoint cluster upstream of the caller's fallback.
  defp uu_gc(bin) do
    :unicode_util.gc(bin)
  rescue
    _ -> []
  end

  # The last codepoint already flushed into the (iolist, most-recent-first) fragment buffer.
  defp buf_last_cp([]), do: nil
  defp buf_last_cp([<<>> | t]), do: buf_last_cp(t)
  defp buf_last_cp([h | t]) when is_binary(h), do: bin_last_cp(h) || buf_last_cp(t)
  defp buf_last_cp(_), do: nil

  defp bin_last_cp(bin), do: bin_last_cp(bin, byte_size(bin) - 1)
  defp bin_last_cp(_bin, n) when n < 0, do: nil

  defp bin_last_cp(bin, n) do
    case binary_part(bin, n, byte_size(bin) - n) do
      <<c::utf8>> -> c
      _ -> bin_last_cp(bin, n - 1)
    end
  end

  # Codepoint width of a byte slice, for column advance — total over invalid UTF-8: a UTF-8
  # continuation byte (`0x80..0xBF`) rides with its lead byte; every other byte counts as one column.
  defp cp_width(<<c, rest::binary>>, n) when c >= 0x80 and c <= 0xBF, do: cp_width(rest, n)
  defp cp_width(<<_, rest::binary>>, n), do: cp_width(rest, n + 1)
  defp cp_width(<<>>, n), do: n

  # Specialized `take_while`s for the two hot fixed predicates — a direct inline guard avoids the
  # per-byte captured-fun call. Both return `{count, rest}` like `take_while/3`.
  defp take_hspace(<<c, rest::binary>>, n) when c in [?\s, ?\t], do: take_hspace(rest, n + 1)
  defp take_hspace(bin, n), do: {n, bin}

  defp take_mods(<<c, rest::binary>>, n) when mod_char?(c), do: take_mods(rest, n + 1)
  defp take_mods(bin, n), do: {n, bin}

  # One-pass digit-run scan: the maximal `[digit | _]` run length AND Elixir's underscore rule
  # (`_` only *between* digits — no leading/trailing/doubled `_`, non-empty run) fused into a
  # single direct-guard pass returning `{len, ok?, rest}`. Replaces the old run_len +
  # valid_underscores? double pass (each a captured-fun call per byte, plus a validation-only
  # `binary_part` slice per number). `class` is `:hex` or the highest digit byte (`?9`/`?7`/`?1`
  # for dec/oct/bin — all contiguous from `?0`). On a misplaced `_` the run is still consumed in
  # full (the error token spans it), just marked invalid.
  defp digit_run(<<c, rest::binary>>, class, n, _prev)
       when is_integer(class) and c >= ?0 and c <= class,
       do: digit_run(rest, class, n + 1, :digit)

  defp digit_run(<<c, rest::binary>>, :hex, n, _prev) when is_hex(c),
    do: digit_run(rest, :hex, n + 1, :digit)

  defp digit_run(<<?_, rest::binary>>, class, n, :digit), do: digit_run(rest, class, n + 1, :us)
  defp digit_run(<<?_, rest::binary>>, class, n, _prev), do: bad_digit_run(rest, class, n + 1)
  defp digit_run(bin, _class, n, prev), do: {n, prev == :digit, bin}

  defp bad_digit_run(<<c, rest::binary>>, class, n)
       when is_integer(class) and ((c >= ?0 and c <= class) or c == ?_),
       do: bad_digit_run(rest, class, n + 1)

  defp bad_digit_run(<<c, rest::binary>>, :hex, n) when is_hex(c) or c == ?_,
    do: bad_digit_run(rest, :hex, n + 1)

  defp bad_digit_run(bin, _class, n), do: {n, false, bin}

  # Exponent suffix `e[+-]?digits`: returns `{consumed_length, underscores_valid?}`.
  defp scan_exp(<<e, s, d, _::binary>> = bin)
       when e in [?e, ?E] and s in [?+, ?-] and is_digit(d) do
    {dlen, ok, _rest} = digit_run(rest_at(bin, 2), ?9, 0, :start)
    {2 + dlen, ok}
  end

  defp scan_exp(<<e, d, _::binary>> = bin) when e in [?e, ?E] and is_digit(d) do
    {dlen, ok, _rest} = digit_run(rest_at(bin, 1), ?9, 0, :start)
    {1 + dlen, ok}
  end

  defp scan_exp(_bin), do: {0, true}

  defp num_error(bin, len, line, col, acc, w, st) do
    err = LexError.new(:invalid_number, %{})
    cont(rest_at(bin, len), {:error, line, col, line, col + len, err}, acc, w, st)
  end

  # Most numeric literals have no `_`; skip the (allocating) global replace for them. The reject is
  # a plain byte recursion, NOT `:binary.match` — number slices are 2–10 bytes, where the BM scan's
  # per-call setup (~0.7µs under eprof) costs more than walking every byte in the match context.
  defp strip_underscores(bin) do
    if has_underscore?(bin), do: :binary.replace(bin, "_", "", [:global]), else: bin
  end

  defp has_underscore?(<<?_, _::binary>>), do: true
  defp has_underscore?(<<_, rest::binary>>), do: has_underscore?(rest)
  defp has_underscore?(<<>>), do: false

  defp skip_spaces_tabs(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_spaces_tabs(rest)
  defp skip_spaces_tabs(bin), do: bin

  # A single-quoted HEREDOC (`'''...'''`) is a deprecated charlist — Elixir warns, suggesting
  # `~c"""..."""`. (Single-line `'...'` warnings are deferred to `close_quoted`, which knows the
  # role; heredocs are always bare charlists, so the notice is emitted eagerly here.)
  defp charlist_notice(w, _acc, line, col, open_len),
    do: [{:lexer, :warning, :deprecated_charlist, {line, col, line, col + open_len}, %{}} | w]

  # The role of a `"`/`'` literal, for deferred quote warnings: a literal immediately after a `.`
  # is a remote-CALL name (`a."foo"()`), anything else is a bare string (possibly a keyword key).
  defp quote_role([{:dot, _, _, _, _, _} | _], line, col), do: {:call, line, col}
  defp quote_role(_acc, line, col), do: {:string, line, col}

  # A `\`-newline is space-preceded when the `\` (at `col`) sits past the previous token's end on
  # the same line — i.e. horizontal space was consumed between them. Emits a zero-width `:cont`
  # marker (partitioned out of the stream by `Tokens.from_list/1`) so the parser's no-parens-arg
  # check can tell `foo \⏎+1` (=> `foo(+1)`) from the no-space `foo\⏎+1` (=> `foo + 1`).
  defp cont_marker([{_k, _sl, _sc, el, ec, _v} | _] = acc, line, col)
       when el == line and col > ec,
       do: [{:cont, line, col, line, col, nil} | acc]

  defp cont_marker(acc, _line, _col), do: acc

  # `x\⏎<eof>`: upstream's "invalid escape \\ at end of file" (an incomplete editor buffer).
  defp cont_eof_error(acc, line, col),
    do: [{:error, line, col, line, col + 1, LexError.new(:invalid_eof_escape, %{})} | acc]

  # `String.to_float/1` raises on an out-of-range magnitude (e.g. `1.0e309`); keep the lexer total.
  defp safe_to_float(bin) do
    {:ok, String.to_float(bin)}
  rescue
    ArgumentError -> :error
  end

  # `{digit_run class, base}` — the class is `:hex` or the highest digit byte of the radix.
  defp capture_int_scan(<<?0, b, rest::binary>> = num) when b in [?x, ?o, ?b] do
    {class, base} = radix(b)
    {rlen, ok, _after} = digit_run(rest, class, 0, :start)

    if ok and rlen > 0 do
      value = num |> binary_part(2, rlen) |> strip_underscores() |> String.to_integer(base)
      {:ok, 2 + rlen, value}
    else
      {:error, 2 + rlen}
    end
  end

  defp capture_int_scan(num) do
    {ilen, ok, _after} = digit_run(num, ?9, 0, :start)

    if ok do
      {:ok, ilen, num |> binary_part(0, ilen) |> strip_underscores() |> String.to_integer()}
    else
      {:error, ilen}
    end
  end

  defp radix(?x), do: {:hex, 16}
  defp radix(?o), do: {?7, 8}
  defp radix(?b), do: {?1, 2}

  defp delim_kind(?(), do: :"("
  defp delim_kind(?)), do: :")"
  defp delim_kind(?[), do: :"["
  defp delim_kind(?]), do: :"]"
  defp delim_kind(?,), do: :","
end
