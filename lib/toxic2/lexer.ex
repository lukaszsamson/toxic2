defmodule Toxic2.Lexer do
  @moduledoc """
  Batch lexer (see `TOXIC_2.md` → Migration Phases #1–#2).

  Phase 2 rounds out the **non-string** lexicon: numbers (int/float, `0x`/`0o`/`0b`), char
  literals, atoms, keyword keys, `true`/`false`/`nil`, the full operator family set, `<<`/`>>`,
  `%`, and comments. Strings / heredocs / sigils / interpolation are intentionally **deferred to
  phase 10** (the spec's dedicated phase): a partial string lexer that ignored interpolation
  would freeze a wrong token contract, so we do them whole or not at all.

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
    {rev_tokens, rev_warnings} = lex(source, 1, 1, [], [])
    {:lists.reverse(rev_tokens), :lists.reverse(rev_warnings)}
  end

  # --- EOF ---------------------------------------------------------------
  defp lex(<<>>, _line, _col, acc, w), do: {acc, w}

  # --- horizontal whitespace ---------------------------------------------
  defp lex(<<c, rest::binary>>, line, col, acc, w) when c in [?\s, ?\t],
    do: lex(rest, line, col + 1, acc, w)

  # --- end of line (coalesced run, explicit token) -----------------------
  defp lex(<<"\r\n", _::binary>> = bin, line, col, acc, w), do: do_eol(bin, line, col, acc, w)
  defp lex(<<"\n", _::binary>> = bin, line, col, acc, w), do: do_eol(bin, line, col, acc, w)

  # --- comments (dropped unless preserved; phase 2 drops) ----------------
  defp lex(<<?#, rest::binary>>, line, col, acc, w) do
    {drop_len, rest2} = take_while(rest, 0, &(&1 != ?\n))
    lex(rest2, line, col + 1 + drop_len, acc, w)
  end

  # --- char literals: ?\<esc> and ?<codepoint> ---------------------------
  defp lex(<<??, ?\\, e, rest::binary>>, line, col, acc, w) do
    value = Map.get(@char_escapes, e, e)
    cont(rest, {:char, line, col, line, col + 3, value}, acc, w)
  end

  defp lex(<<??, cp::utf8, rest::binary>>, line, col, acc, w),
    do: cont(rest, {:char, line, col, line, col + 2, cp}, acc, w)

  # --- numbers: 0x / 0o / 0b ---------------------------------------------
  defp lex(<<?0, b, _::binary>> = bin, line, col, acc, w) when b in [?x, ?X, ?o, ?O, ?b, ?B] do
    {base, pred} = radix(b)
    {rlen, _rest} = run_len(rest_at(bin, 2), pred)
    digits = binary_part(bin, 2, rlen)

    if rlen > 0 and valid_underscores?(digits, pred) do
      total = 2 + rlen
      value = digits |> strip_underscores() |> String.to_integer(base)
      cont(rest_at(bin, total), {:int, line, col, line, col + total, value}, acc, w)
    else
      num_error(bin, 2 + rlen, line, col, acc, w)
    end
  end

  # --- numbers: decimal int / float --------------------------------------
  defp lex(<<c, _::binary>> = bin, line, col, acc, w) when is_digit(c) do
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
          cont(rest_at(bin, total), {:flt, line, col, line, col + total, value}, acc, w)
        else
          num_error(bin, total, line, col, acc, w)
        end

      _ ->
        if int_ok do
          value = bin |> binary_part(0, ilen) |> strip_underscores() |> String.to_integer()
          cont(rest_at(bin, ilen), {:int, line, col, line, col + ilen, value}, acc, w)
        else
          num_error(bin, ilen, line, col, acc, w)
        end
    end
  end

  # --- type operator :: (before the atom `:` clause) ---------------------
  defp lex(<<"::", rest::binary>>, line, col, acc, w),
    do: cont(rest, {:type_op, line, col, line, col + 2, :"::"}, acc, w)

  # --- atoms: :name and :<operator> (quoted atoms deferred to phase 10) --
  defp lex(<<?:, c, _::binary>> = bin, line, col, acc, w)
       when is_lower_start(c) or is_upper_start(c) do
    {wlen, _name, _rest} = read_name(rest_at(bin, 1))
    total = 1 + wlen

    cont(
      rest_at(bin, total),
      {:atom, line, col, line, col + total, binary_part(bin, 1, wlen)},
      acc,
      w
    )
  end

  defp lex(<<?:, rest::binary>> = bin, line, col, acc, w) do
    case match_op(rest) do
      {_kind, _value, oplen} ->
        total = 1 + oplen

        cont(
          rest_at(bin, total),
          {:atom, line, col, line, col + total, binary_part(bin, 1, oplen)},
          acc,
          w
        )

      nil ->
        err = LexError.new(:unexpected_colon, %{})
        cont(rest_at(bin, 1), {:error, line, col, line, col + 1, err}, acc, w)
    end
  end

  # --- capture int &1 (before the `&` operator in the table) -------------
  defp lex(<<?&, d, _::binary>> = bin, line, col, acc, w) when is_digit(d) do
    {dlen, _} = take_while(rest_at(bin, 1), 0, &is_digit/1)
    total = 1 + dlen
    value = bin |> binary_part(1, dlen) |> String.to_integer()
    cont(rest_at(bin, total), {:capture_int, line, col, line, col + total, value}, acc, w)
  end

  # --- percent (parser combines with `{`/alias for maps/structs) ---------
  defp lex(<<?%, rest::binary>>, line, col, acc, w),
    do: cont(rest, {:percent, line, col, line, col + 1, nil}, acc, w)

  # --- single-char delimiters / separators -------------------------------
  defp lex(<<c, rest::binary>>, line, col, acc, w) when c in [?(, ?), ?[, ?], ?{, ?}, ?,, ?;],
    do: cont(rest, {delim_kind(c), line, col, line, col + 1, nil}, acc, w)

  # --- identifiers (lowercase/_) : kw key, reserved op, literal, or name --
  defp lex(<<c, _::binary>> = bin, line, col, acc, w) when is_lower_start(c) do
    {len, name, after_name} = read_name(bin)

    case kw_suffix(after_name) do
      {:kw, rest} ->
        cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w)

      :no ->
        cont(rest_at(bin, len), lower_token(name, line, col, len), acc, w)
    end
  end

  # --- aliases (Uppercase): kw key or alias ------------------------------
  defp lex(<<c, _::binary>> = bin, line, col, acc, w) when is_upper_start(c) do
    {len, _} = word_len(bin, 0)
    name = binary_part(bin, 0, len)

    case kw_suffix(rest_at(bin, len)) do
      {:kw, rest} ->
        cont(rest, {:kw_identifier, line, col, line, col + len + 1, name}, acc, w)

      :no ->
        cont(rest_at(bin, len), {:alias, line, col, line, col + len, name}, acc, w)
    end
  end

  # --- operators (longest match) + tolerant UTF-8/byte error fallback ----
  defp lex(bin, line, col, acc, w) do
    case match_op(bin) do
      {kind, value, len} ->
        cont(rest_at(bin, len), {kind, line, col, line, col + len, value}, acc, w)

      nil ->
        case bin do
          <<cp::utf8, rest::binary>> ->
            err = LexError.new(:unexpected_char, %{codepoint: cp})
            cont(rest, {:error, line, col, line, col + 1, err}, acc, w)

          <<byte, rest::binary>> ->
            err = LexError.new(:invalid_byte, %{byte: byte})
            cont(rest, {:error, line, col, line, col + 1, err}, acc, w)
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
  defp cont(rest, {_kind, _sl, _sc, el, ec, _v} = token, acc, w),
    do: lex(rest, el, ec, [token | acc], w)

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

  defp do_eol(bin, sl, sc, acc, w) do
    {rest, el, ec, count} = consume_eols(bin, sl, sc, 0)
    lex(rest, el, ec, [{:eol, sl, sc, el, ec, count} | acc], w)
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

  defp num_error(bin, len, line, col, acc, w) do
    err = LexError.new(:invalid_number, %{})
    cont(rest_at(bin, len), {:error, line, col, line, col + len, err}, acc, w)
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
  defp delim_kind(?{), do: :"{"
  defp delim_kind(?}), do: :"}"
  defp delim_kind(?,), do: :","
  defp delim_kind(?;), do: :";"
end
