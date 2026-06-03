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
  # scanners (`lex/6`, `word_len/2`, `read_name/1`, `consume_eols/4`, `plain_run_len/4`) are
  # deliberately excluded — inlining them risks code growth / worse i-cache. A/B-measured.
  @compile {:inline, rest_at: 2, kw_suffix: 1, kw_colon?: 1, reserved_token: 4}

  @type token :: Toxic2.Token.t()
  @type warning :: term()

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

  @doc """
  Tokenize `source` into `{tokens, warnings}`, both in **source order**.

  `tokens` may contain `:error` tokens (tolerant mode is the only mode — P1). `warnings` is the
  lexer's only out-of-band channel and is always `[]` in phase 2.
  """
  @spec tokenize(binary(), keyword()) :: {[token()], [warning()]}
  def tokenize(source, _opts \\ []) when is_binary(source) do
    {rev_tokens, rev_warnings} = lex(source, 1, 1, [], [], [])
    {:lists.reverse(rev_tokens), :lists.reverse(rev_warnings)}
  end

  # `st` is a terminator stack used ONLY to tell an interpolation-closing `}` (which ends a
  # string interpolation and resumes string scanning) apart from a `}` that closes a `{`. `{`
  # pushes `:brace`; `#{` inside a string pushes `:interp` (see `read_string`). It is NOT the
  # parser's delimiter matcher — unbalanced delimiters are the parser's concern; this only
  # disambiguates the lexer's two meanings of `}`.

  # --- EOF ---------------------------------------------------------------
  defp lex(<<>>, _line, _col, acc, w, _st), do: {acc, w}

  # --- horizontal whitespace ---------------------------------------------
  defp lex(<<c, rest::binary>>, line, col, acc, w, st) when c in [?\s, ?\t],
    do: lex(rest, line, col + 1, acc, w, st)

  # --- end of line (coalesced run, explicit token) -----------------------
  defp lex(<<"\r\n", _::binary>> = bin, line, col, acc, w, st),
    do: do_eol(bin, line, col, acc, w, st)

  defp lex(<<"\n", _::binary>> = bin, line, col, acc, w, st),
    do: do_eol(bin, line, col, acc, w, st)

  # --- comments (dropped unless preserved; phase 2 drops) ----------------
  defp lex(<<?#, rest::binary>>, line, col, acc, w, st) do
    {drop_len, rest2} = take_while(rest, 0, &(&1 != ?\n))
    acc = comment_bidi_check(rest, line, col + 1, acc)
    lex(rest2, line, col + 1 + drop_len, acc, w, st)
  end

  # --- line continuation: a `\` right before a newline joins the lines (no :eol emitted) ----
  defp lex(<<?\\, ?\r, ?\n, rest::binary>>, line, _col, acc, w, st),
    do: lex(rest, line + 1, 1, acc, w, st)

  defp lex(<<?\\, ?\n, rest::binary>>, line, _col, acc, w, st),
    do: lex(rest, line + 1, 1, acc, w, st)

  # --- heredocs: `"""` / `'''` (before the single-quote clauses) ---------
  defp lex(<<?", ?", ?", rest::binary>>, line, col, acc, w, st),
    do: open_heredoc(rest, line, col, acc, w, st, ?")

  defp lex(<<?', ?', ?', rest::binary>>, line, col, acc, w, st),
    do: open_heredoc(rest, line, col, acc, charlist_notice(w, acc, line, col, 3), st, ?')

  # --- quoted literals: linear form (start, fragments, interp, end) ------
  defp lex(<<?", rest::binary>>, line, col, acc, w, st) do
    start = {:string_start, line, col, line, col + 1, nil}
    read_quoted(rest, line, col + 1, [], {line, col + 1}, [start | acc], w, st, :dquote)
  end

  defp lex(<<?', rest::binary>>, line, col, acc, w, st) do
    start = {:charlist_start, line, col, line, col + 1, nil}
    w = charlist_notice(w, acc, line, col, 1)
    read_quoted(rest, line, col + 1, [], {line, col + 1}, [start | acc], w, st, :charlist)
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
  # `?\<newline>` is a valid char (value `\n`) that CONSUMES the newline — the token spans onto the
  # next line, so line state advances and no trailing `:eol` is emitted (matching Elixir). A `\r`
  # escape (`?\<\r>`, incl. before `\n`) is the ordinary one-char case below — value `\r`, no consume.
  defp lex(<<??, ?\\, ?\n, rest::binary>>, line, col, acc, w, st),
    do: cont(rest, {:char, line, col, line + 1, 1, ?\n}, acc, w, st)

  defp lex(<<??, ?\\, e, rest::binary>>, line, col, acc, w, st) do
    value = Map.get(@char_escapes, e, e)
    cont(rest, {:char, line, col, line, col + 3, value}, acc, w, st)
  end

  defp lex(<<??, cp::utf8, rest::binary>>, line, col, acc, w, st),
    do: cont(rest, {:char, line, col, line, col + 2, cp}, acc, w, st)

  # --- numbers: 0x / 0o / 0b ---------------------------------------------
  defp lex(<<?0, b, _::binary>> = bin, line, col, acc, w, st)
       when b in [?x, ?X, ?o, ?O, ?b, ?B] do
    {base, pred} = radix(b)
    {rlen, _rest} = run_len(rest_at(bin, 2), pred)
    digits = binary_part(bin, 2, rlen)

    if rlen > 0 and valid_underscores?(digits, pred) do
      total = 2 + rlen
      value = digits |> strip_underscores() |> String.to_integer(base)
      cont(rest_at(bin, total), {:int, line, col, line, col + total, value}, acc, w, st)
    else
      num_error(bin, 2 + rlen, line, col, acc, w, st)
    end
  end

  # --- numbers: decimal int / float --------------------------------------
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_digit(c) do
    {ilen, after_int} = run_len(bin, &dec?/1)
    int_ok = valid_underscores?(binary_part(bin, 0, ilen), &dec?/1)

    case after_int do
      <<?., d, _::binary>> when is_digit(d) ->
        {flen, _} = run_len(rest_at(bin, ilen + 1), &dec?/1)
        frac_ok = valid_underscores?(binary_part(bin, ilen + 1, flen), &dec?/1)
        {elen, exp_ok} = scan_exp(rest_at(bin, ilen + 1 + flen))
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
          cont(rest_at(bin, ilen), {:int, line, col, line, col + ilen, value}, acc, w, st)
        else
          num_error(bin, ilen, line, col, acc, w, st)
        end
    end
  end

  # --- type operator :: (before the atom `:` clause) ---------------------
  # `:::` is NOT `::` + `:`; it's the atom `:"::"` (a leading `:` taking `::` as its operator
  # name), so the `::` operator must yield when a third `:` follows — the atom clause handles it.
  defp lex(<<?:, ?:, next, _::binary>> = bin, line, col, acc, w, st) when next != ?:,
    do: cont(rest_at(bin, 2), {:type_op, line, col, line, col + 2, :"::"}, acc, w, st)

  defp lex(<<?:, ?:>>, line, col, acc, w, st),
    do: cont(<<>>, {:type_op, line, col, line, col + 2, :"::"}, acc, w, st)

  # --- quoted atoms `:"..."` / `:'...'` (a `:quoted_atom` marker + the quoted literal's tokens) --
  defp lex(<<?:, ?", rest::binary>>, line, col, acc, w, st) do
    marker = {:quoted_atom, line, col, line, col + 1, nil}
    start = {:string_start, line, col + 1, line, col + 2, nil}
    read_quoted(rest, line, col + 2, [], {line, col + 2}, [start, marker | acc], w, st, :dquote)
  end

  defp lex(<<?:, ?', rest::binary>>, line, col, acc, w, st) do
    marker = {:quoted_atom, line, col, line, col + 1, nil}
    start = {:charlist_start, line, col + 1, line, col + 2, nil}
    read_quoted(rest, line, col + 2, [], {line, col + 2}, [start, marker | acc], w, st, :charlist)
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

        cont(
          rest_at(bin, total),
          {:atom, line, col, line, col + total, binary_part(bin, 1, wlen)},
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
  defp lex(<<?&, d, _::binary>> = bin, line, col, acc, w, st) when is_digit(d) do
    {dlen, _} = take_while(rest_at(bin, 1), 0, &is_digit/1)
    total = 1 + dlen
    value = bin |> binary_part(1, dlen) |> String.to_integer()
    cont(rest_at(bin, total), {:capture_int, line, col, line, col + total, value}, acc, w, st)
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

  # --- other single-char delimiters / separators ------------------------
  defp lex(<<c, rest::binary>>, line, col, acc, w, st) when c in [?(, ?), ?[, ?], ?,, ?;],
    do: cont(rest, {delim_kind(c), line, col, line, col + 1, nil}, acc, w, st)

  # --- identifiers (lowercase/_) : kw key, reserved op, literal, or name --
  # If the ascii run flows into a `>127` byte the word is unicode — hand the WHOLE word to the
  # vendored tokenizer (NFC + UTS-39 script checks), so e.g. `café`/`módulo` stay single tokens.
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_lower_start(c) do
    {len, name, after_name} = read_name(bin)

    case after_name do
      <<cp::utf8, _::binary>> when cp > 127 ->
        lex_unicode(bin, line, col, acc, w, st)

      _ ->
        case kw_suffix(after_name) do
          {:kw, rest} ->
            cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)

          :no ->
            cont(after_name, lower_token(name, line, col, len), acc, w, st)
        end
    end
  end

  # --- aliases (Uppercase): kw key or alias ------------------------------
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_upper_start(c) do
    {len, after_name} = word_len(bin, 0)
    name = binary_part(bin, 0, len)

    case after_name do
      <<cp::utf8, _::binary>> when cp > 127 ->
        lex_unicode(bin, line, col, acc, w, st)

      _ ->
        case kw_suffix(after_name) do
          {:kw, rest} ->
            cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)

          :no ->
            cont(after_name, {:alias, line, col, line, col + len, name}, acc, w, st)
        end
    end
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

  defp emit_operator_or_kw(bin, kind, value, len, line, col, acc, w, st) do
    cond do
      # `<<>>:` / `..//:` — atom-shaped operator keys whose full length the table's longest match
      # (`<<` / `..`) would shadow; `%{}`/`{}`/`%`/`::` are handled by earlier `lex/6` clauses.
      sp = atom_op_kw_len(bin) ->
        emit_op_kw(bin, sp, line, col, acc, w, st)

      # a table operator directly followed by a keyword colon is an operator keyword key (`+: 1`),
      # EXCEPT `//` (the ternary step op) which is never an atom/keyword (`a // b: c` is `a // (b: c)`).
      kind != :ternary_op and kw_colon?(rest_at(bin, len)) ->
        emit_op_kw(bin, len, line, col, acc, w, st)

      true ->
        cont(rest_at(bin, len), {kind, line, col, line, col + len, value}, acc, w, st)
    end
  end

  defp atom_op_kw_len(<<"<<>>", rest::binary>>), do: if(kw_colon?(rest), do: 4)
  defp atom_op_kw_len(<<"..//", rest::binary>>), do: if(kw_colon?(rest), do: 4)
  defp atom_op_kw_len(_), do: nil

  # --- unicode identifier/atom tokenization (vendored Toxic2.String.Tokenizer) -----------------
  # The tokenizer returns {kind, nfc_name, rest, codepoint_len, ascii?, special}. `kind` is
  # `:identifier` (usable as a name), `:alias` (Module-like), or `:atom` (unicode-uppercase —
  # valid ONLY as an atom name, not a standalone identifier). Columns advance by codepoint count.

  # Identifier position (start of a word). `:atom`-kind words and tokenizer errors are rejected.
  defp lex_unicode(bin, line, col, acc, w, st) do
    case Toxic2.String.Tokenizer.tokenize(bin) do
      {:identifier, name, rest, len, _ascii?, _special} ->
        emit_unicode_name(:identifier, name, rest, len, line, col, acc, w, st)

      {:alias, name, rest, len, _ascii?, _special} ->
        emit_unicode_name(:alias, name, rest, len, line, col, acc, w, st)

      {:atom, name, rest, len, _ascii?, _special} ->
        # A unicode-uppercase word is valid only as an atom name — `Σ` alone is rejected, but as a
        # keyword KEY it's fine (`[Ólá: 0]` => `[{:Ólá, 0}]`).
        case kw_suffix(rest) do
          {:kw, r} ->
            cont(r, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)

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

  defp emit_unicode_name(kind, name, rest, len, line, col, acc, w, st) do
    case kw_suffix(rest) do
      {:kw, r} ->
        cont(r, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)

      :no ->
        cont(rest, {kind, line, col, line, col + len, name}, acc, w, st)
    end
  end

  # Atom-literal position (`:` already at `col`; `wordbin` is one past the colon). Every word
  # kind — including `:atom` (`:Σ`) — is a valid atom name here.
  defp lex_unicode_atom(wordbin, line, col, acc, w, st) do
    case Toxic2.String.Tokenizer.tokenize(wordbin) do
      {kind, name, rest, len, _ascii?, _special} when kind in [:identifier, :alias, :atom] ->
        cont(rest, {:atom, line, col, line, col + 1 + len, name}, acc, w, st)

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
        if binary_part(bin, 0, len) != "::" and kw_colon?(rest_at(bin, len)), do: len, else: nil
    end
  end

  defp emit_op_kw(bin, len, line, col, acc, w, st) do
    tok = {:kw_identifier, line, col, line, col + len + 1, binary_part(bin, 0, len)}
    cont(rest_at(bin, len + 1), tok, acc, w, st)
  end

  # A keyword-key colon is `:` followed by a clear separator (whitespace / closer / EOF).
  # `:` followed by a name char starts an `:atom` operand instead — `&:foo`, `+:erlang` (a capture).
  defp kw_colon?(<<?:, c, _::binary>>),
    do: c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v, ?], ?}, ?), ?,, ?;]

  defp kw_colon?(<<?:>>), do: true
  defp kw_colon?(_), do: false

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

  defp lower_token(name, l, c, n) do
    cond do
      m = @reserved_ops[name] ->
        reserved_token(m, l, c, n)

      Map.has_key?(@terminators, name) ->
        {@terminators[name], l, c, l, c + n, nil}

      Map.has_key?(@value_literals, name) ->
        {:literal, l, c, l, c + n, @value_literals[name]}

      Map.has_key?(@block_labels, name) ->
        {:block_label, l, c, l, c + n, @block_labels[name]}

      # `__aliases__` / `__block__` are reserved (they name AST nodes) and cannot be used as plain
      # identifiers; emit a lexer error (tolerant: the parser reports it and recovers).
      name in ["__aliases__", "__block__"] ->
        {:error, l, c, l, c + n, LexError.new(:reserved_token, %{name: name})}

      true ->
        {:identifier, l, c, l, c + n, name}
    end
  end

  defp reserved_token({kind, atom}, l, c, n), do: {kind, l, c, l, c + n, atom}

  # `foo:` keyword key iff a single `:` follows (not `::`). Works for reserved words too
  # (`do:` is a keyword key, not the `do` terminator).
  defp kw_suffix(<<?:, ?:, _::binary>>), do: :no
  defp kw_suffix(<<?:, rest::binary>>), do: {:kw, rest}
  defp kw_suffix(_), do: :no

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
  defp read_quoted(<<?\\, rest::binary>>, line, col, buf, fs, acc, w, st, qk) do
    {app, rest2, line2, col2, err} = decode_escape(rest, line, col)

    case err do
      nil ->
        read_quoted(rest2, line2, col2, [app | buf], fs, acc, w, st, qk)

      {code, details} ->
        acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
        acc = [{:error, line, col, line2, col2, LexError.new(code, details)} | acc]
        read_quoted(rest2, line2, col2, [app], {line2, col2}, acc, w, st, qk)
    end
  end

  defp read_quoted(<<?#, ?{, rest::binary>>, line, col, buf, fs, acc, w, st, qk) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
    acc = [{:begin_interpolation, line, col, line, col + 2, nil} | acc]
    lex(rest, line, col + 2, acc, w, [{:interp, {:quoted, qk}} | st])
  end

  defp read_quoted(<<?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, qk),
    do: read_quoted(rest, line + 1, 1, [<<?\n>> | buf], fs, acc, w, st, qk)

  defp read_quoted(<<>>, line, col, buf, fs, acc, w, _st, qk) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
    err = {:error, line, col, line, col, LexError.new(:string_missing_terminator, %{})}
    {[{end_kind(qk), line, col, line, col, nil}, err | acc], w}
  end

  # Fast path: slice a maximal run of ordinary printable-ASCII content bytes in ONE `binary_part`
  # instead of one `<<c>>`+cons per char (the dominant string/heredoc allocation — see tprof). The
  # guard also matches the close quote (a printable ASCII byte); the run scanner stops at it, so a
  # 0-length run means "the close is here" and we hand off to `close_quoted`.
  defp read_quoted(<<c, _::binary>> = bin, line, col, buf, fs, acc, w, st, qk)
       when c >= 32 and c < 128 and c != ?\\ and c != ?# do
    close = close_char(qk)

    if c == close do
      close_quoted(rest_at(bin, 1), line, col, buf, fs, acc, w, st, qk)
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
        qk
      )
    end
  end

  defp read_quoted(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, qk) do
    cond do
      c == close_char(qk) ->
        close_quoted(rest, line, col, buf, fs, acc, w, st, qk)

      bidi?(c) ->
        acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))

        acc = [
          {:error, line, col, line, col + 1, LexError.new(:invalid_bidi, %{codepoint: c})} | acc
        ]

        read_quoted(rest, line, col + 1, [<<c::utf8>>], {line, col + 1}, acc, w, st, qk)

      true ->
        read_quoted(rest, line, col + 1, [<<c::utf8>> | buf], fs, acc, w, st, qk)
    end
  end

  # A stray non-UTF-8 byte inside a quoted literal: keep it verbatim and keep scanning (tolerant).
  defp read_quoted(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, qk) do
    read_quoted(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, qk)
  end

  # Close a quoted literal: flush the pending fragment, emit the end token, then check for a quoted
  # keyword colon. `rest` is the input AFTER the close quote.
  defp close_quoted(rest, line, col, buf, fs, acc, w, st, qk) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
    acc = [{end_kind(qk), line, col, line, col + 1, nil} | acc]
    # A `:` immediately after the close quote (not `::`) makes this a quoted keyword KEY
    # (`"foo": 1`): emit a `:kw_quote` marker the parser pairs with the preceding literal.
    maybe_kw_colon(rest, line, col + 1, acc, w, st)
  end

  defp maybe_kw_colon(<<?:, c, _::binary>> = rest, line, col, acc, w, st) when c != ?: do
    tok = {:kw_quote, line, col, line, col + 1, nil}
    lex(rest_at(rest, 1), line, col + 1, [tok | acc], w, st)
  end

  defp maybe_kw_colon(<<?:>>, line, col, acc, w, st) do
    lex(<<>>, line, col + 1, [{:kw_quote, line, col, line, col + 1, nil} | acc], w, st)
  end

  defp maybe_kw_colon(rest, line, col, acc, w, st), do: lex(rest, line, col, acc, w, st)

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
        {app, rest2, line, col + 1 + (byte_size(rest) - byte_size(rest2)), err}
    end
  end

  # `\x{H..}` — a codepoint (deprecated form). Empty braces (`\x{}`) are invalid.
  defp esc(<<?x, ?{, rest::binary>>) do
    {hex, rest2} = take_hex(rest, <<>>)
    rest3 = drop_rbrace(rest2)

    if hex == <<>>,
      do: {<<>>, rest3, :sameline, {:invalid_hex_escape, %{}}},
      else: wrap_cp(cp_to_utf8(hex), rest3)
  end

  defp esc(<<?x, a, b, rest::binary>>) when is_hex(a) and is_hex(b),
    do: {<<hex_val(a) * 16 + hex_val(b)>>, rest, :sameline, nil}

  defp esc(<<?x, a, rest::binary>>) when is_hex(a), do: {<<hex_val(a)>>, rest, :sameline, nil}

  # `\x` not followed by a hex digit or `{` (e.g. `\xG`) — invalid (Elixir rejects it).
  defp esc(<<?x, rest::binary>>), do: {<<?x>>, rest, :sameline, {:invalid_hex_escape, %{}}}

  # `\u{H..}` — a codepoint. Empty braces / out-of-range / surrogate are invalid.
  defp esc(<<?u, ?{, rest::binary>>) do
    {hex, rest2} = take_hex(rest, <<>>)
    rest3 = drop_rbrace(rest2)

    if hex == <<>>,
      do: {<<>>, rest3, :sameline, {:invalid_unicode_escape, %{}}},
      else: wrap_cp(cp_to_utf8(hex), rest3)
  end

  defp esc(<<?u, a, b, c, d, rest::binary>>)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d),
       do: wrap_cp(cp_to_utf8(<<a, b, c, d>>), rest)

  # `\u` not followed by 4 hex digits or `{` (e.g. `\uZ`, `\u1F`) — invalid.
  defp esc(<<?u, rest::binary>>), do: {<<?u>>, rest, :sameline, {:invalid_unicode_escape, %{}}}

  defp esc(<<?\r, ?\n, rest::binary>>), do: {<<>>, rest, :newline, nil}
  defp esc(<<?\n, rest::binary>>), do: {<<>>, rest, :newline, nil}

  defp esc(<<e::utf8, rest::binary>>),
    do: {<<Map.get(@char_escapes, e, e)::utf8>>, rest, :sameline, nil}

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
  defp resume_interp({:quoted, qk}, rest, line, col, acc, w, st),
    do: read_quoted(rest, line, col, [], {line, col}, acc, w, st, qk)

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

  # `\<close>` → literal delimiter (drop the backslash).
  defp read_sigil(<<?\\, c, rest::binary>>, line, col, buf, fs, acc, w, st, {close, _} = sm)
       when c == close,
       do: read_sigil(rest, line, col + 2, [<<c::utf8>> | buf], fs, acc, w, st, sm)

  # any other `\x` is kept verbatim (no parse-time unescape for sigils).
  defp read_sigil(<<?\\, c, rest::binary>>, line, col, buf, fs, acc, w, st, sm),
    do: read_sigil(rest, line, col + 2, [<<c::utf8>>, <<?\\>> | buf], fs, acc, w, st, sm)

  # interpolation, lowercase sigils only.
  defp read_sigil(<<?#, ?{, rest::binary>>, line, col, buf, fs, acc, w, st, {_close, true} = sm) do
    acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
    acc = [{:begin_interpolation, line, col, line, col + 2, nil} | acc]
    lex(rest, line, col + 2, acc, w, [{:interp, {:sigil, sm}} | st])
  end

  # newlines are literal content (non-heredoc sigils may span lines).
  defp read_sigil(<<?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, sm),
    do: read_sigil(rest, line + 1, 1, [<<?\n>> | buf], fs, acc, w, st, sm)

  defp read_sigil(<<>>, line, col, buf, fs, acc, w, _st, _sm) do
    acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
    err = {:error, line, col, line, col, LexError.new(:sigil_missing_terminator, %{})}
    {[{:sigil_end, line, col, line, col, ""}, err | acc], w}
  end

  defp read_sigil(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, {close, _} = sm) do
    if c == close do
      acc = flush_fragment(buf, fs, line, col, acc, :string_fragment)
      {mlen, after_mods} = take_while(rest, 0, &mod_char?/1)
      mods = binary_part(rest, 0, mlen)
      acc = [{:sigil_end, line, col, line, col + 1 + mlen, mods} | acc]
      lex(after_mods, line, col + 1 + mlen, acc, w, st)
    else
      read_sigil(rest, line, col + 1, [<<c::utf8>> | buf], fs, acc, w, st, sm)
    end
  end

  defp read_sigil(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, sm),
    do: read_sigil(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, sm)

  defp mod_char?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9

  # A sigil name is the run of letters/digits after `~` (single lowercase, or one-or-more
  # uppercase — the oracle judges validity; we just measure the run). Returns its length.
  defp sigil_name(<<c, rest::binary>>, n) when c in ?a..?z or c in ?A..?Z or c in ?0..?9,
    do: sigil_name(rest, n + 1)

  defp sigil_name(_bin, n), do: n

  # Bidirectional formatting controls (Elixir's `?bidi` macro): rejected in comments and strings
  # because they can visually reorder source against its logical meaning (a security hazard).
  defp bidi?(c),
    do: c in [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]

  # Scan a (to-be-dropped) comment's content for a bidi control; emit a lexer error at the first one.
  defp comment_bidi_check(bin, line, col, acc) do
    case find_bidi(bin, col) do
      nil -> acc
      bcol -> [{:error, line, bcol, line, bcol + 1, LexError.new(:invalid_bidi, %{})} | acc]
    end
  end

  defp find_bidi(<<?\n, _::binary>>, _col), do: nil
  defp find_bidi(<<>>, _col), do: nil

  defp find_bidi(<<c::utf8, rest::binary>>, col),
    do: if(bidi?(c), do: col, else: find_bidi(rest, col + 1))

  defp find_bidi(<<_byte, rest::binary>>, col), do: find_bidi(rest, col + 1)

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
  # (so lowering is shared). `hc = {delim_char, mode, interp?, strip, end_kind}`: `mode` is
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
         {_d, :full, _i, _s, _ek} = hc
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
         {_d, :full, _i, _s, _ek} = hc
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
         {_d, :full, _i, _s, ek} = hc
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
         {_d, :raw, _i, _s, _ek} = hc
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
         {_d, _m, true, _s, ek} = hc
       ) do
    acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
    acc = [{:begin_interpolation, line, col, line, col + 2, nil} | acc]
    lex(rest, line, col + 2, acc, w, [{:interp, {:heredoc, hc}} | st])
  end

  defp read_heredoc(<<?\n, rest::binary>>, line, _col, buf, fs, acc, w, st, hc),
    do: heredoc_line_start(rest, line + 1, [<<?\n>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(<<>>, line, col, buf, fs, acc, w, _st, {_d, _m, _i, _s, ek}) do
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

  defp read_heredoc(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, hc),
    do: read_heredoc(rest, line, col + 1, [<<c::utf8>> | buf], fs, acc, w, st, hc)

  defp read_heredoc(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, hc),
    do: read_heredoc(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, hc)

  # At the start of a body line: the terminator ends the heredoc, otherwise strip the (shared)
  # indentation and keep scanning. Shared by the opener (first line) and the `\n` clause.
  defp heredoc_line_start(rest, line, buf, fs, acc, w, st, {d, _m, _i, strip, _ek} = hc) do
    if heredoc_terminator?(rest, d) do
      heredoc_close(rest, line, buf, fs, acc, w, st, hc)
    else
      {dropped, rest2} = drop_indent(rest, strip)
      read_heredoc(rest2, line, 1 + dropped, buf, fs, acc, w, st, hc)
    end
  end

  # The closer is `\s*<delim>x3` at the start of a line; consume it and emit the end token.
  defp heredoc_close(rest, line, buf, fs, acc, w, st, {_d, _m, _i, _strip, ek}) do
    {ws, rest2} = take_while(rest, 0, &(&1 in [?\s, ?\t]))
    <<_::binary-size(3), rest3::binary>> = rest2
    col = 1 + ws
    acc = flush_fragment(buf, fs, line, col, acc, frag_of(ek))
    {mlen, after_mods, mods} = heredoc_mods(ek, rest3)
    acc = [{ek, line, col, line, col + 3 + mlen, mods} | acc]
    lex(after_mods, line, col + 3 + mlen, acc, w, st)
  end

  # Only a sigil heredoc takes trailing modifier letters after the closing `"""`.
  defp heredoc_mods(:sigil_end, rest) do
    {mlen, after_mods} = take_while(rest, 0, &mod_char?/1)
    {mlen, after_mods, binary_part(rest, 0, mlen)}
  end

  defp heredoc_mods(_ek, rest), do: {0, rest, nil}

  # A line is the terminator when, after its indentation, it begins with the delimiter*3.
  defp heredoc_terminator?(line_rest, d) do
    {_ws, after_ws} = take_while(line_rest, 0, &(&1 in [?\s, ?\t]))
    heredoc_delim3?(after_ws, d)
  end

  defp heredoc_delim3?(<<a, b, c, _::binary>>, d), do: a == d and b == d and c == d
  defp heredoc_delim3?(<<a, b, c>>, d), do: a == d and b == d and c == d
  defp heredoc_delim3?(_bin, _d), do: false

  # Drop up to `n` leading spaces/tabs; returns {dropped_count, rest}.
  defp drop_indent(bin, n), do: drop_indent(bin, n, 0)

  defp drop_indent(<<c, rest::binary>>, n, k) when n > 0 and c in [?\s, ?\t],
    do: drop_indent(rest, n - 1, k + 1)

  defp drop_indent(bin, _n, k), do: {k, bin}

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
    {ows, after_ws} = take_while(rest, 0, &(&1 in [?\s, ?\t]))

    case after_ws do
      <<?\r, ?\n, body::binary>> ->
        heredoc_start_body(body, line, acc, w, st, spec)

      <<?\n, body::binary>> ->
        heredoc_start_body(body, line, acc, w, st, spec)

      _ ->
        # content on the opening line is invalid — tolerant: flag it, scan from here, strip 0.
        err = {:error, line, col, line, col, LexError.new(:heredoc_start_line, %{})}
        hc = {delim, mode, interp?, 0, end_kind}
        read_heredoc(rest, line, col + ows, [], {line, col}, [err | acc], w, st, hc)
    end
  end

  defp heredoc_start_body(body, line, acc, w, st, {delim, mode, interp?, end_kind}) do
    strip = heredoc_indent(body, delim, 0)
    hc = {delim, mode, interp?, strip, end_kind}

    # Seed an empty fragment: a heredoc always opens with a fragment, so an immediate `#{…}` keeps
    # the leading `""` the reference emits (`\"\"\"\n#{x}…` => `["", interp, …]`); for ordinary
    # leading text the empty chunk simply merges into the first fragment.
    heredoc_line_start(body, line + 1, [<<>>], {line + 1, 1}, acc, w, st, hc)
  end

  # Pre-scan the body for the closing delimiter's indentation. `depth` tracks `#{...}` nesting so a
  # `"""` inside an interpolation isn't mistaken for the terminator. Returns 0 if none is found.
  defp heredoc_indent(bin, delim, depth) do
    {ws, after_ws} = take_while(bin, 0, &(&1 in [?\s, ?\t]))

    cond do
      depth == 0 and heredoc_delim3?(after_ws, delim) -> ws
      true -> heredoc_indent_skip(after_ws, delim, depth)
    end
  end

  defp heredoc_indent_skip(bin, delim, depth) do
    case skip_to_eol(bin, depth) do
      :eof -> 0
      {rest, depth2} -> heredoc_indent(rest, delim, depth2)
    end
  end

  # Scan to the next newline (consumed), tracking `#{`/brace depth and skipping escaped chars.
  defp skip_to_eol(<<>>, _depth), do: :eof
  defp skip_to_eol(<<?\n, rest::binary>>, depth), do: {rest, depth}
  # A `\`-newline is a content line continuation, but the closing `"""` still lives on its own
  # physical line — so for the indentation pre-scan it counts as a line boundary, not an escape.
  defp skip_to_eol(<<?\\, ?\r, ?\n, rest::binary>>, depth), do: {rest, depth}
  defp skip_to_eol(<<?\\, ?\n, rest::binary>>, depth), do: {rest, depth}
  defp skip_to_eol(<<?\\, _c, rest::binary>>, depth), do: skip_to_eol(rest, depth)
  defp skip_to_eol(<<?#, ?{, rest::binary>>, depth), do: skip_to_eol(rest, depth + 1)
  defp skip_to_eol(<<?{, rest::binary>>, depth) when depth > 0, do: skip_to_eol(rest, depth + 1)
  defp skip_to_eol(<<?}, rest::binary>>, depth) when depth > 0, do: skip_to_eol(rest, depth - 1)
  defp skip_to_eol(<<_c, rest::binary>>, depth), do: skip_to_eol(rest, depth)

  defp frag_of(:string_end), do: :string_fragment
  defp frag_of(:charlist_end), do: :charlist_fragment
  defp frag_of(:sigil_end), do: :string_fragment

  # A fragment token is emitted only for a non-empty run, spanning `fs`..(el, ec).
  defp flush_fragment([], _fs, _el, _ec, acc, _kind), do: acc

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

  # Read an identifier/atom name: word chars + optional single trailing ? or !.
  # `word_len/2` already returns the rest after the word run, so reuse it rather than re-slicing
  # with `rest_at` (a per-identifier sub-binary that tprof flagged); only the name itself needs a
  # slice. The optional trailing `?`/`!` consumes one more byte, whose tail we likewise reuse.
  defp read_name(bin) do
    case word_len(bin, 0) do
      {wlen, <<p, after_p::binary>>} when p in [??, ?!] ->
        {wlen + 1, binary_part(bin, 0, wlen + 1), after_p}

      {wlen, rest} ->
        {wlen, binary_part(bin, 0, wlen), rest}
    end
  end

  # An atom name: word chars and `@` (`:nonode@nohost`, `:foo@`), then an optional trailing `?`/`!`.
  # Reuse the rest `atom_word_len/2` already returns instead of re-slicing with `rest_at` (mirrors
  # `read_name/1`); the optional trailing `?`/`!` consumes one more byte, whose tail we also reuse.
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

  # --- end-of-line coalescing --------------------------------------------

  defp do_eol(bin, sl, sc, acc, w, st) do
    {rest, el, ec, count} = consume_eols(bin, sl, sc, 0)
    lex(rest, el, ec, [{:eol, sl, sc, el, ec, count} | acc], w, st)
  end

  defp consume_eols(<<"\r\n", rest::binary>>, line, _col, count),
    do: consume_eols(rest, line + 1, 1, count + 1)

  defp consume_eols(<<"\n", rest::binary>>, line, _col, count),
    do: consume_eols(rest, line + 1, 1, count + 1)

  defp consume_eols(<<c, rest::binary>>, line, col, count) when c in [?\s, ?\t],
    do: consume_eols(rest, line, col + 1, count)

  defp consume_eols(rest, line, col, count), do: {rest, line, col, count}

  # --- scanners ----------------------------------------------------------

  defp word_len(<<c, rest::binary>>, n) when is_word(c), do: word_len(rest, n + 1)
  defp word_len(rest, n), do: {n, rest}

  defp take_while(<<c, rest::binary>> = bin, n, pred) do
    if pred.(c), do: take_while(rest, n + 1, pred), else: {n, bin}
  end

  defp take_while(<<>>, n, _pred), do: {n, <<>>}

  # Length of the maximal `[digit | _]` run (`pred` is digit-only; `_` is allowed here and
  # validated separately by `valid_underscores?/2`).
  defp run_len(bin, pred, n \\ 0)

  defp run_len(<<c, rest::binary>> = bin, pred, n) do
    if pred.(c) or c == ?_, do: run_len(rest, pred, n + 1), else: {n, bin}
  end

  defp run_len(<<>>, _pred, n), do: {n, <<>>}

  # Elixir's underscore rule: `_` only *between* digits — no leading/trailing/doubled `_`, and
  # the run must be non-empty. Prevents both crashes (empty → `String.to_integer`) and silently
  # accepting `1_`, `1__2`, `0x_F`, `1.2_`.
  defp valid_underscores?(<<>>, _pred), do: false
  defp valid_underscores?(slice, pred), do: valid_us(slice, pred, :start)

  defp valid_us(<<>>, _pred, prev), do: prev == :digit

  defp valid_us(<<c, rest::binary>>, pred, prev) do
    cond do
      pred.(c) -> valid_us(rest, pred, :digit)
      c == ?_ and prev == :digit -> valid_us(rest, pred, :us)
      true -> false
    end
  end

  # Exponent suffix `e[+-]?digits`: returns `{consumed_length, underscores_valid?}`.
  defp scan_exp(<<e, s, d, _::binary>> = bin)
       when e in [?e, ?E] and s in [?+, ?-] and is_digit(d) do
    {dlen, _} = run_len(rest_at(bin, 2), &dec?/1)
    {2 + dlen, valid_underscores?(binary_part(bin, 2, dlen), &dec?/1)}
  end

  defp scan_exp(<<e, d, _::binary>> = bin) when e in [?e, ?E] and is_digit(d) do
    {dlen, _} = run_len(rest_at(bin, 1), &dec?/1)
    {1 + dlen, valid_underscores?(binary_part(bin, 1, dlen), &dec?/1)}
  end

  defp scan_exp(_bin), do: {0, true}

  defp num_error(bin, len, line, col, acc, w, st) do
    err = LexError.new(:invalid_number, %{})
    cont(rest_at(bin, len), {:error, line, col, line, col + len, err}, acc, w, st)
  end

  defp strip_underscores(bin), do: :binary.replace(bin, "_", "", [:global])

  defp skip_spaces_tabs(<<c, rest::binary>>) when c in [?\s, ?\t], do: skip_spaces_tabs(rest)
  defp skip_spaces_tabs(bin), do: bin

  # A bare single-quoted string (`'...'`, `'''...'''`) is a deprecated charlist — Elixir warns,
  # suggesting `~c"..."` / `""`. Recorded as an id-less lexer notice on the out-of-band channel
  # (numbered at the parse boundary). A single-quoted REMOTE-CALL name (`a.'foo'`) is preceded by a
  # `.` and gets its own deprecation (backlog), so it is skipped here.
  defp charlist_notice(w, [{:dot, _, _, _, _, _} | _], _line, _col, _len), do: w

  defp charlist_notice(w, _acc, line, col, open_len),
    do: [{:lexer, :warning, :deprecated_charlist, {line, col, line, col + open_len}, %{}} | w]

  # `String.to_float/1` raises on an out-of-range magnitude (e.g. `1.0e309`); keep the lexer total.
  defp safe_to_float(bin) do
    {:ok, String.to_float(bin)}
  rescue
    ArgumentError -> :error
  end

  defp radix(b) when b in [?x, ?X], do: {16, &hex?/1}
  defp radix(b) when b in [?o, ?O], do: {8, &oct?/1}
  defp radix(b) when b in [?b, ?B], do: {2, &bin?/1}

  defp dec?(c), do: c in ?0..?9
  defp hex?(c), do: c in ?0..?9 or c in ?a..?f or c in ?A..?F
  defp oct?(c), do: c in ?0..?7
  defp bin?(c), do: c in [?0, ?1]

  defp delim_kind(?(), do: :"("
  defp delim_kind(?)), do: :")"
  defp delim_kind(?[), do: :"["
  defp delim_kind(?]), do: :"]"
  defp delim_kind(?,), do: :","
  defp delim_kind(?;), do: :";"
end
