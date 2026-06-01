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
  operator-named atoms (`:<<>>`, `:%{}`, `:..//`), and `\`-newline line continuation in code.
  Not yet lexed: **unicode identifiers/atoms** (needs Unicode XID + NFC) and **operator-named
  keyword keys** (`<<>>: 1`).

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
    do: open_heredoc(rest, line, col, acc, w, st, ?')

  # --- quoted literals: linear form (start, fragments, interp, end) ------
  defp lex(<<?", rest::binary>>, line, col, acc, w, st) do
    start = {:string_start, line, col, line, col + 1, nil}
    read_quoted(rest, line, col + 1, [], {line, col + 1}, [start | acc], w, st, :dquote)
  end

  defp lex(<<?', rest::binary>>, line, col, acc, w, st) do
    start = {:charlist_start, line, col, line, col + 1, nil}
    read_quoted(rest, line, col + 1, [], {line, col + 1}, [start | acc], w, st, :charlist)
  end

  # --- sigils: ~name<delim>...<delim>modifiers ---------------------------
  defp lex(<<?~, c, _::binary>> = bin, line, col, acc, w, st)
       when c in ?a..?z or c in ?A..?Z do
    namelen = sigil_name(rest_at(bin, 1), 0)
    name = binary_part(bin, 1, namelen)
    ncol = col + 1 + namelen
    start = {:sigil_start, line, col, line, ncol, name}
    begin_sigil(rest_at(bin, 1 + namelen), line, ncol, [start | acc], w, st, name)
  end

  # --- char literals: ?\<esc> and ?<codepoint> ---------------------------
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

        if int_ok and frac_ok and exp_ok do
          value = bin |> binary_part(0, total) |> strip_underscores() |> String.to_float()
          cont(rest_at(bin, total), {:flt, line, col, line, col + total, value}, acc, w, st)
        else
          num_error(bin, total, line, col, acc, w, st)
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
  defp lex(<<"::", rest::binary>>, line, col, acc, w, st),
    do: cont(rest, {:type_op, line, col, line, col + 2, :"::"}, acc, w, st)

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
  defp lex(<<?:, c, _::binary>> = bin, line, col, acc, w, st)
       when is_lower_start(c) or is_upper_start(c) do
    {wlen, _name, _rest} = read_name(rest_at(bin, 1))
    total = 1 + wlen

    cont(
      rest_at(bin, total),
      {:atom, line, col, line, col + total, binary_part(bin, 1, wlen)},
      acc,
      w,
      st
    )
  end

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
  defp lex(<<?%, rest::binary>>, line, col, acc, w, st),
    do: cont(rest, {:percent, line, col, line, col + 1, nil}, acc, w, st)

  # --- `{` opens a brace frame (so the matching `}` isn't mistaken for an interp close) ---
  defp lex(<<?{, rest::binary>>, line, col, acc, w, st),
    do: cont(rest, {:"{", line, col, line, col + 1, nil}, acc, w, [:brace | st])

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
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_lower_start(c) do
    {len, name, after_name} = read_name(bin)

    case kw_suffix(after_name) do
      {:kw, rest} ->
        cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)

      :no ->
        cont(rest_at(bin, len), lower_token(name, line, col, len), acc, w, st)
    end
  end

  # --- aliases (Uppercase): kw key or alias ------------------------------
  defp lex(<<c, _::binary>> = bin, line, col, acc, w, st) when is_upper_start(c) do
    {len, _} = word_len(bin, 0)
    name = binary_part(bin, 0, len)

    case kw_suffix(rest_at(bin, len)) do
      {:kw, rest} ->
        cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w, st)

      :no ->
        cont(rest_at(bin, len), {:alias, line, col, line, col + len, name}, acc, w, st)
    end
  end

  # --- operators (longest match) + tolerant UTF-8/byte error fallback ----
  defp lex(bin, line, col, acc, w, st) do
    case match_op(bin) do
      {kind, value, len} ->
        cont(rest_at(bin, len), {kind, line, col, line, col + len, value}, acc, w, st)

      nil ->
        case bin do
          <<cp::utf8, rest::binary>> ->
            err = LexError.new(:unexpected_char, %{codepoint: cp})
            cont(rest, {:error, line, col, line, col + 1, err}, acc, w, st)

          <<byte, rest::binary>> ->
            err = LexError.new(:invalid_byte, %{byte: byte})
            cont(rest, {:error, line, col, line, col + 1, err}, acc, w, st)
        end
    end
  end

  # --- classification of a lowercase word --------------------------------

  defp lower_token(name, l, c, n) do
    cond do
      m = @reserved_ops[name] -> reserved_token(m, l, c, n)
      Map.has_key?(@terminators, name) -> {@terminators[name], l, c, l, c + n, nil}
      Map.has_key?(@value_literals, name) -> {:literal, l, c, l, c + n, @value_literals[name]}
      Map.has_key?(@block_labels, name) -> {:block_label, l, c, l, c + n, @block_labels[name]}
      true -> {:identifier, l, c, l, c + n, name}
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
  defp op_atom_len(<<?/, ?/, _::binary>>), do: nil

  defp op_atom_len(rest) do
    case match_op(rest) do
      {_kind, _value, oplen} -> oplen
      nil -> nil
    end
  end

  defp match_op(bin), do: lookup_op(bin, 3) || lookup_op(bin, 2) || lookup_op(bin, 1)

  defp lookup_op(bin, n) when byte_size(bin) >= n do
    case @op_table[binary_part(bin, 0, n)] do
      nil -> nil
      {kind, value} -> {kind, value, n}
    end
  end

  defp lookup_op(_bin, _n), do: nil

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
    {app, rest2, line2, col2} = decode_escape(rest, line, col)
    read_quoted(rest2, line2, col2, [app | buf], fs, acc, w, st, qk)
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

  defp read_quoted(<<c::utf8, rest::binary>>, line, col, buf, fs, acc, w, st, qk) do
    if c == close_char(qk) do
      acc = flush_fragment(buf, fs, line, col, acc, frag_kind(qk))
      acc = [{end_kind(qk), line, col, line, col + 1, nil} | acc]
      # A `:` immediately after the close quote (not `::`) makes this a quoted keyword KEY
      # (`"foo": 1`): emit a `:kw_quote` marker the parser pairs with the preceding literal.
      maybe_kw_colon(rest, line, col + 1, acc, w, st)
    else
      read_quoted(rest, line, col + 1, [<<c::utf8>> | buf], fs, acc, w, st, qk)
    end
  end

  # A stray non-UTF-8 byte inside a quoted literal: keep it verbatim and keep scanning (tolerant).
  defp read_quoted(<<byte, rest::binary>>, line, col, buf, fs, acc, w, st, qk) do
    read_quoted(rest, line, col + 1, [<<byte>> | buf], fs, acc, w, st, qk)
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
      {app, rest2, :newline} ->
        {app, rest2, line + 1, 1}

      {app, rest2, :sameline} ->
        {app, rest2, line, col + 1 + (byte_size(rest) - byte_size(rest2))}
    end
  end

  defp esc(<<?x, ?{, rest::binary>>) do
    {hex, rest2} = take_hex(rest, <<>>)
    {cp_to_utf8(hex), drop_rbrace(rest2), :sameline}
  end

  defp esc(<<?x, a, b, rest::binary>>) when is_hex(a) and is_hex(b),
    do: {<<hex_val(a) * 16 + hex_val(b)>>, rest, :sameline}

  defp esc(<<?x, a, rest::binary>>) when is_hex(a), do: {<<hex_val(a)>>, rest, :sameline}

  defp esc(<<?u, ?{, rest::binary>>) do
    {hex, rest2} = take_hex(rest, <<>>)
    {cp_to_utf8(hex), drop_rbrace(rest2), :sameline}
  end

  defp esc(<<?u, a, b, c, d, rest::binary>>)
       when is_hex(a) and is_hex(b) and is_hex(c) and is_hex(d),
       do: {cp_to_utf8(<<a, b, c, d>>), rest, :sameline}

  defp esc(<<?\r, ?\n, rest::binary>>), do: {<<>>, rest, :newline}
  defp esc(<<?\n, rest::binary>>), do: {<<>>, rest, :newline}

  defp esc(<<e::utf8, rest::binary>>),
    do: {<<Map.get(@char_escapes, e, e)::utf8>>, rest, :sameline}

  defp esc(<<>>), do: {<<?\\>>, <<>>, :sameline}

  defp take_hex(<<c, rest::binary>>, acc) when is_hex(c), do: take_hex(rest, <<acc::binary, c>>)
  defp take_hex(bin, acc), do: {acc, bin}

  defp drop_rbrace(<<?}, rest::binary>>), do: rest
  defp drop_rbrace(bin), do: bin

  defp hex_val(c) when c in ?0..?9, do: c - ?0
  defp hex_val(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_val(c) when c in ?A..?F, do: c - ?A + 10

  # A codepoint from collected hex digits, UTF-8 encoded. Tolerant: empty or out-of-range → "".
  defp cp_to_utf8(<<>>), do: <<>>

  defp cp_to_utf8(hex) do
    <<String.to_integer(hex, 16)::utf8>>
  rescue
    ArgumentError -> <<>>
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
  defp read_heredoc(
         <<?\\, rest::binary>>,
         line,
         col,
         buf,
         fs,
         acc,
         w,
         st,
         {_d, :full, _i, _s, _ek} = hc
       ) do
    {app, rest2, line2, col2} = decode_escape(rest, line, col)
    read_heredoc(rest2, line2, col2, [app | buf], fs, acc, w, st, hc)
  end

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
    heredoc_line_start(body, line + 1, [], {line + 1, 1}, acc, w, st, hc)
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

  # Read an identifier/atom name: word chars + optional single trailing ? or !.
  defp read_name(bin) do
    {wlen, _} = word_len(bin, 0)

    len =
      case rest_at(bin, wlen) do
        <<p, _::binary>> when p in [??, ?!] -> wlen + 1
        _ -> wlen
      end

    {len, binary_part(bin, 0, len), rest_at(bin, len)}
  end

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
