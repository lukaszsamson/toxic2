defmodule Toxic2.Lower do
  @moduledoc """
  CST → Elixir AST lowering (see `TOXIC_2.md` → Lowering; Migration Phases #6).

  This is the **one** pass that knows Elixir AST quirks (P5). The parser builds a structural
  green CST; everything Elixir-AST-specific — variable shape, alias shape, atomization, block
  wrapping, operator nodes — lives here, so a conformance failure localizes cleanly to "CST
  wrong" (parser bug) vs "lowering rule wrong" (here).

  **Totality (P5): lowering NEVER raises.** It returns `{ast, diagnostics}` and threads a
  diagnostic accumulator (the lowerer's channel in the single combined stream — used now for the
  `:existing_atoms_only` atom policy, and reserved for things like the `not in` deprecation).
  Ids continue from `start_id` so they stay unique across lexer + parser + lowerer.

  Atom policy: source-derived names are atomized here (never in the lexer — review #1). With
  `existing_atoms_only: true`, an unknown atom does not raise — it lowers to `{:__error__, ...}`
  plus a `:nonexistent_atom` lowerer diagnostic.
  """

  alias Toxic2.{CST, Diagnostics, Tokens}

  # Sparse grapheme index (see `gc_index/1`): one entry per `@gc_index_step` columns, built only for
  # mixed lines whose non-ASCII tail exceeds `@gc_index_min` bytes.
  @gc_index_step 32
  @gc_index_min 256

  # Narrow inlining of tiny LOCAL meta builders on the hot per-node path (A/B-measured).
  @compile {:inline, tmeta: 2, op_atom: 2, op_meta: 2, span_meta: 1, token_meta: 3}

  # Lower-LOCAL token-view and CST reads (the perf-pass-6 parser pattern): `Tokens.kind/value/
  # token` and `CST.tag/token_index/node_kind/children/span` are cross-module — a callee-module
  # `@compile :inline` can't reach them, and together they were ~13% of lower-stage calls under
  # eprof. These read the view/CST tuples directly and inline into the walkers.
  @compile {:inline, tk: 2, tv: 2, tt: 2, ctag: 1, ctoki: 1, ckind: 1, cchildren: 1, cspan: 1}
  @compile {:inline, range_enabled?: 1, maybe_token_range: 4, with_range: 3, kw_pair?: 1}

  defp tk({toks, size, _cont}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 0)
  defp tk(_t, _i), do: :eof

  defp tv({toks, size, _cont}, i) when i >= 0 and i < size, do: elem(elem(toks, i), 5)
  defp tv(_t, _i), do: nil

  defp tt({toks, size, _cont}, i) when i >= 0 and i < size, do: elem(toks, i)
  defp tt(_t, _i), do: :eof

  defp tspan(t, i) do
    case tt(t, i) do
      :eof -> nil
      tok -> {elem(tok, 1), elem(tok, 2), elem(tok, 3), elem(tok, 4)}
    end
  end

  defp ctag(cst), do: elem(cst, 0)

  defp ctoki({:token, i, _f, _d}), do: i
  defp ctoki(_cst), do: nil

  defp ckind({:node, kind, _sp, _ch, _f, _d}), do: kind
  defp ckind({:missing, expected, _ai, _f, _d}), do: expected
  defp ckind({:token, _i, _f, _d}), do: :token

  defp cchildren({:node, _k, _sp, ch, _f, _d}), do: ch
  defp cchildren(_leaf), do: []

  defp cspan({:node, _k, sp, _ch, _f, _d}), do: sp
  defp cspan(_leaf), do: nil

  @type ast :: Macro.t()

  @doc """
  Lower `cst` to AST. Returns `{ast, lowerer_diagnostics}` (source-ordered). `start_id` is the
  next free diagnostic id (so ids don't collide with lexer/parser diagnostics).
  """
  @spec to_ast(CST.t(), Tokens.t(), String.t(), keyword(), pos_integer()) ::
          {ast(), [Toxic2.Diagnostic.t()]}
  def to_ast(cst, view), do: to_ast(cst, view, "", [], 1)

  # Backward-compatible arities: the original public shape was `to_ast(cst, view, opts, start_id)`
  # (no source). `token_metadata: true` needs the source to scan `delimiter:`/`token:`/`newlines:`,
  # so the 5-arity form threads it; the keyword-`opts` 3/4-arities keep old callers working.
  #
  # These source-less arities are for DEFAULT lowering only. The source-sensitive options
  # (`token_metadata: true`, `range: true`, a source-reading `literal_encoder`) need the source
  # binary and will produce nil/empty metadata here — use the 5-arity form or `Toxic2.parse_to_ast/2`
  # (which always threads the source) when any of those are set.
  def to_ast(cst, view, opts) when is_list(opts), do: to_ast(cst, view, "", opts, 1)

  def to_ast(cst, view, opts, start_id) when is_list(opts) and is_integer(start_id),
    do: to_ast(cst, view, "", opts, start_id)

  def to_ast(cst, view, source, opts, start_id)
      when is_binary(source) and is_list(opts) and is_integer(start_id) do
    {ast, acc, _nid} = lower(cst, view, resolve_opts(opts, source), [], start_id)
    {ast, Diagnostics.to_list(acc)}
  end

  # Resolve the (keyword) options ONCE into a compact map threaded through lowering, so per-node
  # checks are a map field read (`opts.range`) instead of a `Keyword.get` keyfind over the option
  # list on every node (tprof: that keyfind was ~4 % of all calls). `token_metadata` mode also
  # carries the source split into lines (codepoint columns) so helpers can slice `delimiter:`/`token:`.
  defp resolve_opts(opts, source) do
    tm = Keyword.get(opts, :token_metadata, false)
    range = Keyword.get(opts, :range, false)
    encoder = Keyword.get(opts, :literal_encoder)

    # `source_lines` (a `String.split` + per-line ASCII scan) is only needed when we slice the source
    # — token_metadata / range / literal_encoder. DEFAULT lowering never reads the source (the one
    # source-derived fact it needs, `(;)` vs `()`, is a CST flag set by the parser), so it skips the
    # whole-source split+scan and `src_slice` answers `nil`.
    {lines, ascii} =
      if tm or range or encoder != nil do
        line_index(source)
      else
        {nil, nil}
      end

    %{
      existing_atoms_only: Keyword.get(opts, :existing_atoms_only, false),
      range: range,
      literal_encoder: encoder,
      token_metadata: tm,
      source_lines: lines,
      # Per-LINE ASCII descriptor (`:all` | per-line prefix tuple), so `col_byte`/`line_probe` are
      # O(1) within a line's leading-ASCII run instead of walking.
      ascii_lines: ascii
    }
  end

  # The line tuple plus the per-line ASCII descriptors, from ONE split. The descriptors come from a
  # single cursor over the SOURCE: `:binary.match` (Boyer–Moore, C) jumps to the next high byte and
  # the walk hands out `:all` to every line before it — one match call per line that actually has a
  # non-ASCII byte, instead of one per line (that per-line call was ~30 ms per stdlib pass, most of
  # the tm/range index cost, for files where a single docstring holds the only non-ASCII text).
  # Offsets are tracked on the RAW split lines (before `\r` chomping) so they line up with the
  # source; a high byte is never `\r`, so its offset within the chomped line is the same.
  defp line_index(source) do
    raw = String.split(source, "\n")

    lines =
      case :binary.match(source, "\r") do
        :nomatch -> raw
        _ -> Enum.map(raw, &chomp_cr/1)
      end

    pat = high_byte_pattern()

    ascii =
      case :binary.match(source, pat) do
        :nomatch -> :all
        {pos, _} -> raw |> ascii_descriptors(lines, 0, pos, source, pat, []) |> rev_tuple()
      end

    {List.to_tuple(lines), ascii}
  end

  # `next` is the source offset of the next high byte at or after `lo` (the current raw line's
  # start), or `nil` once the source has no more.
  defp ascii_descriptors([raw | raws], [line | lines], lo, next, source, pat, acc) do
    hi = lo + byte_size(raw) + 1

    if next != nil and next < hi do
      d = line_descriptor(line, next - lo)
      ascii_descriptors(raws, lines, hi, next_high_byte(source, hi, pat), source, pat, [d | acc])
    else
      ascii_descriptors(raws, lines, hi, next, source, pat, [:all | acc])
    end
  end

  defp ascii_descriptors([], [], _lo, _next, _source, _pat, acc), do: acc

  defp next_high_byte(source, from, pat) when from < byte_size(source) do
    case :binary.match(source, pat, scope: {from, byte_size(source) - from}) do
      :nomatch -> nil
      {pos, _} -> pos
    end
  end

  defp next_high_byte(_source, _from, _pat), do: nil

  # Per-line ASCII descriptor for a line whose first non-ASCII byte sits at `pos`: an integer = the
  # byte offset of the first non-ASCII byte = the count of LEADING ASCII codepoints (a line that's
  # only non-ASCII in a trailing string/comment still has a long ASCII prefix where delimiters and
  # operators live, so positioning there stays O(1)), or `{pos, index}` with a sparse cluster index
  # when the non-ASCII tail is long (see `gc_index/1`).
  defp line_descriptor(line, pos) when byte_size(line) - pos <= @gc_index_min, do: pos
  defp line_descriptor(line, pos), do: {pos, gc_index(line)}

  # Sparse cluster→byte-offset index for a long mixed line: entry `i` is the byte offset of column
  # `i * @gc_index_step + 1`. Without it, N metadata queries at increasing columns on the same line
  # each re-walk it from the start — O(N × col), quadratic (the `opts` map is immutable, so nothing
  # can be carried from one query to the next). With it a query walks at most `@gc_index_step`
  # clusters. Built once per mixed line, in O(line), and only for lines whose non-ASCII tail exceeds
  # `@gc_index_min` bytes so short unicode lines (the common case) stay a bare integer prefix.
  #
  # It walks from byte 0, NOT from the ASCII prefix: an ASCII byte followed by a combining mark is
  # one cluster with it, so `prefix` is not necessarily a cluster boundary and an index anchored
  # there would report columns the full walk never produces.
  defp gc_index(line), do: line |> gc_index_offsets(0, byte_size(line), [0]) |> rev_tuple()

  defp gc_index_offsets(text, off, size, acc) when off < size do
    case col_byte_walk(binary_part(text, off, size - off), @gc_index_step, 0) do
      :past -> acc
      o -> gc_index_offsets(text, off + o, size, [off + o | acc])
    end
  end

  defp gc_index_offsets(_text, _off, _size, acc), do: acc

  defp rev_tuple(rev), do: rev |> :lists.reverse() |> List.to_tuple()

  # The leading-ASCII byte count of a line descriptor (`:all` is handled by the callers' own clause).
  defp ascii_prefix({prefix, _index}), do: prefix
  defp ascii_prefix(prefix), do: prefix

  # ASCII descriptor for line `n` — `:all`, an integer prefix length, a `{prefix, index}` pair, or
  # `0` (out-of-range: walk all).
  defp line_ascii_prefix(%{ascii_lines: :all}, _n), do: :all

  defp line_ascii_prefix(%{ascii_lines: t}, n) when n >= 1 and n <= tuple_size(t),
    do: elem(t, n - 1)

  defp line_ascii_prefix(_opts, _n), do: 0

  # Boyer–Moore pattern of every high byte (0x80–0xFF), compiled once and cached in `:persistent_term`
  # (mirrors `Toxic2.Lexer`): a C-level pure-ASCII test that is effectively free per file.
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

  # A CRLF file leaves a trailing `\r` on each split line; strip it so an end-of-line scan sees the
  # line end where the `\r\n` begins (matching Elixir, which treats `\r\n` as the newline). The trim
  # is gated on the SOURCE containing a `\r` at all (one C-level scan, see `line_index/1`): for an
  # LF-only file — the common case — a per-line `String.trim_trailing` pass was ~8% of the whole
  # lower stage. `chomp_cr/1` keeps the exact trim_trailing semantics (strips ALL trailing `\r`s).
  defp chomp_cr(line) when byte_size(line) > 0 do
    case :binary.last(line) do
      ?\r -> chomp_cr(binary_part(line, 0, byte_size(line) - 1))
      _ -> line
    end
  end

  defp chomp_cr(line), do: line

  # Raw source text spanning `{sl,sc}`..`{el,ec}` (codepoint columns, end-exclusive), or `nil`.
  # Single-line (the hot case — `token:` text, `(`/`)` delimiter checks): map the codepoint columns
  # to byte offsets with `col_byte` and take ONE `binary_part`, instead of `String.slice`'s
  # grapheme walk (`do_slice`/`byte_size_remaining_at`/`unicode_util.gc` were ~3M tm words). The
  # `:past` clamp mirrors `String.slice` returning "" past the line end / to the line end.
  defp src_slice(%{source_lines: lines} = opts, {sl, sc}, {el, ec})
       when is_tuple(lines) and sl == el and ec >= sc do
    line = elem(lines, sl - 1)
    ascii = line_ascii_prefix(opts, sl)

    case col_byte(line, sc, ascii) do
      :past ->
        ""

      o1 ->
        o2 =
          case col_byte(line, ec, ascii) do
            :past -> byte_size(line)
            v -> v
          end

        binary_part(line, o1, o2 - o1)
    end
  end

  # a degenerate span (`ec < sc` on one line, or `ec < 1` / `el < sl` across lines) can arise from
  # an unclosed/empty delimiter (e.g. a bare `(` at EOF); there is no source to slice
  defp src_slice(%{source_lines: _lines}, {sl, _sc}, {el, _ec}) when sl == el, do: nil

  # Multi-line (rare — heredoc / cross-line `token:` text): the first line FROM column `sc` to its
  # end, the whole inner lines, and the last line UP TO column `ec`. Same `col_byte` + `binary_part`
  # treatment as the single-line clause (no `String.slice`/`String.length` grapheme walk); the inner
  # lines are already sub-binaries. The `Enum.join` materialises the one result binary (inherent).
  defp src_slice(%{source_lines: lines} = opts, {sl, sc}, {el, ec})
       when is_tuple(lines) and el > sl and ec >= 1 do
    head_line = elem(lines, sl - 1)

    head =
      case col_byte(head_line, sc, line_ascii_prefix(opts, sl)) do
        :past -> ""
        o -> binary_part(head_line, o, byte_size(head_line) - o)
      end

    tail_line = elem(lines, el - 1)

    tend =
      case col_byte(tail_line, ec, line_ascii_prefix(opts, el)) do
        :past -> byte_size(tail_line)
        o -> o
      end

    tail = binary_part(tail_line, 0, tend)
    mids = for l <- (sl + 1)..(el - 1)//1, do: elem(lines, l - 1)
    Enum.join(Enum.concat([[head], mids, [tail]]), "\n")
  end

  defp src_slice(_opts, _from, _to), do: nil

  defp tm?(%{token_metadata: tm}), do: tm

  defp src_line(%{source_lines: lines}, n)
       when is_tuple(lines) and n >= 1 and n <= tuple_size(lines),
       do: elem(lines, n - 1)

  defp src_line(_opts, _n), do: nil

  # `source_lines` is always a line tuple here: every caller runs only under `token_metadata: true`,
  # where `resolve_opts` builds the index eagerly (default mode carries `nil`).
  defp src_line_count(%{source_lines: lines}) when is_tuple(lines), do: tuple_size(lines)

  # --- end_of_expression (token_metadata) --------------------------------------------------------
  # A statement carries `end_of_expression: [newlines: n, line: l, column: c]` when it is followed by
  # an end-of-line token (a newline or `;`). `{l, c}` is that terminator's position; `newlines`
  # counts the `\n`s before the next real token, NOT counting the newline that ends a pure-comment
  # line (`# …` alone on its line), matching Elixir's tokenizer. Derived entirely from the source.
  defp attach_eoe(ast, _child, _view, %{token_metadata: false}), do: ast

  defp attach_eoe({f, meta, a} = ast, child, view, opts) do
    case eoe_meta(child, view, opts) do
      [] -> ast
      kw -> {f, Enum.concat(kw, meta), a}
    end
  end

  defp attach_eoe(ast, _child, _view, _opts), do: ast

  defp eoe_meta(child, view, opts) do
    case child_span(child, view) do
      {_sl, _sc, el, ec} -> scan_eoe(opts, el, ec, 0, false, nil)
      _ -> []
    end
  end

  defp scan_eoe(opts, line, col, nls, semi, pos) do
    case src_line(opts, line) do
      nil ->
        finalize_eoe(nls, semi, pos)

      text ->
        # First significant char at/after column `col`, found by ONE in-place codepoint walk —
        # no `String.slice`/`String.length` and no `split_leading_ws` tail binary (those were the
        # top token_metadata allocator). `tok_col` is the codepoint column of that char.
        case line_probe(text, col, line_ascii_prefix(opts, line)) do
          # End of line: cross this line's `\n`.
          {:eol, tok_col} ->
            cross_newline(opts, line, nls, semi, pos || {line, tok_col})

          # A comment RESETS the run (Elixir counts only the newlines after the last comment), so
          # we carry 0 across a comment line.
          {:hash, tok_col} ->
            cross_newline(opts, line, 0, semi, pos || {line, tok_col})

          {:semi, tok_col} ->
            scan_eoe(opts, line, tok_col + 1, nls, true, pos || {line, tok_col})

          {:other, _tok_col} ->
            finalize_eoe(nls, semi, pos)
        end
    end
  end

  # Cross the `\n` that ends `line` (+1 newline), continuing on the next line; at EOF there is none.
  defp cross_newline(opts, line, nls, semi, pos) do
    if line < src_line_count(opts) do
      scan_eoe(opts, line + 1, 1, nls + 1, semi, pos)
    else
      finalize_eoe(nls, semi, pos)
    end
  end

  defp finalize_eoe(nls, semi, {l, c}) when nls > 0 or semi,
    do: [end_of_expression: [newlines: nls, line: l, column: c]]

  defp finalize_eoe(_nls, _semi, _pos), do: []

  # Probe `text` at codepoint column `col`: position at that column, skip any space/tab (advancing
  # the column), then classify the first significant char. Returns `{:eol | :hash | :semi | :other,
  # tok_col}` — ONLY scalars cross the boundary, never a sub-binary.
  #
  # Positioning is `col_byte/3` (shared with every other source read), so a fully-ASCII line / the
  # leading-ASCII prefix of a mixed line is O(1) and a long mixed line goes through the sparse
  # grapheme index instead of re-walking from the line start. Past the line end the walk's `:past`
  # is the classifier's own end-of-line answer, so both report `{:eol, col}`.
  defp line_probe(text, col, desc) do
    case col_byte(text, col, desc) do
      :past -> {:eol, col}
      off -> line_classify(text, off, col, byte_size(text))
    end
  end

  # Skip space/tab from byte offset `off` / column `col` (both ASCII-wide, so they advance in step),
  # then classify. Any non-ws lead byte — including a non-ASCII one — is `:other`, so no utf8 clause.
  defp line_classify(_text, off, col, size) when off >= size, do: {:eol, col}

  defp line_classify(text, off, col, size) do
    case :binary.at(text, off) do
      c when c == ?\s or c == ?\t -> line_classify(text, off + 1, col + 1, size)
      ?# -> {:hash, col}
      ?; -> {:semi, col}
      _ -> {:other, col}
    end
  end

  # Count the newlines in the source from `{line, col}` up to the next real token, with the same
  # comment-reset rule as `end_of_expression` (a comment line zeroes the run). Used for the
  # standalone `newlines:` on operators / `->` / `when` / containers, so comments and blank lines
  # are counted exactly as Elixir's tokenizer does (not a naive line delta).
  defp gap_newlines(opts, line, col, nls \\ 0) do
    case src_line(opts, line) do
      nil ->
        nls

      text ->
        # Same in-place walk as `scan_eoe` (no slicing). A `;` is not a gap terminator here, so it
        # falls into `:other` like any real token — matching the old `true ->` branch.
        case line_probe(text, col, line_ascii_prefix(opts, line)) do
          {:eol, _} -> cross_gap(opts, line, nls + 1, nls)
          {:hash, _} -> cross_gap(opts, line, 1, nls)
          _ -> nls
        end
    end
  end

  defp cross_gap(opts, line, next_nls, eof_nls) do
    if line < src_line_count(opts), do: gap_newlines(opts, line + 1, 1, next_nls), else: eof_nls
  end

  defp lower(cst, view, opts, acc, nid) do
    case ctag(cst) do
      :token -> lower_token(cst, view, opts, acc, nid)
      :missing -> {error_ast(cst, view), acc, nid}
      :node -> lower_node(cst, view, opts, acc, nid)
    end
  end

  # `meta` is built INSIDE the three branches that consume it: the numeric / literal / atom branches
  # are the bulk of the leaves and never look at it, and the BEAM otherwise constructs its line and
  # column cons cells before the `select_val` dispatch.
  defp lower_token(cst, view, opts, acc, nid) do
    idx = ctoki(cst)
    val = tv(view, idx)

    case tk(view, idx) do
      :int -> lit(val, view, idx, opts, acc, nid, tm_token(view, idx, opts))
      :flt -> lit(val, view, idx, opts, acc, nid, tm_token(view, idx, opts))
      :char -> lit(val, view, idx, opts, acc, nid, tm_token(view, idx, opts))
      :literal -> lit(val, view, idx, opts, acc, nid)
      # `&N` (capture argument): the whole token is the capture `{:&, _, [N]}` (see Precedence).
      :capture_int -> {{:&, token_meta(view, idx, opts), [val]}, acc, nid}
      :atom -> lower_atom_literal(cst, view, idx, opts, val, acc, nid)
      :identifier -> atomize_var(cst, view, idx, opts, acc, nid, val)
      :alias -> atomize_alias(cst, view, idx, opts, acc, nid, val)
      _ -> {error_ast(cst, view), acc, nid}
    end
  end

  # Leaf nodes are fresh (no passthrough), so the token's own span IS the range.
  defp token_meta(view, idx, opts), do: tmeta(view, idx) |> maybe_token_range(view, idx, opts)

  defp lower_atom_literal(cst, view, idx, opts, val, acc, nid) do
    case to_atom(val, opts) do
      # `:true` / `:false` / `:nil` — upstream's atom_colon_meta adds `format: :atom` for exactly
      # these three, so an encoder can tell `:true` from bare `true` (K12).
      {:ok, atom} when atom in [true, false, nil] ->
        lit(atom, view, idx, opts, acc, nid, format: :atom)

      {:ok, atom} ->
        lit(atom, view, idx, opts, acc, nid)

      :error ->
        nonexistent_atom(cst, view, val, acc, nid)
    end
  end

  # --- literal encoder (opt-in via `literal_encoder: fn val, meta -> {:ok, ast} | {:error, _} end`)
  # Elixir-compatible: called for each literal (int/float/atom/string/charlist/true/false/nil and
  # list / 2-tuple containers) with positional meta — `line:`/`column:` plus `range:` when ranges
  # are on. Lets bare literals (which otherwise have no metadata slot in the AST) carry source info.

  # A scalar leaf literal: `lit/6` only touches the token span when an encoder is installed, so the
  # default (no-encoder) path stays a bare value with zero extra work.
  defp lit(value, view, idx, opts, acc, nid, extra \\ []) do
    case opts.literal_encoder do
      nil ->
        {value, acc, nid}

      enc ->
        span = tspan(view, idx)
        run_encoder_meta(enc, value, Enum.concat(extra, literal_meta(span, opts)), span, acc, nid)
    end
  end

  defp run_encoder_meta(enc, value, meta, span, acc, nid) do
    case enc.(value, meta) do
      {:ok, encoded} ->
        {encoded, acc, nid}

      {:error, reason} ->
        sp = if is_tuple(span), do: span, else: {1, 1, 1, 1}

        {id, acc, nid} =
          Diagnostics.emit(acc, nid, :lowerer, :error, :literal_encoder, sp, %{reason: reason})

        {{:__error__, [], %{diag_ids: [id]}}, acc, nid}
    end
  end

  defp literal_meta({sl, sc, _el, _ec} = span, opts),
    do: with_range([line: sl, column: sc], span, opts)

  defp literal_meta(_other, _opts), do: []

  # --- source ranges (opt-in via `range: true`) --------------------------------------------------
  # Each AST node that corresponds to source carries `range: {{start_line, start_col}, {end_line,
  # end_col}}` (end exclusive — one past the last char), separate from the `line:`/`column:` anchor
  # (which Elixir places on the operator for infix ops, not the expression start). The extent comes
  # straight from the green CST node's span, so a parent's range provably contains every child's.

  defp range_enabled?(opts), do: opts.range

  defp with_range(meta, span, opts) do
    case range_enabled?(opts) and span do
      {sl, sc, el, ec} -> [{:range, {{sl, sc}, {el, ec}}} | meta]
      _ -> meta
    end
  end

  # Token spans are only materialized when ranges are on (keeps the default lowering allocation-lean).
  defp maybe_token_range(meta, view, idx, opts) do
    if range_enabled?(opts), do: with_range(meta, tspan(view, idx), opts), else: meta
  end

  # Node kinds that lower to a bare LITERAL value (not a `{form, meta, args}` node) when they hold
  # no interpolation / are 2-element: these feed the literal encoder. Interpolated strings/charlists
  # and 3+ tuples lower to real nodes (3-tuples) instead and take the range path.
  @literal_node_kinds [:list, :tuple, :string, :charlist, :quoted_atom]

  # One trivial clause per node kind (keeps each clause's cyclomatic complexity at 1).
  defp lower_node(cst, view, opts, acc, nid) do
    kind = ckind(cst)
    {ast, acc, nid} = lower_kind(kind, cchildren(cst), cst, view, opts, acc, nid)
    finalize_node(kind, ast, cst, view, opts, acc, nid)
  end

  # A real node result → attach its source range + token_metadata keys. A bare literal result from a
  # literal-bearing kind → run the literal encoder (keys flow into the encoder meta). Anything else
  # (e.g. a synthetic `nil`) passes through untouched.
  defp finalize_node(kind, {_form, meta, _args} = ast, cst, view, opts, acc, nid)
       when is_list(meta) do
    # Default fast path: with neither range nor token_metadata, put_node_range/tm_node_keys/tm_anchor
    # all no-op (range off → unchanged, tm off → [] keys, anchor → meta unchanged), so the whole
    # decoration reduces to the node itself. Skip the four helper calls + empty-list concat per node.
    if opts.range or opts.token_metadata do
      {form, ranged_meta, args} = put_node_range(ast, cst, opts)

      meta = tm_anchor(form, tm_node_keys(kind, cst, view, opts, ranged_meta), cst, opts)

      {{form, meta, args}, acc, nid}
    else
      {ast, acc, nid}
    end
  end

  defp finalize_node(kind, ast, cst, view, opts, acc, nid) when kind in @literal_node_kinds do
    encode_node_literal(kind, ast, cst, view, opts, acc, nid)
  end

  # A parenthesised stab `(a -> b)` (e.g. a function type in a spec) lowers to a clause LIST, which
  # Elixir treats as a list literal — so the encoder wraps it. Single-expr / multi-stmt parens lower
  # to a node or an already-encoded child instead, so only the bare-list (stab) case lands here.
  defp finalize_node(:paren, ast, cst, view, opts, acc, nid) when is_list(ast),
    do: encode_node_literal(:list, ast, cst, view, opts, acc, nid)

  defp finalize_node(_kind, ast, _cst, _view, _opts, acc, nid), do: {ast, acc, nid}

  defp encode_node_literal(kind, ast, cst, view, opts, acc, nid) do
    case opts.literal_encoder do
      nil ->
        {ast, acc, nid}

      enc ->
        span = cspan(cst)
        meta = tm_node_keys(kind, cst, view, opts, literal_meta(span, opts))
        run_encoder_meta(enc, ast, meta, span, acc, nid)
    end
  end

  # --- token_metadata (Elixir-compatible meta, opt-in via `token_metadata: true`) ----------------
  # Structural keys derivable from the green CST: `closing:` (close-delimiter position = node-span
  # end minus the close length), and `do:`/`end:` (the do-block span start = the `do` keyword,
  # span end minus 3 = the `end` keyword). No source / view needed.

  # `ambiguous_op: nil` — a no-parens local call whose SOLE argument is a space-separated unary
  # `+`/`-` (`foo -1`, `@all_info -1`). The parser only yields an `:np_call` here in the genuinely
  # ambiguous case (`foo - 1` parses as a binary op instead), so the shape itself is the trigger.
  defp ambiguous_op_meta({fun, meta, args} = ast, [_callee, arg], view, opts) when is_atom(fun) do
    if tm?(opts) and leading_unary_pm?(arg, view),
      do: {fun, [{:ambiguous_op, nil} | meta], args},
      else: ast
  end

  defp ambiguous_op_meta(ast, _ch, _view, _opts), do: ast

  # The argument BEGINS with a space-separated unary `+`/`-` — either directly (`foo -1`) or as the
  # leftmost operand of a wider expression (`@spec -float :: float`, where the arg is `… :: …`).
  defp leading_unary_pm?({:node, :unary_op, _sp, [op_leaf | _], _f, _d}, view),
    do: ctag(op_leaf) == :token and tv(view, ctoki(op_leaf)) in [:+, :-]

  defp leading_unary_pm?({:node, :binary_op, _sp, [left | _], _f, _d}, view),
    do: leading_unary_pm?(left, view)

  defp leading_unary_pm?(_arg, _view), do: false

  # Key ORDER mirrors Elixir's encoder exactly (the AST is compared as ordered keyword lists):
  # `do`/`end` first, THEN `newlines`, THEN `closing`, THEN `delimiter`. A call with both a
  # multi-line open delimiter and a do-block (`foo(\n a\n) do … end`) needs `do, end, newlines,
  # closing` — putting `open_newlines` first (correct only when there is no do-block) misordered it.
  #
  # The base meta (`line:`/`column:`/`range:`) is threaded in as `tail` and each component is
  # PREPENDED right-to-left, so the result is built with at most one small `++` per non-empty
  # component (and ZERO work when a node has no tm keys — `prepend([], tail)` is `tail`). This
  # replaces the old `Enum.concat([a,b,c,d])` intermediate (a `concat_list` over four mostly-empty
  # lists, ~3% of tm CPU) followed by a second concat onto the base.
  defp tm_node_keys(kind, cst, view, opts, tail) do
    if tm?(opts) do
      doend_keys(cst, opts)
      |> prepend(
        open_newlines(kind, cst, view, opts)
        |> prepend(
          closing_keys(kind, cst, view, opts)
          |> prepend(delimiter_keys(kind, cst, opts) |> prepend(tail))
        )
      )
    else
      tail
    end
  end

  # Prepend a (usually short) key list onto a tail, skipping the `++` entirely for the common empty
  # component. `keys ++ tail` copies only `keys`; `tail` is shared.
  defp prepend([], tail), do: tail
  defp prepend(keys, tail), do: Enum.concat(keys, tail)

  # `newlines:` for a container / call / `fn`: the (comment-aware) newline count between the open
  # delimiter and the first inner element. `foo(\n a)` / `{\n a}` / `%{\n a: 1}` / `fn\n x -> …` → 1;
  # a newline only *between* later elements does not count. A struct carries it on its inner map.
  # `fn\n-> 1 end` — when the FIRST clause head is empty, upstream attaches the eol to the
  # ARROW (`stab_op_eol`), not to `fn` (K11); with a pattern (`fn\n x -> …`) it stays on `fn`.
  defp open_newlines(:fn, cst, view, opts) do
    if fn_empty_first_head?(cchildren(cst)),
      do: [],
      else: open_newlines_scan(:fn, cst, view, opts)
  end

  defp open_newlines(kind, cst, view, opts)
       when kind in [
              :call,
              :remote_call,
              :anon_call,
              :dot_tuple,
              :tuple,
              :map,
              :map_update,
              :bitstring,
              :list
            ],
       do: open_newlines_scan(kind, cst, view, opts)

  defp open_newlines(_kind, _cst, _view, _opts), do: []

  defp open_newlines_scan(kind, cst, view, opts) do
    case open_scan_pos(kind, cst, view, opts) do
      {line, col} ->
        case gap_newlines(opts, line, col) do
          n when n > 0 -> [newlines: n]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp fn_empty_first_head?([{:node, :stab, _sp, [args, _body], _f, _d} | _rest]),
    do: cchildren(args) == []

  defp fn_empty_first_head?(_children), do: false

  # Where to start scanning for the post-open-delimiter newlines: just past `(`/`{`/`[`/`<<`/`%{`/`fn`.
  # For a (local) call the `(` follows the callee (child 0); for a remote call it follows the member
  # name (child 1) — but only when parens are actually present (`a.b`/`a.b c` have none); otherwise
  # the delimiter sits at the node-span start.
  defp open_scan_pos(:call, cst, view, opts), do: after_open_paren(cst, 0, view, opts)
  defp open_scan_pos(:remote_call, cst, view, opts), do: after_open_paren(cst, 1, view, opts)

  # `foo.(…)` / `Foo.{…}` — the open delimiter follows the base AND the `.`, so it sits one column
  # further than a plain call's `(`.
  defp open_scan_pos(:anon_call, cst, view, opts), do: after_dot_delim(cst, ?(, view, opts)
  defp open_scan_pos(:dot_tuple, cst, view, opts), do: after_dot_delim(cst, ?{, view, opts)

  # A map opens with `%{` (2) when written `%{…}`, but only `{` (1) as a struct's inner map
  # (`%Foo{…}`, where the `%` sits on the struct node), so measure the leading `%` from the source.
  defp open_scan_pos(kind, cst, _view, opts) when kind in [:map, :map_update] do
    case cspan(cst) do
      {sl, sc, _el, _ec} ->
        len = if src_byte_at(opts, sl, sc) == ?%, do: 2, else: 1
        {sl, sc + len}

      _ ->
        nil
    end
  end

  defp open_scan_pos(kind, cst, _view, _opts) do
    case cspan(cst) do
      {sl, sc, _el, _ec} -> {sl, sc + open_delim_len(kind)}
      _ -> nil
    end
  end

  defp open_delim_len(kind) when kind in [:list, :tuple], do: 1
  defp open_delim_len(_two_char), do: 2

  # The position just past the `(` following child `idx` (the callee / member name) — or `nil` when
  # the next char is not `(` (a paren-less call, which has no open-delimiter newlines).
  defp after_open_paren(cst, idx, view, opts) do
    with child when not is_nil(child) <- child_at(cchildren(cst), idx),
         {_, _, el, ec} <- child_span(child, view),
         ?( <- src_byte_at(opts, el, ec) do
      {el, ec + 1}
    else
      _ -> nil
    end
  end

  # `foo.(…)` / `Foo.{…}` — the open delimiter is the char one past the base's `.` (two past the base
  # end). Returns the position just inside it, or `nil` if the expected delimiter (a byte: `?(`/`?{`)
  # isn't there.
  defp after_dot_delim(cst, delim, view, opts) do
    with child when not is_nil(child) <- child_at(cchildren(cst), 0),
         {_, _, el, ec} <- child_span(child, view),
         ^delim <- src_byte_at(opts, el, ec + 1) do
      {el, ec + 2}
    else
      _ -> nil
    end
  end

  # Direct indexed child access (idx is always 0 or 1) — avoids `Enum.at/2`'s protocol dispatch on
  # the call/remote-call metadata path.
  defp child_at([c | _], 0), do: c
  defp child_at([_, c | _], 1), do: c
  defp child_at(_children, _idx), do: nil

  # Byte at codepoint column `col` of source line `line`, or `nil` (past end / no line). For the
  # single-char delimiter checks (`(`/`)`/`{`/`%`) — `col_byte` + `:binary.at` avoid the 1-byte
  # sub-binary `src_slice` would build, and `col_byte` is O(1) on ASCII lines.
  defp src_byte_at(opts, line, col) do
    case src_line(opts, line) do
      nil ->
        nil

      text ->
        case col_byte(text, col, line_ascii_prefix(opts, line)) do
          off when is_integer(off) and off < byte_size(text) -> :binary.at(text, off)
          _ -> nil
        end
    end
  end

  # Container / operator nodes that lowering built with empty meta still need a `line:`/`column:`
  # anchor (the node-span start) under `token_metadata: true`, matching Elixir. The implicit
  # `:__block__` grouping is the one node Elixir leaves anchorless, so it is excluded.
  defp tm_anchor(:__block__, meta, _cst, _opts), do: meta

  defp tm_anchor(_form, meta, cst, opts) do
    if tm?(opts) and not Keyword.has_key?(meta, :line) do
      case cspan(cst) do
        {sl, sc, _el, _ec} -> Enum.concat(meta, line: sl, column: sc)
        _ -> meta
      end
    else
      meta
    end
  end

  # The counterpart of open_newlines/4's empty-first-head rule (K11): the eol run after `fn`
  # lands as `newlines:` on the first ARROW (`fn\n-> 1 end` => `{:->, [newlines: 1, …], …}`).
  defp fn_first_arrow_newlines([{:->, m, a} | rest], ch, cst, opts) do
    with true <- tm?(opts),
         true <- fn_empty_first_head?(ch),
         false <- Keyword.has_key?(m, :newlines),
         {sl, sc, _, _} <- cspan(cst),
         n when is_integer(n) and n > 0 <- gap_newlines(opts, sl, sc + 2) do
      [{:->, [{:newlines, n} | m], a} | rest]
    else
      _ -> [{:->, m, a} | rest]
    end
  end

  defp fn_first_arrow_newlines(clauses, _ch, _cst, _opts), do: clauses

  # A stab clause anchors at its `->` operator (not the clause start), matching Elixir, and records
  # `newlines:` when its body starts on a later line than the `->`.
  # Scan for `->` starting AFTER the clause head (the args' span end), never from the clause start —
  # otherwise a pattern that contains the literal text `->` (e.g. `fn "->" -> x end`) would match
  # inside the pattern instead of the real arrow.
  defp stab_arrow_meta(args_node, body_node, view, opts) do
    if tm?(opts) do
      case arrow_scan_start(args_node, view) do
        {line, col} ->
          last = with({bsl, _, _, _} <- child_span(body_node, view), do: bsl, else: (_ -> line))
          arrow = scan_op(opts, line, col, "->", last)
          nls = stab_newlines({line, col}, arrow, opts)
          Enum.concat([stab_parens_meta(args_node, view, opts), nls, arrow])

        _ ->
          []
      end
    else
      []
    end
  end

  # A parenthesised clause head (`fn (a, b) -> …`, `fn () -> …`, and the guarded `fn () when g -> …`)
  # records `parens: [line, column, closing: …]` on the `->` (the `(`…`)` span). The patterns are the
  # head children — unwrapped from a `stab_when` (which appends the guard) when a guard is present.
  defp stab_parens_meta(args_node, view, _opts) do
    case stab_parens_bounds(args_node, view) do
      {{sl, sc, _, _}, {el, ec, _, _}} ->
        [parens: [closing: [line: el, column: ec], line: sl, column: sc]]

      nil ->
        []
    end
  end

  defp stab_head_patterns(args_node) do
    case cchildren(args_node) do
      [{:node, :stab_when, _sp, when_ch, _f, _d}] -> Enum.drop(when_ch, -1)
      children -> children
    end
  end

  # An empty `()` head is a single empty `:paren` node. A parenthesised multi/keyword-arg head is
  # stored as bare patterns, so recover its delimiters from the token immediately outside the full
  # first/last pattern spans. Using tokens (rather than same-line source slices) also handles
  # newlines/comments and nested first/last patterns without mistaking punctuation in comments.
  defp stab_parens_bounds(args_node, view) do
    case stab_head_patterns(args_node) do
      [{:node, :paren, {sl, sc, el, ec}, [], _f, _d}] ->
        {{sl, sc, sl, sc + 1}, {el, ec - 1, el, ec}}

      [first | _] = pats ->
        with first_i when is_integer(first_i) <- cst_first_token_index(first, view),
             open_i when is_integer(open_i) <- previous_non_eol(view, first_i - 1),
             :"(" <- tk(view, open_i),
             last_i when is_integer(last_i) <- cst_last_token_index(List.last(pats), view),
             close_i when is_integer(close_i) <- next_non_eol(view, last_i + 1),
             :")" <- tk(view, close_i),
             open_span when is_tuple(open_span) <- tspan(view, open_i),
             close_span when is_tuple(close_span) <- tspan(view, close_i) do
          {open_span, close_span}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp cst_first_token_index({:token, i, _f, _d}, _view), do: i

  defp cst_first_token_index({:node, _k, {sl, sc, _el, _ec}, children, _f, _d}, view) do
    case Enum.find_value(children, &cst_first_token_index(&1, view)) do
      i when is_integer(i) -> rewind_to_span_start(view, i, sl, sc)
      _ -> nil
    end
  end

  defp cst_first_token_index(_cst, _view), do: nil

  defp rewind_to_span_start(view, i, sl, sc) when i >= 0 do
    case tspan(view, i) do
      {^sl, ^sc, _, _} ->
        i

      {tl, tc, _, _} when tl > sl or (tl == sl and tc > sc) ->
        rewind_to_span_start(view, i - 1, sl, sc)

      _ ->
        i
    end
  end

  defp rewind_to_span_start(_view, _i, _sl, _sc), do: nil

  defp cst_last_token_index({:token, i, _f, _d}, _view), do: i

  defp cst_last_token_index({:node, _k, {_sl, _sc, el, ec}, children, _f, _d}, view) do
    case Enum.find_value(Enum.reverse(children), &cst_last_token_index(&1, view)) do
      i when is_integer(i) -> advance_to_span_end(view, i, el, ec)
      _ -> nil
    end
  end

  defp cst_last_token_index(_cst, _view), do: nil

  defp advance_to_span_end(view, i, el, ec) do
    case tspan(view, i) do
      {_, _, ^el, ^ec} ->
        i

      {_, _, tl, tc} when tl < el or (tl == el and tc < ec) ->
        advance_to_span_end(view, i + 1, el, ec)

      _ ->
        i
    end
  end

  defp previous_non_eol(view, i) when i >= 0 do
    if tk(view, i) == :eol, do: previous_non_eol(view, i - 1), else: i
  end

  defp previous_non_eol(_view, _i), do: nil

  defp next_non_eol(view, i) do
    case tk(view, i) do
      :eol -> next_non_eol(view, i + 1)
      :eof -> nil
      _ -> i
    end
  end

  # Where to begin scanning for the clause `->`: after the last pattern (so its text can't contain a
  # false `->`); for an empty head (`fn -> …`) there is no pattern, so start at the head's span start.
  defp arrow_scan_start(args_node, view) do
    case cchildren(args_node) do
      [] ->
        with({sl, sc, _, _} <- child_span(args_node, view), do: {sl, sc}, else: (_ -> nil))

      # A guarded head must start after its guard, which also prevents `->` text inside the guard
      # from being mistaken for the clause arrow.
      [{:node, :stab_when, _sp, _ch, _f, _d}] = children ->
        arrow_scan_start_after_last(children, view)

      # For an unguarded parenthesised multi/keyword-arg or empty head, begin after `)`, not after
      # the last pattern. Otherwise a line break before the closing delimiter becomes a false
      # `newlines:` entry on `->`.
      children ->
        case stab_parens_bounds(args_node, view) do
          {_open, {_, _, el, ec}} -> {el, ec}
          nil -> arrow_scan_start_after_last(children, view)
        end
    end
  end

  defp arrow_scan_start_after_last(children, view) do
    with(
      {_, _, el, ec} <- child_span(List.last(children), view),
      do: {el, ec},
      else: (_ -> nil)
    )
  end

  # newlines AFTER the `->` (comment-aware), scanning from just past the arrow.
  # newlines adjacent to the `->`: the count AFTER it (arrow at line end) if any, else BEFORE it
  # (arrow at line start, e.g. a guard then `\n  -> body`). Comment-aware via `gap_newlines`.
  defp stab_newlines({hl, hc}, [line: al, column: ac], opts) do
    after_n = gap_newlines(opts, al, ac + 2)
    n = if after_n > 0, do: after_n, else: gap_newlines(opts, hl, hc)
    if n > 0, do: [newlines: n], else: []
  end

  defp stab_newlines(_start, _arrow, _opts), do: []

  # Find `needle` in the source starting at (line, col), up to and including `last_line`. Returns
  # `[line: l, column: c]` (codepoint column) or `[]`. Used for operator anchors (`->`, `|`).
  defp scan_op(opts, line, col, needle, last_line) when line <= last_line do
    case src_line(opts, line) do
      nil ->
        []

      text ->
        # Position at codepoint column `col` (scalar byte offset, no slice), then let the C-level
        # Boyer–Moore `:binary.match` find `needle` from there — no `String.slice`/`String.split`
        # (the list + `++`) / `String.length`. The gap from `col` to the operator is whitespace, so
        # its codepoint width equals the byte delta; `cp_between` keeps it exact for the rare case.
        ascii = line_ascii_prefix(opts, line)

        case col_byte(text, col, ascii) do
          :past ->
            scan_op(opts, line + 1, 1, needle, last_line)

          boff ->
            # COMMENT-AWARE: the scanned region is the gap between two tokens, where any `#`
            # starts a comment running to end of line — an operator spelled inside a comment
            # (`fn a # ->\n -> 1 end`, `a # not\nnot in b`) must not hijack the anchor (K14/K10).
            case gap_op_match(text, needle, boff) do
              {moff, _} -> [line: line, column: col + scan_gap(text, boff, moff, ascii)]
              :nomatch -> scan_op(opts, line + 1, 1, needle, last_line)
            end
        end
    end
  end

  defp scan_op(_opts, _line, _col, _needle, _last_line), do: []

  # `:binary.match` for `needle` from `boff`, unless a `#` (a gap comment) precedes it on the line.
  defp gap_op_match(text, needle, boff) do
    scope = {boff, byte_size(text) - boff}

    with {moff, _} = m <- :binary.match(text, needle, scope: scope) do
      case :binary.match(text, "#", scope: scope) do
        {hoff, _} when hoff < moff -> :nomatch
        _ -> m
      end
    end
  end

  # Codepoint gap from byte offset `boff` to the operator at `moff`. When `boff..moff` is entirely in
  # the line's ASCII region (whole line `:all`, or the operator found within the leading-ASCII prefix)
  # the codepoint gap equals the byte gap — skip `cp_between`'s `binary_part` + codepoint count.
  defp scan_gap(_text, boff, moff, :all), do: moff - boff

  defp scan_gap(text, boff, moff, desc) do
    if moff <= ascii_prefix(desc), do: moff - boff, else: cp_between(text, boff, moff)
  end

  # Byte offset of the grapheme-cluster column `col` in `text` (i.e. after `col - 1` clusters), or
  # `:past` past the line end. Scalar return — never a tail binary.
  # Fully-ASCII line: cluster column == byte offset everywhere, O(1), no walk at all. `:past`
  # mirrors the walk's "column beyond the line" result (strictly past the last byte).
  defp col_byte(text, col, :all) do
    o = col - 1
    if o < 0 or o > byte_size(text), do: :past, else: o
  end

  # Degenerate column (< 1, from an inferred/unclosed delimiter) — checked HERE so `col_byte_walk`
  # never sees a negative count.
  defp col_byte(_text, col, _any) when col < 1, do: :past

  # Mixed line: a column within the leading-ASCII prefix is O(1) (byte offset == column there).
  # `is_integer` matters — a `{prefix, index}` descriptor would compare GREATER than any integer in
  # Erlang term order and silently take this clause.
  defp col_byte(_text, col, prefix) when is_integer(prefix) and col - 1 <= prefix, do: col - 1

  defp col_byte(text, col, prefix) when is_integer(prefix), do: col_byte_walk(text, col - 1, 0)

  defp col_byte(_text, col, {prefix, _index}) when col - 1 <= prefix, do: col - 1

  # Long mixed line: jump to the nearest indexed column at or before `col`, then walk the remainder
  # (< `@gc_index_step` clusters). An index that stops short of `col` means the line has fewer
  # columns than that — `:past`, exactly as the full walk would report.
  defp col_byte(text, col, {_prefix, index}) do
    d = col - 1
    i = div(d, @gc_index_step)

    if i < tuple_size(index) do
      start = elem(index, i)

      case col_byte_walk(
             binary_part(text, start, byte_size(text) - start),
             rem(d, @gc_index_step),
             0
           ) do
        :past -> :past
        o -> start + o
      end
    else
      :past
    end
  end

  # Walk GRAPHEME CLUSTERS from a non-negative count — one cluster is one column (matching the
  # lexer's content scanners and upstream's `unicode_util:gc` walk: `é` as `e` + U+0301 is one
  # column). A run of ASCII bytes is counted by `ascii_span/3` through ONE reused match context;
  # only a cluster that a non-ASCII byte extends needs a sub-binary. The old per-byte
  # `binary_part(bin, 1, byte_size(bin) - 1)` materialized a fresh sub-binary on EVERY step
  # (`bs_get_tail` + `gc_bif binary_part` in the disassembly) because its 2-byte lookahead clause
  # could not hand its own tail to the recursive call.
  defp col_byte_walk(bin, n, off) when n > 0 do
    case ascii_span(bin, 0, n + 1) do
      # `n + 1` ASCII bytes ahead: each of the first `n` is followed by ASCII, so each is a cluster.
      {a, _tail} when a > n -> off + n
      # The run reaches the line end: every one of its bytes is its own cluster.
      {a, <<>>} -> if a == n, do: off + n, else: :past
      # A non-ASCII byte cut the run short — it extends the cluster the LAST ASCII byte starts.
      {a, _tail} -> col_byte_gc(bin, a, n, off)
    end
  end

  defp col_byte_walk(_bin, _n, off), do: off

  defp col_byte_gc(bin, a, n, off) do
    skip = if a > 0, do: a - 1, else: 0
    base = if skip == 0, do: bin, else: binary_part(bin, skip, byte_size(bin) - skip)

    case base do
      <<_::utf8, _::binary>> ->
        w = gc_head_bytes(base)
        col_byte_walk(binary_part(base, w, byte_size(base) - w), n - skip - 1, off + skip + w)

      # invalid UTF-8 lead byte: one byte, one column
      <<_, rest::binary>> ->
        col_byte_walk(rest, n - skip - 1, off + skip + 1)
    end
  end

  # Count leading ASCII bytes, at most `max`. BOTH clauses start with a binary match, so the BEAM
  # keeps one match context across the loop (`bs_start_match4 :resume` + `call_only`) and builds the
  # returned tail sub-binary once, at termination. A bare-variable head here de-opts the whole loop.
  defp ascii_span(<<c, rest::binary>>, k, max) when c < 128 and k < max,
    do: ascii_span(rest, k + 1, max)

  defp ascii_span(<<_::binary>> = bin, k, _max), do: {k, bin}

  # Byte width of the grapheme cluster at `bin`'s head (>= 1, total over invalid UTF-8).
  # Fast path: no cluster extender exists below U+0300, so a sub-U+0300 head followed by ASCII
  # or another sub-U+0300 codepoint is its own cluster — no `unicode_util:gc` call.
  defp gc_head_bytes(<<c::utf8, rest::binary>> = bin) when c < 0x0300 do
    case rest do
      <<n, _::binary>> when n < 0xCC -> byte_size(bin) - byte_size(rest)
      <<>> -> byte_size(bin) - byte_size(rest)
      <<n::utf8, _::binary>> when n < 0x0300 -> byte_size(bin) - byte_size(rest)
      _ -> gc_head_bytes_slow(bin)
    end
  end

  defp gc_head_bytes(bin), do: gc_head_bytes_slow(bin)

  defp gc_head_bytes_slow(bin) do
    case :unicode_util.gc(bin) do
      [gc | _] -> max(byte_size(:unicode.characters_to_binary(List.wrap(gc))), 1)
      _ -> 1
    end
  rescue
    _ -> 1
  end

  # Grapheme clusters in the byte range `text[lo..hi)` — the gap between a span end and the
  # operator the scan found. Almost always pure-ASCII whitespace (so `hi - lo`), but counted for
  # exactness in the same one-cluster-one-column model as `col_byte_walk`.
  defp cp_between(text, lo, hi), do: count_gc(binary_part(text, lo, hi - lo))

  defp count_gc(<<>>), do: 0

  defp count_gc(<<c, nb, _::binary>> = bin) when c < 128 and nb < 128,
    do: 1 + count_gc(binary_part(bin, 1, byte_size(bin) - 1))

  defp count_gc(<<c>>) when c < 128, do: 1

  defp count_gc(bin) do
    w = gc_head_bytes(bin)
    1 + count_gc(binary_part(bin, w, byte_size(bin) - w))
  end

  # `delimiter:` — the opening string/charlist/sigil delimiter, read from the source: at the node
  # span start for strings/charlists, after the leading `:` for quoted atoms, and after `~` + the
  # sigil name for sigils. A heredoc opens with the quote tripled (`"""` / `'''`).
  defp delimiter_keys(kind, cst, opts) when kind in [:string, :charlist, :quoted_atom, :sigil] do
    case cspan(cst) do
      {sl, sc, _el, ec} ->
        head = src_slice(opts, {sl, sc}, {sl, sc + 40})

        case head && opening_delimiter(kind, head) do
          d when is_binary(d) -> [{:delimiter, d} | heredoc_indent(kind, d, ec)]
          _ -> []
        end

      _ ->
        []
    end
  end

  defp delimiter_keys(_kind, _cst, _opts), do: []

  # A string/charlist heredoc carries `indentation:` = the closing delimiter's column − 1 (= the
  # node-span end col − 4, since the `"""`/`'''` close is 3 chars and the span end is exclusive).
  # Sigil heredocs put `indentation:` on their inner `<<>>` instead (see `build_sigil`).
  defp heredoc_indent(kind, d, ec) when kind in [:string, :charlist] and byte_size(d) == 3,
    do: [indentation: ec - 4]

  defp heredoc_indent(_kind, _d, _ec), do: []

  defp opening_delimiter(:string, head), do: delim_at(head)
  defp opening_delimiter(:charlist, head), do: delim_at(head)
  defp opening_delimiter(:quoted_atom, ":" <> rest), do: delim_at(rest)
  defp opening_delimiter(:quoted_atom, _), do: nil
  defp opening_delimiter(:sigil, "~" <> rest), do: delim_at(skip_sigil_name(rest))
  defp opening_delimiter(:sigil, _), do: nil

  # Skip the sigil name to reach the opening delimiter. Names are letters AND digits (an uppercase
  # sigil may carry digits, e.g. `~A1(…)`), so a digit must not be mistaken for the delimiter.
  defp skip_sigil_name(<<c, rest::binary>>) when c in ?a..?z or c in ?A..?Z or c in ?0..?9,
    do: skip_sigil_name(rest)

  defp skip_sigil_name(rest), do: rest

  defp delim_at(~S(""") <> _), do: ~S(""")
  defp delim_at("'''" <> _), do: "'''"
  defp delim_at(<<c::utf8, _::binary>>), do: <<c::utf8>>
  defp delim_at(_), do: nil

  # `token:` — the raw source text of a numeric / char literal (preserves `0x1F`, `1_000`, `?a`).
  defp tm_token(view, idx, opts) do
    if tm?(opts) do
      {sl, sc, el, ec} = tspan(view, idx)

      case src_slice(opts, {sl, sc}, {el, ec}) do
        t when is_binary(t) -> [token: t]
        _ -> []
      end
    else
      []
    end
  end

  # Kinds with an UNCONDITIONAL close delimiter: list `]`, tuple/map/map-update `}` (1 char);
  # bitstring `>>` (2); `fn … end` (3). A struct (`%Foo{…}`) carries no `closing:` itself — the inner
  # `%{}` map / map-update node does. Calls have OPTIONAL parens (`foo(a)` vs `try do … end`, both
  # `:call`; `Mod.fun(x)` vs `a.b`, both `:remote_call`), so confirm the span ends at `)` against the
  # source — a paren-less remote call instead gets `no_parens: true`.
  defp closing_keys(kind, cst, view, opts) do
    case {kind, cspan(cst)} do
      {k, {_sl, _sc, el, ec}} when k in [:list, :tuple, :map, :map_update, :dot_tuple] ->
        [closing: [line: el, column: ec - 1]]

      {:bitstring, {_sl, _sc, el, ec}} ->
        [closing: [line: el, column: ec - 2]]

      {:fn, {_sl, _sc, el, ec}} ->
        [closing: [line: el, column: ec - 3]]

      {k, {_sl, _sc, el, ec}} when k in [:call, :remote_call] ->
        call_closing(k, cst, el, ec, view, opts)

      _ ->
        []
    end
  end

  # A call carries `closing:` only when it has actual parens — detected by a `(` immediately after
  # the callee/member (NOT by the span ending in `)`, which `IO.puts foo(x)` would falsely satisfy).
  # When the parenthesised args are followed by a do-block (`quote(x) do … end`), the `)` sits before
  # the block, so locate it; otherwise it is the span's last char. A bare zero-arity remote call
  # (`a.b`) instead gets `no_parens: true`.
  defp call_closing(k, cst, el, ec, view, opts) do
    cond do
      after_open_paren(cst, callee_idx(k), view, opts) == nil ->
        if k == :remote_call and remote_zero_arity?(cst), do: [no_parens: true], else: []

      src_byte_at(opts, el, ec - 1) == ?) ->
        [closing: [line: el, column: ec - 1]]

      true ->
        close_paren_before_do(cst, opts)
    end
  end

  defp callee_idx(:call), do: 0
  defp callee_idx(:remote_call), do: 1

  # The `)` closing a paren call's args when a do-block follows (`quote(x) do … end`): the last `)`
  # in the source from the call start up to the do-block's `do`.
  defp close_paren_before_do(cst, opts) do
    with {:node, :do_block, {dsl, dsc, _, _}, _, _, _} <-
           Enum.find(cchildren(cst), &match?({:node, :do_block, _, _, _, _}, &1)),
         {sl, sc, _el, _ec} <- cspan(cst) do
      last_paren(opts, sl, sc, dsl, dsc)
    else
      _ -> []
    end
  end

  defp last_paren(opts, sl, sc, dsl, dsc) do
    Enum.reduce(sl..dsl, [], fn line, acc ->
      case src_line(opts, line) do
        nil ->
          acc

        text ->
          from = if line == sl, do: sc, else: 1
          # Non-last lines: any column is in-window; `byte_size` is a safe upper bound on the
          # codepoint column count, so no `String.length` is needed.
          upto = if line == dsl, do: dsc - 1, else: byte_size(text)

          case last_char_col(text, ?), 1, from, upto, nil) do
            nil -> acc
            col -> [closing: [line: line, column: col]]
          end
      end
    end)
  end

  # Codepoint column of the LAST `ch` (an ASCII byte) within columns `[from, upto]` of `text`, or
  # `nil`. One in-place walk, no slice/split/length; every clause has a binary head (the `<<>>`
  # terminal) so the match context threads with zero per-step allocation.
  defp last_char_col(<<>>, _ch, _col, _from, _upto, last), do: last

  defp last_char_col(<<c, nb, _::binary>> = bin, ch, col, from, upto, last)
       when c < 128 and nb < 128 do
    last = if c == ch and col >= from and col <= upto, do: col, else: last
    last_char_col(binary_part(bin, 1, byte_size(bin) - 1), ch, col + 1, from, upto, last)
  end

  defp last_char_col(<<c>>, ch, col, from, upto, last) when c < 128 do
    if c == ch and col >= from and col <= upto, do: col, else: last
  end

  defp last_char_col(<<_::utf8, _::binary>> = bin, ch, col, from, upto, last) do
    w = gc_head_bytes(bin)
    last_char_col(binary_part(bin, w, byte_size(bin) - w), ch, col + 1, from, upto, last)
  end

  defp last_char_col(<<_, rest::binary>>, ch, col, from, upto, last),
    do: last_char_col(rest, ch, col + 1, from, upto, last)

  # `do:` / `end:` come from the do-block span (start = `do`, end − 3 = `end`). On TOLERANT/invalid
  # input the block may be unterminated (recovered missing `end`), which would yield an impossible
  # position (e.g. column 0); emit each key only when the source actually has the keyword there.
  # A remote call with exactly `[base, member]` children — no argument and no do-block, i.e. `a.b`.
  defp remote_zero_arity?(cst), do: match?([_base, _member], cchildren(cst))

  defp doend_keys(cst, opts) do
    case Enum.find(cchildren(cst), &match?({:node, :do_block, _, _, _, _}, &1)) do
      {:node, :do_block, {sl, sc, el, ec}, _ch, _f, _d} ->
        Enum.concat(kw_at(opts, sl, sc, "do", :do), kw_at(opts, el, ec - 3, "end", :end))

      _ ->
        []
    end
  end

  defp kw_at(opts, line, col, word, key) do
    if col >= 1 and word_at?(src_line(opts, line), col, word, line_ascii_prefix(opts, line)),
      do: [{key, [line: line, column: col]}],
      else: []
  end

  # Is the literal `word` (ASCII: `do`/`end`) at codepoint column `col` of the line? Positions with
  # `col_byte` (no `src_slice`/`String.length`) and compares the bytes directly — the only sub-binary
  # is the ≤3-byte `binary_part` for the equality check, once per call (not per char).
  defp word_at?(nil, _col, _word, _ascii), do: false

  defp word_at?(text, col, word, ascii) do
    case col_byte(text, col, ascii) do
      :past ->
        false

      boff ->
        wlen = byte_size(word)
        byte_size(text) - boff >= wlen and binary_part(text, boff, wlen) == word
    end
  end

  # Attach this CST node's span as the range — UNLESS the lowered result already carries one, which
  # means `lower_kind` passed a child through transparently (single-statement block/paren); the
  # child's own (tighter) range must win.
  defp put_node_range({form, meta, args}, cst, opts) when is_list(meta) do
    if range_enabled?(opts) and not Keyword.has_key?(meta, :range) do
      {form, with_range(meta, cspan(cst), opts), args}
    else
      {form, meta, args}
    end
  end

  defp put_node_range(ast, _cst, _opts), do: ast

  # Atomize a source-derived name into its leaf node, or — under `existing_atoms_only` for a missing
  # atom — emit a lowerer diagnostic and an error node (never raise).
  # Two specialised builders instead of one `atomize/7` taking a `fun`: the shared version made the
  # caller `make_fun3` a closure capturing `meta` and `atomize` `call_fun2` it, 87 k times per
  # stdlib pass. Here the variable / alias node is built directly at its leaf.
  defp atomize_var(cst, view, idx, opts, acc, nid, val) do
    case to_atom(val, opts) do
      {:ok, atom} -> {{atom, token_meta(view, idx, opts), nil}, acc, nid}
      :error -> nonexistent_atom(cst, view, val, acc, nid)
    end
  end

  defp atomize_alias(cst, view, idx, opts, acc, nid, val) do
    case to_atom(val, opts) do
      {:ok, atom} -> {{:__aliases__, token_meta(view, idx, opts), [atom]}, acc, nid}
      :error -> nonexistent_atom(cst, view, val, acc, nid)
    end
  end

  defp nonexistent_atom(cst, view, val, acc, nid) do
    {id, acc, nid} =
      Diagnostics.emit(acc, nid, :lowerer, :error, :nonexistent_atom, name_span(cst, view), %{
        name: val
      })

    {{:__error__, error_meta(cst, view), %{diag_ids: [id]}}, acc, nid}
  end

  # One trivial clause per node kind (keeps each clause's cyclomatic complexity at 1).
  # An empty top-level program is the grammar's `$empty`/`eoe` rule: since Elixir 1.20 its
  # `__block__` is anchored at `[line: 1, column: 1]` (token-metadata only; normalized away otherwise).
  defp lower_kind(:expr_list, [], _cst, _view, opts, acc, nid),
    do: {{:__block__, if(tm?(opts), do: [line: 1, column: 1], else: []), []}, acc, nid}

  defp lower_kind(:expr_list, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(:paren, ch, cst, view, opts, acc, nid),
    do: lower_paren(ch, cst, view, opts, acc, nid)

  # A leading `;` empty statement in a stab body (`-> ;t` => `__block__([nil, t])`) lowers to `nil`.
  defp lower_kind(:empty_stmt, _ch, _cst, _view, _opts, acc, nid), do: {nil, acc, nid}

  defp lower_kind(:binary_op, ch, _cst, view, opts, acc, nid),
    do: lower_binary(ch, view, opts, acc, nid)

  defp lower_kind(:unary_op, ch, _cst, view, opts, acc, nid),
    do: lower_unary(ch, view, opts, acc, nid)

  # An operator function reference (`+/2` => `{:/, [], [{:+, [], nil}, 2]}`): the bare operator
  # lowers to `{:op_atom, meta, nil}`, the variable-like form the reference's `/arity` divides.
  defp lower_kind(:op_ref, [op_leaf], _cst, view, _opts, acc, nid),
    do: {{op_atom(op_leaf, view), op_meta(op_leaf, view), nil}, acc, nid}

  defp lower_kind(:list, ch, _cst, view, opts, acc, nid), do: lower_list(ch, view, opts, acc, nid)

  # A synthesized keyword list (bare `when a: t` guard) — lowers like a list but is NOT a list
  # literal, so `finalize_node` leaves it un-encoded (matches the oracle).
  defp lower_kind(:kw_list, ch, _cst, view, opts, acc, nid),
    do: lower_each(ch, view, opts, acc, nid)

  defp lower_kind(:tuple, ch, _cst, view, opts, acc, nid),
    do: lower_tuple(ch, view, opts, acc, nid)

  defp lower_kind(:call, ch, _cst, view, opts, acc, nid), do: lower_call(ch, view, opts, acc, nid)

  # A no-parens call lowers identically to a paren call (`f a` and `f(a)` produce the same AST).
  defp lower_kind(:np_call, ch, _cst, view, opts, acc, nid) do
    {ast, acc, nid} = lower_call(ch, view, opts, acc, nid)
    {ambiguous_op_meta(ast, ch, view, opts), acc, nid}
  end

  defp lower_kind(:alias, ch, _cst, view, opts, acc, nid),
    do: lower_alias(ch, view, opts, acc, nid)

  defp lower_kind(:remote_call, ch, _cst, view, opts, acc, nid),
    do: lower_remote_call(ch, view, opts, acc, nid)

  # `Foo.{A, B}` => `{{:., _, [base, :{}]}, _, [elems]}` (multi-alias / `alias Foo.{...}`). The dot
  # and the call both anchor at the `.` (between base and `{`); `closing:` (the `}`) is added by
  # `closing_keys`/`finalize_node`.
  defp lower_kind(:dot_tuple, [base | elems], _cst, view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {elem_asts, acc, nid} = lower_args(elems, view, opts, acc, nid)
    dm = remote_dot_meta(base, view, opts) || []
    {{{:., dm, [base_ast, :{}]}, dm, elem_asts}, acc, nid}
  end

  defp lower_kind(:anon_call, ch, cst, view, opts, acc, nid),
    do: lower_anon_call(ch, cst, view, opts, acc, nid)

  defp lower_kind(:kw_pair, ch, _cst, view, opts, acc, nid),
    do: lower_kw_pair(ch, view, opts, acc, nid)

  defp lower_kind(:bitstring, ch, _cst, view, opts, acc, nid),
    do: lower_bitstring(ch, view, opts, acc, nid)

  defp lower_kind(:access, ch, cst, view, opts, acc, nid),
    do: lower_access(ch, cst, view, opts, acc, nid)

  defp lower_kind(:map, ch, _cst, view, opts, acc, nid), do: lower_map(ch, view, opts, acc, nid)

  defp lower_kind(:map_update, ch, _cst, view, opts, acc, nid),
    do: lower_map_update(ch, view, opts, acc, nid)

  defp lower_kind(:struct, ch, _cst, view, opts, acc, nid),
    do: lower_struct(ch, view, opts, acc, nid)

  defp lower_kind(:assoc, ch, _cst, view, opts, acc, nid),
    do: lower_assoc(ch, view, opts, acc, nid)

  defp lower_kind(:not_in_op, ch, _cst, view, opts, acc, nid),
    do: lower_not_in(ch, view, opts, acc, nid)

  defp lower_kind(:fn, ch, cst, view, opts, acc, nid) do
    {clauses, acc, nid} = lower_each(ch, view, opts, acc, nid)
    {{:fn, [], fn_first_arrow_newlines(clauses, ch, cst, opts)}, acc, nid}
  end

  defp lower_kind(:stab, [args_node, body_node], _cst, view, opts, acc, nid) do
    {args, acc, nid} = lower_stab_args(args_node, view, opts, acc, nid)
    {body, acc, nid} = lower_stab_body(body_node, args_node, view, opts, acc, nid)
    {{:->, stab_arrow_meta(args_node, body_node, view, opts), [args, body]}, acc, nid}
  end

  defp lower_kind(:string, ch, _cst, view, opts, acc, nid),
    do: lower_string(ch, view, opts, acc, nid)

  defp lower_kind(:charlist, ch, cst, view, opts, acc, nid),
    do: lower_charlist(ch, cst, view, opts, acc, nid)

  defp lower_kind(:sigil, ch, cst, view, opts, acc, nid),
    do: lower_sigil(ch, cst, view, opts, acc, nid)

  # `:"..."` / `:'...'` — no interpolation lowers to the atom (atom policy); with interpolation to
  # `:erlang.binary_to_atom(<<...>>, :utf8)`.
  defp lower_kind(:quoted_atom, [inner], cst, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(cchildren(inner), view, opts, acc, nid)
    build_quoted_atom(parts, inner, cst, false, view, opts, acc, nid)
  end

  # An interpolation's inner is a block (`#{a; b}` → `{:__block__, ...}`, `#{a}` → `a`).
  defp lower_kind(:interp, ch, _cst, view, opts, acc, nid),
    do: lower_block(ch, view, opts, acc, nid)

  defp lower_kind(_other, _ch, cst, view, _opts, acc, nid), do: {error_ast(cst, view), acc, nid}

  # A string lowers to a bare binary with no interpolation, else the `<<>>` form Elixir uses:
  # fragments stay binaries; each interpolation becomes a `Kernel.to_string/1` ::-binary segment.
  defp lower_string(children, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(children, view, opts, acc, nid)
    build_string(parts, opts, acc, nid)
  end

  # A charlist lowers to a literal codepoint list with no interpolation, else to
  # `List.to_charlist([...])` where interpolations are bare `Kernel.to_string/1` (no ::-binary).
  defp lower_charlist(children, cst, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(children, view, opts, acc, nid)
    build_charlist(parts, cst, view, opts, acc, nid)
  end

  # Collect a quoted literal's parts as `{:frag, binary}` / `{:interp, ast}`, in source order.
  # Error leaves (unterminated marker) are skipped — their diagnostic is already emitted.
  defp quoted_parts_ast(children, view, opts, acc, nid) do
    {rev_parts, acc, nid} =
      Enum.reduce(children, {[], acc, nid}, fn child, {parts, a, n} ->
        lower_quoted_part(child, view, opts, parts, a, n)
      end)

    {:lists.reverse(rev_parts), acc, nid}
  end

  defp lower_quoted_part(child, view, opts, parts, acc, nid) do
    case ctag(child) do
      :token -> lower_fragment_part(child, view, parts, acc, nid)
      :node -> lower_interp_part(child, view, opts, parts, acc, nid)
      _ -> {parts, acc, nid}
    end
  end

  defp lower_fragment_part(child, view, parts, acc, nid) do
    if tk(view, ctoki(child)) in [:string_fragment, :charlist_fragment] do
      {[{:frag, tv(view, ctoki(child))} | parts], acc, nid}
    else
      {parts, acc, nid}
    end
  end

  defp lower_interp_part(child, view, opts, parts, acc, nid) do
    if ckind(child) == :interp do
      {ast, acc, nid} = lower_block(cchildren(child), view, opts, acc, nid)
      {[{:interp, ast, cspan(child)} | parts], acc, nid}
    else
      {parts, acc, nid}
    end
  end

  # Single-fragment fast path (the dominant literal shape, `"foo"`): the fragment binary IS the
  # value — skip the interp scan and the map + iodata flatten (which would copy it).
  defp build_string([{:frag, bin}], _opts, acc, nid), do: {bin, acc, nid}

  defp build_string(parts, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      {{:<<>>, [], Enum.map(parts, &string_segment(&1, opts))}, acc, nid}
    else
      {parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary(), acc, nid}
    end
  end

  defp build_charlist([{:frag, bin}], cst, view, _opts, acc, nid),
    do: finish_charlist(bin, cst, view, acc, nid)

  defp build_charlist(parts, cst, view, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      # The interpolated-charlist dot node `{:., _, [List, :to_charlist]}` anchors at the opening
      # quote (charlist span start), set UNCONDITIONALLY (matching `build_list_string` upstream,
      # which uses `meta_from_location` even without token_metadata).
      dot_meta = charlist_dot_meta(cst)

      {{{:., dot_meta, [List, :to_charlist]}, [], [Enum.map(parts, &charlist_segment(&1, opts))]},
       acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()
      finish_charlist(bin, cst, view, acc, nid)
    end
  end

  defp charlist_dot_meta(cst) do
    case cspan(cst) do
      {sl, sc, _el, _ec} -> [line: sl, column: sc]
      _ -> []
    end
  end

  # A charlist's content is decoded as UTF-8 codepoints, so a non-UTF-8 byte (e.g. `'\xFF'`,
  # which yields the raw byte rather than codepoint U+00FF) is an error — unlike a string, where
  # `<<255>>` is a valid binary. The tolerant `[255]` charlist is still produced.
  defp finish_charlist(bin, cst, view, acc, nid) do
    {acc, nid} =
      if String.valid?(bin),
        do: {acc, nid},
        else: invalid_charlist_encoding(cst, view, acc, nid)

    {safe_to_charlist(bin), acc, nid}
  end

  defp invalid_charlist_encoding(cst, view, acc, nid) do
    {_id, acc, nid} =
      Diagnostics.emit(
        acc,
        nid,
        :lowerer,
        :error,
        :invalid_charlist_encoding,
        child_span(cst, view),
        %{}
      )

    {acc, nid}
  end

  defp build_quoted_atom([{:frag, bin}], inner, _anchor, _kw?, view, opts, acc, nid),
    do: atomize_quoted(bin, inner, opts, view, acc, nid)

  defp build_quoted_atom(parts, inner, anchor, kw?, view, opts, acc, nid) do
    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      segs = Enum.map(parts, &string_segment(&1, opts))
      pos = qatom_pos(anchor, view, opts)
      head = qatom_head(anchor, kw?, view, opts)

      {{{:., pos, [:erlang, :binary_to_atom]}, Enum.concat(head, pos),
        [{:<<>>, pos, segs}, :utf8]}, acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()
      atomize_quoted(bin, inner, opts, view, acc, nid)
    end
  end

  # token_metadata for an INTERPOLATED quoted atom / keyword key (`:"a#{b}"`, `"k#{i}": v`), which
  # lowers to an `:erlang.binary_to_atom` construction. `pos` anchors at the atom/key start; the
  # call also carries the opening `delimiter:` and, for a keyword key, `format: :keyword`.
  defp qatom_pos(anchor, view, opts) do
    if tm?(opts) do
      case child_span(anchor, view) do
        {sl, sc, _el, _ec} -> [line: sl, column: sc]
        _ -> []
      end
    else
      []
    end
  end

  # Only a keyword key needs the head built here: it is lowered inline (no `finalize_node`), so its
  # `delimiter:` + `format: :keyword` must be added now. A bare `:"a#{b}"` atom literal IS finalized,
  # which supplies `delimiter:` — adding it here too would duplicate it.
  defp qatom_head(anchor, true = _kw?, view, opts) do
    if tm?(opts) do
      delim =
        case child_span(anchor, view) do
          {sl, sc, _el, _ec} ->
            head = src_slice(opts, {sl, sc}, {sl, sc + 40}) || ""

            case head do
              ":" <> rest -> delim_at(rest)
              _ -> delim_at(head)
            end

          _ ->
            nil
        end

      d = if is_binary(delim), do: [delimiter: delim], else: []
      Enum.concat(d, format: :keyword)
    else
      []
    end
  end

  defp qatom_head(_anchor, false = _kw?, _view, _opts), do: []

  defp atomize_quoted(bin, inner, opts, view, acc, nid) do
    case to_atom(bin, opts) do
      {:ok, atom} ->
        {atom, acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :nonexistent_atom,
            atom_span(inner, view),
            %{
              name: bin
            }
          )

        {{:__error__, [], %{diag_ids: [id]}}, acc, nid}
    end
  end

  defp atom_span(inner, _view), do: cspan(inner) || {1, 1, 1, 1}

  defp string_segment({:frag, bin}, _opts), do: bin

  defp string_segment({:interp, ast, span}, opts) do
    pos = interp_pos(span, opts)
    {:"::", pos, [interp_to_string(ast, span, opts), {:binary, pos, nil}]}
  end

  defp charlist_segment({:frag, bin}, _opts), do: bin
  defp charlist_segment({:interp, ast, span}, opts), do: interp_to_string(ast, span, opts)

  # The `Kernel.to_string/1` call wrapping an interpolation `#{…}`. Under `token_metadata: true` it
  # carries `from_interpolation: true` + `closing:` (the `}` = interp span end − 1), all anchored at
  # the interpolation start (the `#`). Otherwise the synthetic meta stays empty.
  defp interp_to_string(ast, span, opts) do
    pos = interp_pos(span, opts)
    callmeta = interp_call_meta(span, opts)
    {{:., pos, [Kernel, :to_string]}, callmeta, [ast]}
  end

  defp interp_pos(_span, %{token_metadata: false}), do: []
  defp interp_pos({sl, sc, _el, _ec}, _opts), do: [line: sl, column: sc]
  defp interp_pos(_other, _opts), do: []

  defp interp_call_meta(_span, %{token_metadata: false}), do: []

  defp interp_call_meta({sl, sc, el, ec}, _opts),
    do: [from_interpolation: true, closing: [line: el, column: ec - 1], line: sl, column: sc]

  defp interp_call_meta(_other, _opts), do: []

  # A sigil → `{:"sigil_<name>", [], [{:<<>>, [], segs}, modifier_charlist]}`. Content segments are
  # like a string's (the sigil macro does any further unescaping at expansion); the name atom
  # respects the atom policy. children = [start_leaf | parts... | end_leaf].
  defp lower_sigil([start_leaf | rest], cst, view, opts, acc, nid) do
    name = tv(view, ctoki(start_leaf))
    {part_children, mods} = sigil_split(rest, view)
    {parts, acc, nid} = quoted_parts_ast(part_children, view, opts, acc, nid)

    build_sigil(
      name,
      parts,
      mods,
      start_leaf,
      sigil_inner_meta(cst, mods, opts),
      view,
      opts,
      acc,
      nid
    )
  end

  # The inner `<<>>` of a sigil anchors at the sigil start; a heredoc sigil (`~s\"\"\"…\"\"\"`) also
  # carries `indentation:` there (the closing-delimiter column − 1 = span end − 4).
  defp sigil_inner_meta(cst, mods, opts) do
    if tm?(opts) do
      case cspan(cst) do
        {sl, sc, _el, ec} ->
          head = src_slice(opts, {sl, sc}, {sl, sc + 40})

          case head && opening_delimiter(:sigil, head) do
            # Heredoc sigil: `indentation:` = the closing `"""`/`'''` column − 1. The span end also
            # spans any trailing modifiers (`~r'''…'''x`), so discount their length too.
            d when is_binary(d) and byte_size(d) == 3 ->
              [indentation: ec - String.length(mods) - 4, line: sl, column: sc]

            _ ->
              [line: sl, column: sc]
          end

        _ ->
          []
      end
    else
      []
    end
  end

  # The modifiers live on the trailing `:sigil_end` leaf (last child), if the run closed.
  defp sigil_split([], _view), do: {[], ""}

  defp sigil_split(children, view) do
    [last | rev] = :lists.reverse(children)

    case last do
      {:token, idx, _f, _d} ->
        if tk(view, idx) == :sigil_end,
          do: {:lists.reverse(rev), tv(view, idx) || ""},
          else: {children, ""}

      _ ->
        {children, ""}
    end
  end

  defp build_sigil(name, parts, mods, start_leaf, inner_meta, view, opts, acc, nid) do
    case to_atom("sigil_" <> name, opts) do
      {:ok, atom} ->
        {{atom, [], [{:<<>>, inner_meta, sigil_segments(parts, opts)}, safe_to_charlist(mods)]},
         acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :nonexistent_atom,
            name_span(start_leaf, view),
            %{
              name: "sigil_" <> name
            }
          )

        {{:__error__, error_meta(start_leaf, view), %{diag_ids: [id]}}, acc, nid}
    end
  end

  # A sigil's `<<>>` always has at least one (possibly empty) binary segment (`~s()` → [""]).
  defp sigil_segments([], _opts), do: [""]
  defp sigil_segments(parts, opts), do: Enum.map(parts, &string_segment(&1, opts))

  defp lower_block([], _view, _opts, acc, nid), do: {{:__block__, [], []}, acc, nid}

  defp lower_block([only], view, opts, acc, nid) do
    {ast, acc, nid} = lower(only, view, opts, acc, nid)
    {wrap_splice(attach_eoe(ast, only, view, opts)), acc, nid}
  end

  defp lower_block(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_stmts(children, view, opts, acc, nid)
    {{:__block__, [], asts}, acc, nid}
  end

  # Like `lower_each`, but attaches `end_of_expression` to each statement (token_metadata).
  defp lower_stmts(children, view, opts, acc, nid) do
    {rev, acc, nid} =
      Enum.reduce(children, {[], acc, nid}, fn child, {asts, a, n} ->
        {ast, a, n} = lower(child, view, opts, a, n)
        {[attach_eoe(ast, child, view, opts) | asts], a, n}
      end)

    {:lists.reverse(rev), acc, nid}
  end

  # Parentheses are transparent in the AST (they only carry metadata upstream).
  # A paren is a statement block: empty => empty block, one => the expr (transparent), many =>
  # `__block__`. A trailing recovered `:missing` (no `)`) is skipped — its diagnostic is emitted.
  defp lower_paren(children, cst, view, opts, acc, nid) do
    children = Enum.reject(children, &(ctag(&1) == :missing))

    # A paren of stab clauses (`(a -> b; c -> d)`) lowers to the bare clause LIST `[{:->, …}, …]`,
    # not a statement block.
    if Enum.any?(children, &stab_node?/1) do
      lower_each(children, view, opts, acc, nid)
    else
      {ast, acc, nid} = lower_block(children, view, opts, acc, nid)
      {acc, nid} = maybe_empty_paren_warn(ast, cst, opts, acc, nid)
      {add_parens_meta(wrap_paren_negation(ast), children, cst, opts), acc, nid}
    end
  end

  # `()` (also `( )`, `(\n)`) is an empty parenthesised expression — Elixir warns it's invalid; pass
  # a value like `nil` instead. But `(;)` is a `;`-block (a different grammar production) and does
  # NOT warn; the parser records that `;` token as a CST flag (`( # ;\n)` has no `;` token and
  # warns, as upstream). Scoped to paren EXPRESSIONS: stab-clause-head `()` (`fn () -> …`) is
  # lowered elsewhere, not through here.
  defp maybe_empty_paren_warn({:__block__, _meta, []}, cst, _opts, acc, nid) do
    if CST.has_semicolon?(cst) do
      {acc, nid}
    else
      {_id, acc, nid} =
        Diagnostics.emit(acc, nid, :parser, :warning, :empty_paren, cspan(cst), %{})

      {acc, nid}
    end
  end

  defp maybe_empty_paren_warn(_ast, _cst, _opts, acc, nid), do: {acc, nid}

  # Empty parens. `()` is Elixir's `empty_paren` → `{:__block__, [parens: …], []}`; `(;)` is the
  # `open_paren ';' close_paren` rule → `{:__block__, [closing: …, line, column], []}`. Both lower to
  # an empty block here; the parser's `has_semicolon` flag tells them apart (only meaningful under
  # token_metadata; otherwise the empty block stays bare, matching `()` no-tm).
  defp add_parens_meta({:__block__, _meta, []}, [], cst, opts) do
    with true <- tm?(opts),
         {sl, sc, el, ec} <- cspan(cst) do
      closing = [line: el, column: ec - 1]

      if CST.has_semicolon?(cst),
        do: {:__block__, [closing: closing, line: sl, column: sc], []},
        else: {:__block__, [parens: [closing: closing, line: sl, column: sc]], []}
    else
      _ -> {:__block__, [], []}
    end
  end

  # A single-expression parenthesised group (`(a + b)`) records the parens on the inner node's meta
  # as `parens: [line, column, closing: …]` (the `(`…`)` span), matching Elixir. Each nesting layer
  # prepends another entry (`((a))` → two), outermost first. Multi-statement parens are a block and
  # carry `closing:` instead (handled as a node), so only the single-child case attaches `parens:`.
  # A MULTI-statement parenthesised group lowers to a `__block__` that corresponds to real `(`…`)`
  # delimiters; unlike the implicit top-level block it carries `closing:` (the `)`) and a
  # `line:`/`column:` anchor at the `(`. (A single-expression `__block__` here is the synthetic
  # `(not x)` negation wrapper — Elixir leaves that one anchorless, so it must NOT match.)
  defp add_parens_meta({:__block__, meta, stmts}, [_, _ | _], cst, opts) do
    parens_block(meta, stmts, cst, opts)
  end

  # `(unquote_splicing(x))` is a single-child paren that `wrap_splice` turns into a `__block__`; it is
  # still a real `(`…`)` group (unlike the `(not x)` negation wrapper), so it gets the block anchor.
  defp add_parens_meta(
         {:__block__, meta, [{:unquote_splicing, _, _}] = stmts},
         [_single],
         cst,
         opts
       ),
       do: parens_block(meta, stmts, cst, opts)

  # `(not x)` / `(! x)` is `wrap_paren_negation`'s synthetic `__block__` (empty meta, a single unary
  # node) — Elixir leaves it anchorless, so it gets NO `parens:` entry.
  defp add_parens_meta({:__block__, [], [{op, _, [_]}]} = ast, [_single], _cst, _opts)
       when op in [:not, :!],
       do: ast

  # Any other single-expression parenthesised group records `parens: [line, column, closing: …]` on
  # the inner node's meta (each nesting layer prepends one; `((a))` → two, outermost first). This
  # includes encoder-wrapped literals (`({a, b})`) and a paren around a multi-statement block.
  defp add_parens_meta({f, meta, a}, [_single], cst, opts) do
    if tm?(opts) do
      case cspan(cst) do
        {sl, sc, el, ec} ->
          {f, [{:parens, [closing: [line: el, column: ec - 1], line: sl, column: sc]} | meta], a}

        _ ->
          {f, meta, a}
      end
    else
      {f, meta, a}
    end
  end

  defp add_parens_meta(ast, _children, _cst, _opts), do: ast

  defp parens_block(meta, stmts, cst, opts) do
    case tm?(opts) && cspan(cst) do
      {sl, sc, el, ec} ->
        anchor = [closing: [line: el, column: ec - 1], line: sl, column: sc]
        {:__block__, Enum.concat(anchor, meta), stmts}

      _ ->
        {:__block__, meta, stmts}
    end
  end

  defp stab_node?(cst), do: ctag(cst) == :node and ckind(cst) == :stab

  # A parenthesised boolean negation is wrapped in a `__block__` — `(not x)` => `{:__block__, [],
  # [{:not, [], [x]}]}`, likewise `(! x)` — preserving the parenthesisation the `not in`
  # deprecation relies on. (`-`/`+` and binary ops are NOT wrapped.)
  defp wrap_paren_negation({op, _, [_]} = ast) when op in [:not, :!], do: {:__block__, [], [ast]}
  defp wrap_paren_negation(ast), do: ast

  # A sole empty `()` head means zero patterns (`fn () when g`/`fn () ->`); anything else is kept.
  defp strip_empty_paren_head([{:node, :paren, _sp, [], _f, _d}]), do: []
  defp strip_empty_paren_head(pats), do: pats

  defp lower_binary([lhs, op_leaf, rhs], view, opts, acc, nid) do
    cond do
      op_atom(op_leaf, view) == :in and negation_unary?(lhs, view) ->
        lower_deprecated_not_in(lhs, op_leaf, rhs, view, opts, acc, nid)

      op_atom(op_leaf, view) == :"//" ->
        lower_slash_slash(lhs, op_leaf, rhs, view, opts, acc, nid)

      true ->
        {l, acc, nid} = lower(lhs, view, opts, acc, nid)
        {r, acc, nid} = lower(rhs, view, opts, acc, nid)
        meta = Enum.concat(op_newlines(lhs, op_leaf, rhs, view, opts), op_meta(op_leaf, view))
        {{op_atom(op_leaf, view), meta, [l, r]}, acc, nid}
    end
  end

  # A binary operator records `newlines:` when a line break is adjacent to it — the count after the
  # operator (operator at line end) if any, else the count before it (operator at line start). The
  # count is the line delta between the operand and the operator (blank lines included).
  # `newlines:` on a binary operator: the count AFTER the operator (operator at line end) if any,
  # else the count BEFORE it (operator at line start). `gap_newlines` stops at the next token, so
  # scanning from the operator end yields the after-count and from the lhs end the before-count.
  defp op_newlines(lhs, op_leaf, rhs, view, opts) do
    if tm?(opts) do
      {_l1, _c1, lel, lec} = child_span(lhs, view)
      {osl, _osc, oel, oec} = child_span(op_leaf, view)

      # `newlines:` is non-zero only if a line break is ADJACENT to the operator. Gate the
      # (comment-aware) `gap_newlines` scans on span line numbers we already have, so a SINGLE-LINE
      # operator — the common case — does no eol scan at all. `after_n` (a newline between op and rhs)
      # can only exist if the rhs starts on a later line than the op ends; the before-count only if
      # the op starts on a later line than the lhs ends. On operator-dense files these scans
      # (`gap_newlines` → `line_classify`) were ~4% of tm CPU.
      rhs_sl =
        case child_span(rhs, view) do
          {sl, _, _, _} -> sl
          # unknown rhs span (degenerate) → force the after-scan, preserving the old behaviour
          _ -> oel + 1
        end

      after_n = if rhs_sl > oel, do: gap_newlines(opts, oel, oec), else: 0

      n =
        cond do
          after_n > 0 -> after_n
          osl > lel -> gap_newlines(opts, lel, lec)
          true -> 0
        end

      if n > 0, do: [newlines: n], else: []
    else
      []
    end
  end

  # `a..b//c` is the ternary step range `{:..//, _, [a, b, c]}` — i.e. a `//` whose left side is a
  # range. We test the LOWERED lhs (so a parenthesised range works too: `(a..b)//c`).
  defp lower_slash_slash(lhs, op_leaf, rhs, view, opts, acc, nid) do
    {l, acc, nid} = lower(lhs, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)

    case l do
      # Valid only as the range step: `a..b//c` (lhs a 2-element range, incl. through parens). The
      # `..//` reuses the range's `..` node meta (Elixir's `build_op` reuses it), so it inherits the
      # `parens:` annotation of a parenthesised `..` (`(1..2)//3`). Drop only the lhs `range:`, so
      # `..//` still gets its own (wider) range.
      {:.., m, [a, b]} ->
        {{:..//, Keyword.delete(m, :range), [a, b, r]}, acc, nid}

      # `//` is NOT a general binary operator — Elixir rejects `a // b`, `a..b//c//d`,
      # `a..(b // c)`. Toxic2 is tolerant: emit an error and keep a best-effort `//` node (P1/P5).
      _ ->
        {_id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :misplaced_step_op,
            name_span(op_leaf, view),
            %{}
          )

        {{:"//", op_meta(op_leaf, view), [l, r]}, acc, nid}
    end
  end

  # `not a in b` (an `in` whose LHS is a bare unary `not`) is the deprecated spelling of
  # `not(a in b)`. Rewrite it here (P5) and emit a deprecation `:warning`. `(not a) in b`
  # (parenthesized) is a `:paren` lhs, so it is not matched and keeps its literal meaning.
  defp lower_deprecated_not_in(
         {:node, :unary_op, _sp, [neg_leaf, operand], _f, _d},
         op_leaf,
         rhs,
         view,
         opts,
         acc,
         nid
       ) do
    neg = tv(view, ctoki(neg_leaf))
    {o, acc, nid} = lower(operand, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)
    span = tspan(view, ctoki(op_leaf)) || {1, 1, 1, 1}

    {_id, acc, nid} =
      Diagnostics.emit(acc, nid, :lowerer, :warning, :deprecated_not_in, span, %{})

    # `not x in y` (deprecated): since Elixir 1.20 the outer `not`/`!` keeps its OWN meta (the
    # `not`/`!` token), while the inner `in` is anchored at the `in` operator. Upstream's
    # rearrange_uop keeps these UNCONDITIONALLY (line always, column per `columns:`) — not only
    # under token_metadata (K9), like every neighbouring operator lowering.
    {{neg, op_meta(neg_leaf, view), [{:in, op_meta(op_leaf, view), [o, r]}]}, acc, nid}
  end

  # `not a in b` / `!a in b` — a bare `not`/`!` left of `in` is the membership-negation form
  # `not(a in b)` / `!(a in b)` (`not` binds looser than `in` here). Parenthesising the operand
  # (`(not a) in b`) gives a `:paren` lhs, which is not matched, so it keeps its literal meaning.
  defp negation_unary?({:node, :unary_op, _sp, [op_leaf, _operand], _f, _d}, view),
    do: tv(view, ctoki(op_leaf)) in [:not, :!]

  defp negation_unary?(_lhs, _view), do: false

  defp lower_unary([op_leaf, operand], view, opts, acc, nid) do
    {o, acc, nid} = lower(operand, view, opts, acc, nid)

    case op_atom(op_leaf, view) do
      # `//operand` captures `Kernel.//2` (division). Mirrors `build_unary_op('//')` in the yrl: the
      # nested `{:/, [c+1], [{:/, [c], nil}, operand]}` — outer `/` anchors one column past the `//`
      # token, inner `/` at the token column (line shared).
      :"//" ->
        m = op_meta(op_leaf, view)
        {{:/, bump_column(m), [{:/, m, nil}, o]}, acc, nid}

      atom ->
        {{atom, op_meta(op_leaf, view), [o]}, acc, nid}
    end
  end

  # Nullary `..` / `...` (no operand): `{:.., [], []}` / `{:..., [], []}`.
  defp lower_unary([op_leaf], view, _opts, acc, nid),
    do: {{op_atom(op_leaf, view), op_meta(op_leaf, view), []}, acc, nid}

  # A list literal lowers to the Elixir list of its lowered elements.
  defp lower_list(children, view, opts, acc, nid), do: lower_each(children, view, opts, acc, nid)

  # 2-tuples are literal `{a, b}`; all other arities use `{:{}, [], elems}`. Trailing keyword
  # pairs collapse into a single keyword-list element (`{1, a: 1}` => `{1, [a: 1]}`), like calls.
  defp lower_tuple(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_args(children, view, opts, acc, nid)

    case asts do
      [a, b] -> {{a, b}, acc, nid}
      _ -> {{:{}, [], asts}, acc, nid}
    end
  end

  # `f(args)` => `{fun_atom, meta, lowered_args}`. The callee name respects the atom policy.
  defp lower_call([callee | arg_children], view, opts, acc, nid) do
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    lower_callee(ctag(callee), callee, args, view, opts, acc, nid)
  end

  # A bare identifier callee is a named call `{name, meta, args}` (atom via the atom policy).
  defp lower_callee(:token, callee, args, view, opts, acc, nid) do
    idx = ctoki(callee)
    name = tv(view, idx)

    case to_atom(name, opts) do
      {:ok, fun} ->
        {{fun, tmeta(view, idx), args}, acc, nid}

      :error ->
        {id, acc, nid} =
          Diagnostics.emit(
            acc,
            nid,
            :lowerer,
            :error,
            :nonexistent_atom,
            name_span(callee, view),
            %{
              name: name
            }
          )

        {{:__error__, tmeta(view, idx), %{diag_ids: [id]}}, acc, nid}
    end
  end

  # A node callee is the "double parens" call `f(a)(b)` => `{f(a), [], [b]}`: lower the callee
  # expression and wrap it.
  defp lower_callee(_tag, callee, args, view, opts, acc, nid) do
    {callee_ast, acc, nid} = lower(callee, view, opts, acc, nid)
    {{callee_ast, callee_anchor(callee_ast, opts), args}, acc, nid}
  end

  # A call whose callee is itself an expression (`a.unquote(b)(c)`, `(expr)(c)`) anchors where its
  # callee does — Elixir reuses the callee's `line:`/`column:`, not the whole call's span start.
  defp callee_anchor(_callee, %{token_metadata: false}), do: []

  defp callee_anchor({_f, meta, _a}, _opts) when is_list(meta),
    do: Keyword.take(meta, [:line, :column])

  defp callee_anchor(_callee, _opts), do: []

  # Alias chain: `{:__aliases__, meta, segments}`. A leading alias segment contributes its atom;
  # a leading non-alias base (e.g. `foo.Bar`) contributes its lowered AST as the first segment.
  # Alias segment atoms ARE gated by `existing_atoms_only` — the oracle rejects a fresh module name
  # too — so a segment that would mint a new atom yields an error node + `:nonexistent_atom`.
  defp lower_alias([first | rest], view, opts, acc, nid) do
    meta = error_meta(first, view)

    if ctag(first) == :token and tk(view, ctoki(first)) == :alias do
      build_alias([first | rest], meta, view, opts, acc, nid)
    else
      {base_ast, acc, nid} = lower(first, view, opts, acc, nid)
      {acc, nid} = maybe_atom_dot_alias(base_ast, rest, view, acc, nid)

      case seg_atoms(rest, view, opts) do
        {:ok, atoms} ->
          case base_ast do
            # A base that itself lowered to an alias — only parens produce this (`(Foo).Bar`,
            # `(Foo.Bar).Baz`) — splices into ONE flat alias (upstream's build_dot_alias
            # concatenates the segment lists), keeping the base's meta (parens included) and
            # re-pointing `last:` at the new final segment.
            {:__aliases__, bmeta, base_segs} ->
              {{:__aliases__, replace_alias_last(bmeta, List.last(rest), view, opts),
                prepend(base_segs, atoms)}, acc, nid}

            _ ->
              meta = alias_base_meta(first, meta, view, opts)

              {{:__aliases__, with_alias_last(meta, List.last(rest), view, opts),
                [base_ast | atoms]}, acc, nid}
          end

        {:error, leaf} ->
          alias_seg_error(leaf, view, acc, nid)
      end
    end
  end

  # An alias with a NON-alias base (`__MODULE__.Any`, `unquote(x).Foo`) anchors at the base's span
  # end (the `.` before the first alias segment), not the base start — matching Elixir.
  defp alias_base_meta(_first, meta, _view, %{token_metadata: false}), do: meta

  defp alias_base_meta(first, meta, view, _opts) do
    case child_span(first, view) do
      {_sl, _sc, el, ec} -> [line: el, column: ec]
      _ -> meta
    end
  end

  defp build_alias(leaves, meta, view, opts, acc, nid) do
    case seg_atoms(leaves, view, opts) do
      {:ok, atoms} ->
        {{:__aliases__, with_alias_last(meta, List.last(leaves), view, opts), atoms}, acc, nid}

      {:error, leaf} ->
        alias_seg_error(leaf, view, acc, nid)
    end
  end

  # `last:` — the position of the alias's final segment (`Foo.Bar.Baz` → `Baz`; single `Foo` → `Foo`).
  defp with_alias_last(meta, _last_leaf, _view, %{token_metadata: false}), do: meta

  defp with_alias_last(meta, {:token, idx, _f, _d}, view, _opts) do
    {sl, sc, _el, _ec} = tspan(view, idx)
    [{:last, [line: sl, column: sc]} | meta]
  end

  defp with_alias_last(meta, _last_leaf, _view, _opts), do: meta

  # Update a spliced base's `last:` in place (the base alias always carries one under
  # `token_metadata`), preserving key order so the meta list compares equal to upstream's.
  defp replace_alias_last(meta, _last_leaf, _view, %{token_metadata: false}), do: meta

  defp replace_alias_last(meta, {:token, idx, _f, _d}, view, _opts) do
    {sl, sc, _el, _ec} = tspan(view, idx)
    List.keyreplace(meta, :last, 0, {:last, [line: sl, column: sc]})
  end

  defp replace_alias_last(meta, _last_leaf, _view, _opts), do: meta

  # Atomize every alias segment through the gated policy; the first that fails (a fresh atom under
  # `existing_atoms_only`, or invalid UTF-8) short-circuits to `{:error, that_leaf}`.
  defp seg_atoms(leaves, view, opts) do
    Enum.reduce_while(leaves, {:ok, []}, fn leaf, {:ok, atoms} ->
      case to_atom(tv(view, ctoki(leaf)), opts) do
        {:ok, atom} -> {:cont, {:ok, [atom | atoms]}}
        :error -> {:halt, {:error, leaf}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, :lists.reverse(rev)}
      err -> err
    end
  end

  defp alias_seg_error(leaf, view, acc, nid),
    do: nonexistent_atom(leaf, view, tv(view, ctoki(leaf)), acc, nid)

  # `:foo.Bar` / `nil.Bar` — a bare ATOM literal cannot be followed by an alias (Elixir rejects it;
  # to keep the atom in its name, it must be quoted). Non-atom bases (`__MODULE__.X`, `x.X`, `@x.X`)
  # are fine. Mirrors elixir_parser's `build_dot_alias` `is_atom(Atom)` guard. We keep the
  # `__aliases__` tree (tolerant) but record the error so strict mode rejects it.
  defp maybe_atom_dot_alias(base, [seg | _], view, acc, nid) when is_atom(base) do
    {_id, acc, nid} =
      Diagnostics.emit(acc, nid, :lowerer, :error, :atom_dot_alias, name_span(seg, view), %{})

    {acc, nid}
  end

  defp maybe_atom_dot_alias(_base, _rest, _view, acc, nid), do: {acc, nid}

  # `a.b` / `a.b(args)` => `{{:., m, [base, name]}, m, args}` (zero-arg form is just `args = []`).
  defp lower_remote_call([base, name_leaf | arg_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    dotmeta = remote_dot_meta(base, view, opts)
    remote_name(ctag(name_leaf), name_leaf, base_ast, args, dotmeta, view, opts, acc, nid)
  end

  # Under `token_metadata: true` the `.` operator anchors at the dot itself (between the base and the
  # member name), not at the name — matching Elixir. Off, the dot reuses the name meta (unchanged).
  defp remote_dot_meta(_base, _view, %{token_metadata: false}), do: nil

  defp remote_dot_meta(base, view, opts) do
    case child_span(base, view) do
      {_sl, _sc, bel, bec} ->
        # Scan forward from the base's end for the `.` — multi-line, so a dot that starts a new line
        # (`a\n.b`) anchors at the DOT (line 2, col 1), matching Elixir, rather than at the member.
        case scan_op(opts, bel, bec, ".", src_line_count(opts)) do
          [line: dl, column: dc] -> [line: dl, column: dc]
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp remote_name(:token, name_leaf, base_ast, args, dotmeta, view, opts, acc, nid) do
    idx = ctoki(name_leaf)
    meta = tmeta(view, idx)

    case member_atom(tk(view, idx), tv(view, idx), opts) do
      {:ok, name} -> {{{:., dotmeta || meta, [base_ast, name]}, meta, args}, acc, nid}
      :error -> name_error(name_leaf, view, acc, nid)
    end
  end

  # A recovered missing name (`foo.` with nothing after) — its diagnostic was already emitted by
  # the parser; lower to an error node (P5: total, never raises).
  defp remote_name(:missing, name_leaf, _base_ast, _args, _dotmeta, view, _opts, acc, nid),
    do: name_error(name_leaf, view, acc, nid)

  # `a."foo"` — the function name is a quoted literal. No interpolation allowed (Elixir rejects
  # `a."f#{x}"`): atomize the concatenated fragments; on interpolation, error + best-effort.
  defp remote_name(:node, name_node, base_ast, args, dotmeta, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(cchildren(name_node), view, opts, acc, nid)

    if Enum.any?(parts, &match?({:interp, _, _}, &1)) do
      {id, acc, nid} =
        Diagnostics.emit(
          acc,
          nid,
          :lowerer,
          :error,
          :interpolated_remote_name,
          atom_span(name_node, view),
          %{}
        )

      {{:__error__, [], %{diag_ids: [id]}}, acc, nid}
    else
      bin = parts |> Enum.map(fn {:frag, b} -> b end) |> IO.iodata_to_binary()

      case to_atom(bin, opts) do
        {:ok, name} ->
          dm = dotmeta || []
          {{{:., dm, [base_ast, name]}, quoted_name_meta(name_node, view, opts), args}, acc, nid}

        :error ->
          name_error(name_node, view, acc, nid)
      end
    end
  end

  # A quoted remote-call member (`foo."bar"(x)`): the call meta anchors at the quoted name and
  # carries its opening `delimiter:` (the `closing:` for the `)` is added later by `closing_keys`).
  defp quoted_name_meta(name_node, view, opts) do
    case tm?(opts) && child_span(name_node, view) do
      {sl, sc, _el, _ec} = span ->
        Enum.concat(quoted_key_delimiter(span, opts), line: sl, column: sc)

      _ ->
        []
    end
  end

  # The atom for a remote-call member. Identifiers carry a binary name (atom policy applies);
  # reserved-word members (`a.true`, `a.when`, `a.do`) carry the atom in the token itself — the
  # value for word operators / `:literal` / block labels, or the kind for `do`/`end`/`fn`.
  defp member_atom(:identifier, value, opts), do: to_atom(value, opts)
  defp member_atom(:literal, value, _opts), do: {:ok, value}
  defp member_atom(kind, nil, _opts) when kind in [:do, :end, :fn], do: {:ok, kind}
  defp member_atom(_kind, value, _opts) when is_atom(value), do: {:ok, value}

  # `a.(args)` => `{{:., m, [base]}, m, args}`.
  defp lower_anon_call([base | arg_children], cst, view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)

    # `lower_call_args` (not `lower_args`) so a trailing do-block becomes `[do: …]` — `f.() do … end`.
    {args, acc, nid} = lower_call_args(arg_children, view, opts, acc, nid)
    {dotmeta, callmeta} = anon_call_metas(base, cst, error_meta(base, view), view, opts)
    {{{:., dotmeta, [base_ast]}, callmeta, args}, acc, nid}
  end

  # `f.(…)` — under `token_metadata: true` the dot anchors at the `.` (between base and `(`) and the
  # call meta carries `closing:` (the `)` = node-span end − 1). Off, both reuse the base meta.
  defp anon_call_metas(_base, _cst, base_meta, _view, %{token_metadata: false}),
    do: {base_meta, base_meta}

  defp anon_call_metas(base, cst, base_meta, view, opts) do
    dot = remote_dot_meta(base, view, opts) || base_meta
    {dot, Enum.concat(anon_call_closing(cst, opts), dot)}
  end

  # `closing:` = the `)` of the arg list. With a trailing do-block (`f.(1) do end`) the node span runs
  # past `end`, so locate the `)` BEFORE the `do` instead of the span's last char.
  defp anon_call_closing(cst, opts) do
    if Enum.any?(cchildren(cst), &match?({:node, :do_block, _, _, _, _}, &1)) do
      close_paren_before_do(cst, opts)
    else
      case cspan(cst) do
        {_sl, _sc, el, ec} -> [closing: [line: el, column: ec - 1]]
        _ -> []
      end
    end
  end

  defp name_error(name_leaf, view, acc, nid) do
    idx = ctoki(name_leaf)

    {id, acc, nid} =
      Diagnostics.emit(
        acc,
        nid,
        :lowerer,
        :error,
        :nonexistent_atom,
        name_span(name_leaf, view),
        %{
          name: tv(view, idx)
        }
      )

    {{:__error__, tmeta(view, idx), %{diag_ids: [id]}}, acc, nid}
  end

  # A keyword pair `k: v` => `{key_atom, lowered_value}`. (Keyword key atoms are not gated.)
  defp lower_kw_pair([key, val], view, opts, acc, nid) do
    {acc, nid} = maybe_nested_no_parens_warn(val, view, opts, acc, nid)
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    kw_key(ctag(key), key, v, view, opts, acc, nid)
  end

  # `foo a: bar b` / `f(a: bar b)` — a keyword whose VALUE is a no-parens call is ambiguous (do the
  # following commas belong to the inner or outer call?); Elixir warns to add parentheses. The
  # CST still carries the `:no_parens` category here (the AST erases it).
  # Upstream's warn_nested_no_parens_keyword SKIPS the warning under a literal_encoder — the
  # encoded key is a 3-tuple, not an atom, so its guard never matches (K13); formatter-grade
  # tooling relies on that.
  defp maybe_nested_no_parens_warn(_val, _view, %{literal_encoder: enc}, acc, nid)
       when enc != nil,
       do: {acc, nid}

  defp maybe_nested_no_parens_warn(val, view, _opts, acc, nid) do
    if no_parens_call_cst?(val) do
      {_id, acc, nid} =
        Diagnostics.emit(
          acc,
          nid,
          :parser,
          :warning,
          :nested_no_parens_keyword,
          child_span(val, view),
          %{}
        )

      {acc, nid}
    else
      {acc, nid}
    end
  end

  # Mirrors the parser's `no_parens_expr?`: a no-parens call with ≥2 POSITIONAL arg groups (`bar b,
  # c`), or whose single positional arg is itself such a call. A trailing run of keyword pairs is
  # ONE argument, so a kw-only call (`defstruct a: 1, b: 2`, the value of `do: …`) is NOT multi-arg
  # — and a plain single-arg call (`bar b`) is fine.
  defp no_parens_call_cst?(node) do
    kind = ctag(node) == :node and ckind(node)

    if kind in [:np_call, :remote_call] and CST.category(node) == :no_parens do
      args = np_call_args_cst(kind, cchildren(node))
      {kws, positional} = Enum.split_with(args, &kw_pair_cst?/1)
      groups = length(positional) + if kws == [], do: 0, else: 1

      cond do
        positional != [] and groups >= 2 -> true
        match?([_], positional) and kws == [] -> no_parens_call_cst?(hd(positional))
        true -> false
      end
    else
      false
    end
  end

  defp np_call_args_cst(:np_call, [_callee | args]), do: args
  defp np_call_args_cst(:remote_call, [_base, _name | args]), do: args
  defp np_call_args_cst(_kind, _children), do: []

  defp kw_pair_cst?(node), do: ctag(node) == :node and ckind(node) == :kw_pair

  defp kw_key(:token, key_leaf, v, view, opts, acc, nid) do
    idx = ctoki(key_leaf)

    case to_atom(tv(view, idx), opts) do
      :error ->
        {err, acc, nid} = nonexistent_atom(key_leaf, view, tv(view, idx), acc, nid)
        {{err, v}, acc, nid}

      {:ok, atom} ->
        case opts.literal_encoder do
          nil ->
            {{atom, v}, acc, nid}

          enc ->
            # A keyword key is a literal atom; Elixir tags its meta `format: :keyword` and the
            # encoded key turns the `k: v` shorthand into an explicit `{encoded_key, v}` pair.
            span = tspan(view, idx)
            meta = [{:format, :keyword} | literal_meta(span, opts)]
            {key_ast, acc, nid} = run_encoder_meta(enc, atom, meta, span, acc, nid)
            {{key_ast, v}, acc, nid}
        end
    end
  end

  # A quoted kw key (`"foo": v`) atomizes like a quoted atom: no interpolation => the atom; with
  # interpolation => the `binary_to_atom` construction (so the pair is `{key_expr, v}`).
  defp kw_key(:node, key_node, v, view, opts, acc, nid) do
    {parts, acc, nid} = quoted_parts_ast(cchildren(key_node), view, opts, acc, nid)
    {key_ast, acc, nid} = build_quoted_atom(parts, key_node, key_node, true, view, opts, acc, nid)
    {key_ast, acc, nid} = encode_quoted_kw_key(key_ast, key_node, opts, acc, nid)
    {{key_ast, v}, acc, nid}
  end

  # A static quoted kw key (`"foo": v`) lowers to a bare atom — encode it like a plain kw key. An
  # interpolated key (`"#{x}": v`) is a `binary_to_atom` construction (not an atom), left as-is.
  defp encode_quoted_kw_key(atom, key_node, opts, acc, nid) when is_atom(atom) do
    case opts.literal_encoder do
      nil ->
        {atom, acc, nid}

      enc ->
        span = cspan(key_node)
        meta = [{:format, :keyword} | literal_meta(span, opts)]

        run_encoder_meta(
          enc,
          atom,
          Enum.concat(quoted_key_delimiter(span, opts), meta),
          span,
          acc,
          nid
        )
    end
  end

  defp encode_quoted_kw_key(other, _key_node, _opts, acc, nid), do: {other, acc, nid}

  # A quoted keyword key (`"foo": v`) carries the opening `delimiter:` under token_metadata, read at
  # the key's span start (the `"` / `'`), before `format: :keyword`.
  defp quoted_key_delimiter({sl, sc, _el, _ec}, %{token_metadata: true} = opts) do
    case src_slice(opts, {sl, sc}, {sl, sc + 4}) do
      h when is_binary(h) -> if d = delim_at(h), do: [delimiter: d], else: []
      _ -> []
    end
  end

  defp quoted_key_delimiter(_span, _opts), do: []

  # Call arguments: a trailing run of keyword pairs is collected into one keyword-list arg
  # (`f(1, a: 2)` => `[1, [a: 2]]`); regular args lower normally.
  #
  # ONE `:lists.last` decides the shape. The overwhelmingly common case — no keyword tail, no
  # do-block — then lowers the list as it stands: no peel, no reverse, no concat, no allocation
  # beyond the result. Only a list that actually HAS a tail pays for the peel, and it pays once:
  # the old shape ran `:lists.last` twice (`pop_do_block` + `lower_args`, 110 k calls per stdlib
  # pass) plus `drop_last`, `reverse`, `split_while`, two more reverses and `Enum.concat`.
  defp lower_args([], _view, _opts, acc, nid), do: {[], acc, nid}

  defp lower_args(children, view, opts, acc, nid) do
    if kw_pair?(:lists.last(children)),
      do: lower_peeled(:lists.reverse(children), nil, view, opts, acc, nid),
      else: lower_each(children, view, opts, acc, nid)
  end

  defp kw_pair?(cst), do: ctag(cst) == :node and ckind(cst) == :kw_pair

  # Call args, where a trailing `:do_block` child becomes the final `[do: ..., else: ...]` arg.
  defp lower_call_args([], _view, _opts, acc, nid), do: {[], acc, nid}

  defp lower_call_args(children, view, opts, acc, nid) do
    case :lists.last(children) do
      {:node, :do_block, _sp, _ch, _f, _d} = db ->
        [_db | plain_rev] = :lists.reverse(children)
        lower_peeled(plain_rev, db, view, opts, acc, nid)

      last ->
        if kw_pair?(last),
          do: lower_peeled(:lists.reverse(children), nil, view, opts, acc, nid),
          else: lower_each(children, view, opts, acc, nid)
    end
  end

  # `rev_children` is the arg list reversed (do-block already off the front), so peeling the
  # trailing keyword run off its HEAD hands the pairs back in source order for free.
  defp lower_peeled(rev_children, db, view, opts, acc, nid) do
    {kw, reg_rev} = peel_kw(rev_children, [])
    {rev, acc, nid} = lower_rev(:lists.reverse(reg_rev), view, opts, acc, nid, [])
    {rev, acc, nid} = lower_kw_arg(kw, view, opts, acc, nid, rev)
    {rev, acc, nid} = lower_do_arg(db, view, opts, acc, nid, rev)
    {:lists.reverse(rev), acc, nid}
  end

  defp peel_kw([c | rest] = rev, kw) do
    if kw_pair?(c), do: peel_kw(rest, [c | kw]), else: {kw, rev}
  end

  defp peel_kw([], kw), do: {kw, []}

  # Both push onto the REVERSED result accumulator, so `lower_peeled`'s single `:lists.reverse`
  # replaces the `Enum.concat(args, [kw])` copy of the whole arg list.
  defp lower_kw_arg([], _view, _opts, acc, nid, rev), do: {rev, acc, nid}

  defp lower_kw_arg(kw, view, opts, acc, nid, rev) do
    {kw_list, acc, nid} = lower_each(kw, view, opts, acc, nid)
    {[kw_list | rev], acc, nid}
  end

  defp lower_do_arg(nil, _view, _opts, acc, nid, rev), do: {rev, acc, nid}

  defp lower_do_arg(db, view, opts, acc, nid, rev) do
    {kw, acc, nid} = lower_do_block(db, view, opts, acc, nid)
    {[kw | rev], acc, nid}
  end

  # `do ... else ... end` => keyword list `[do: body, else: body, ...]`. A trailing `:missing`
  # (recovered missing `end`) is skipped — its diagnostic was already emitted by the parser.
  defp lower_do_block(db, view, opts, acc, nid) do
    {pairs, acc, nid} =
      Enum.reduce(cchildren(db), {[], acc, nid}, fn
        {:node, :do_section, _sp, _ch, _f, _d} = section, {ps, a, n} ->
          {pair, a, n} = lower_section(section, view, opts, a, n)
          {[pair | ps], a, n}

        _other, accum ->
          accum
      end)

    {:lists.reverse(pairs), acc, nid}
  end

  defp lower_section({:node, :do_section, _sp, [label_leaf, body], _f, _d}, view, opts, acc, nid) do
    {b, acc, nid} =
      lower_section_body(body, section_block_meta(label_leaf, view, opts), view, opts, acc, nid)

    {key, acc, nid} = section_label(label_leaf, view, opts, acc, nid)
    {{key, b}, acc, nid}
  end

  # Since Elixir 1.20 the `do` section's body block is anchored at the `do` token
  # (`build_stab(.., meta_from_token(do))`): a multi-statement / empty body's `__block__` carries
  # `[line, column]` of `do`, and a single-expression body carries `parens: [line, column]`. Other
  # sections (`else`/`catch`/…) pass `[]`. Token-metadata only; non-tm meta is normalized away.
  defp section_block_meta(label_leaf, view, opts) do
    idx = ctoki(label_leaf)

    if tm?(opts) and tk(view, idx) == :do do
      {l, c, _, _} = tspan(view, idx)
      [line: l, column: c]
    else
      []
    end
  end

  # The `do:`/`else:`/`rescue:`/… key of a do-block. It is a literal atom too, so under a literal
  # encoder it gets encoded (plain `line:`/`column:` meta — Elixir does NOT tag these `:keyword`).
  defp section_label(label_leaf, view, opts, acc, nid) do
    idx = ctoki(label_leaf)
    atom = if tk(view, idx) == :do, do: :do, else: tv(view, idx)

    case opts.literal_encoder do
      nil ->
        {atom, acc, nid}

      enc ->
        span = tspan(view, idx)
        run_encoder_meta(enc, atom, literal_meta(span, opts), span, acc, nid)
    end
  end

  # A `:do_body` lowers like a block (nil / expr / __block__); `:do_clauses` lowers to a list of
  # `{:->, ...}` clauses. `block_meta` is the `do`-token anchor (see `section_block_meta/3`).
  defp lower_section_body(
         {:node, :do_clauses, _sp, clauses, _f, _d},
         _block_meta,
         view,
         opts,
         acc,
         nid
       ),
       do: lower_each(clauses, view, opts, acc, nid)

  defp lower_section_body({:node, :do_body, _sp, stmts, _f, _d}, block_meta, view, opts, acc, nid) do
    case stmts do
      # An empty section body is `{:__block__, block_meta, []}` (`foo do end`), NOT nil — Elixir
      # distinguishes an empty block from a missing one.
      [] ->
        {{:__block__, block_meta, []}, acc, nid}

      [one] ->
        {ast, acc, nid} = lower(one, view, opts, acc, nid)

        # A sole arity-one splice takes the block meta ON the `__block__` wrapper (upstream
        # `build_block`'s splice case receives BlockMeta directly); everything else gets the
        # single-expression `parens:` treatment.
        case wrap_splice(attach_eoe(ast, one, view, opts), block_meta) do
          {:__block__, ^block_meta, [{:unquote_splicing, _, [_]}]} = wrapped ->
            {wrapped, acc, nid}

          other ->
            {section_parens(other, block_meta), acc, nid}
        end

      many ->
        {{:__block__, _m, asts}, acc, nid} = wrap_block(lower_stmts(many, view, opts, acc, nid))
        {{:__block__, block_meta, asts}, acc, nid}
    end
  end

  # A single-expression `do` body carries `parens: <do-token meta>` (Elixir 1.20). Only an expr that
  # already has a metadata list (a `{op, meta, args}` 3-tuple) takes it — a bare literal does not.
  defp section_parens(ast, []), do: ast

  defp section_parens({op, meta, args}, block_meta) when is_list(meta),
    do: {op, [{:parens, block_meta} | meta], args}

  defp section_parens(ast, _block_meta), do: ast

  # `<<...>>` => `{:<<>>, [], elems}` (segments incl. `::` are ordinary expressions).
  # Trailing keyword pairs collapse into one keyword-list element (`<<a, k: 1>>` => `[a, [k: 1]]`).
  defp lower_bitstring(children, view, opts, acc, nid) do
    {asts, acc, nid} = lower_args(children, view, opts, acc, nid)
    {{:<<>>, [], asts}, acc, nid}
  end

  # `a[b]` => `{{:., m, [Access, :get]}, m, [base, index]}`.
  defp lower_access([base, idx | _missing], cst, view, opts, acc, nid) do
    {b, acc, nid} = lower(base, view, opts, acc, nid)
    {k, acc, nid} = lower_bracket_arg(idx, view, opts, acc, nid)
    dm = access_dot_meta(base, idx, cst, view, opts)
    {{{:., dm, [Access, :get]}, dm, [b, k]}, acc, nid}
  end

  # `build_access_arg` (yrl) passes a `kw_data` bracket arg RAW — it does NOT wrap the keyword list
  # in `handle_literal`, so the keyword list is unencoded (each key/value is still encoded, but the
  # outer list is not). A non-kw bracket arg (`a[[1]]`) IS a list literal and stays encoded.
  defp lower_bracket_arg(idx, view, opts, acc, nid) do
    if kw_data_list?(idx) do
      lower_each(cchildren(idx), view, opts, acc, nid)
    else
      lower(idx, view, opts, acc, nid)
    end
  end

  # A bracket `kw_data` arg is a `:list` node whose children are ALL keyword pairs (the `[ ]` are the
  # bracket-access delimiters, not a list literal). An empty list or any non-kw element means it is a
  # real list literal (`a[[]]`, `a[[1]]`) and must keep the encoding.
  defp kw_data_list?({:node, :list, _sp, [_ | _] = children, _f, _d}),
    do: Enum.all?(children, &match?({:node, :kw_pair, _, _, _, _}, &1))

  defp kw_data_list?(_idx), do: false

  # The span of a CST child, whether a node (`CST.span/1`) or a bare token leaf (via the view).
  defp child_span({:token, idx, _f, _d}, view), do: tspan(view, idx)
  defp child_span(child, _view), do: cspan(child)

  # `foo[bar]` => `{{:., dotmeta, [Access, :get]}, [], [foo, bar]}`. Under `token_metadata: true`
  # the dot meta carries `from_brackets: true` + `closing:` (the `]` = node-span end − 1), anchors
  # at the opening `[` (= the index list child's span start — the base may be separated from the
  # bracket by whitespace: `f() [0]`), and records comment-aware opening `newlines:`.
  defp access_dot_meta(_base, _idx, _cst, _view, %{token_metadata: false}), do: []

  defp access_dot_meta(base, idx, cst, view, opts) do
    with {_, _, bel, bec} <- child_span(base, view),
         {isl, _, _, _} <- child_span(idx, view),
         [line: bl, column: bc] <- scan_op(opts, bel, bec, "[", isl),
         {_, _, el, ec} <- cspan(cst) do
      tail = [closing: [line: el, column: ec - 1], line: bl, column: bc]

      case gap_newlines(opts, bl, bc + 1) do
        n when n > 0 -> [{:from_brackets, true}, {:newlines, n} | tail]
        _ -> [{:from_brackets, true} | tail]
      end
    else
      _ -> []
    end
  end

  # `%{...}` => `{:%{}, [], entries}`; entries lower to `{key, value}` 2-tuples.
  defp lower_map(children, view, opts, acc, nid) do
    {entries, acc, nid} = lower_each(children, view, opts, acc, nid)
    {{:%{}, [], entries}, acc, nid}
  end

  # `%{base | ...}` => `{:%{}, [], [{:|, [], [base, update_entries]}]}`.
  defp lower_map_update([base | entry_children], view, opts, acc, nid) do
    {base_ast, acc, nid} = lower(base, view, opts, acc, nid)
    {entries, acc, nid} = lower_each(entry_children, view, opts, acc, nid)
    {{:%{}, [], [{:|, cons_meta(base, view, opts), [base_ast, entries]}]}, acc, nid}
  end

  # The `|` of a map update (`%{m | …}`) anchors at the bar, found just past the base in the source.
  defp cons_meta(base, view, opts) do
    if tm?(opts) do
      with {_sl, _sc, el, ec} <- child_span(base, view),
           [line: bl, column: bc] = pos <- scan_op(opts, el, ec, "|", el + 3) do
        after_n = gap_newlines(opts, bl, bc + 1)
        n = if after_n > 0, do: after_n, else: gap_newlines(opts, el, ec)
        if n > 0, do: [{:newlines, n} | pos], else: pos
      else
        _ -> []
      end
    else
      []
    end
  end

  # `%Name{...}` => `{:%, [], [name, map]}`.
  defp lower_struct([name, map_node], view, opts, acc, nid) do
    {name_ast, acc, nid} = lower(name, view, opts, acc, nid)
    {map_ast, acc, nid} = lower(map_node, view, opts, acc, nid)
    {{:%, [], [name_ast, map_ast]}, acc, nid}
  end

  # Stab clause head -> the arg list. A `when` guard wraps the patterns: `[{:when, [], [pats, g]}]`.
  # A trailing keyword run in the patterns is grouped into one keyword-list arg (`fn x, a: 1 -> …`
  # => `[x, [a: 1]]`), matching call/list args; the guard (always last) stays a separate element.
  # A clause-head `when` guard anchors at the `when` keyword (between the last pattern and the guard).
  defp when_meta(args_node, pats, guard, view, opts) do
    with true <- tm?(opts),
         {_, _, pel, pec} <- pats |> List.last() |> then(&(&1 && child_span(&1, view))),
         {gsl, _, _, _} <- child_span(guard, view) do
      case scan_op(opts, pel, pec, "when", gsl) do
        [line: wl, column: wc] = w ->
          after_n = gap_newlines(opts, wl, wc + 4)

          n =
            cond do
              after_n > 0 -> after_n
              stab_parens_bounds(args_node, view) != nil -> 0
              true -> gap_newlines(opts, pel, pec)
            end

          if n > 0, do: [{:newlines, n} | w], else: w

        w ->
          w
      end
    else
      _ -> []
    end
  end

  defp lower_stab_args(args_node, view, opts, acc, nid) do
    {args, acc, nid} = do_lower_stab_args(args_node, view, opts, acc, nid)
    {unwrap_splice_head(args), acc, nid}
  end

  # `unwrap_splice` (yrl): a stab head whose sole arg is a `__block__` wrapping a lone splice — the
  # parenthesised form `((unquote_splicing(x)) -> …)` — is unwrapped back to the bare splice (the
  # `__block__` wrapper from the inner paren is stripped). `(unquote_splicing(x) -> …)` never grows
  # the wrapper in the first place, so it is unaffected.
  defp unwrap_splice_head([{:__block__, _, [{:unquote_splicing, _, _} = splice]}]), do: [splice]
  defp unwrap_splice_head(args), do: args

  defp do_lower_stab_args(args_node, view, opts, acc, nid) do
    case cchildren(args_node) do
      [{:node, :stab_when, _sp, when_ch, _f, _d}] ->
        {pats, [guard]} = Enum.split(when_ch, length(when_ch) - 1)

        # `fn () when g -> …`: an empty parenthesised head is ZERO patterns, so `when` wraps just
        # the guard (`{:when, [], [g]}`), mirroring the bare `fn () -> …` => `[]` case below.
        {pat_asts, acc, nid} = lower_args(strip_empty_paren_head(pats), view, opts, acc, nid)
        {guard_ast, acc, nid} = lower(guard, view, opts, acc, nid)

        {[
           {:when, when_meta(args_node, pats, guard, view, opts),
            Enum.concat(pat_asts, [guard_ast])}
         ], acc, nid}

      # `fn () -> ... end`: an empty parenthesised head is ZERO args (`[]`), not one block arg.
      [{:node, :paren, _sp, [], _f, _d}] ->
        {[], acc, nid}

      children ->
        lower_args(children, view, opts, acc, nid)
    end
  end

  # Stab clause body -> nil (empty), the expression (one), or a `__block__` (many).
  defp lower_stab_body(body_node, args_node, view, opts, acc, nid) do
    case cchildren(body_node) do
      [] ->
        # An empty stab body (`fn -> end`) is the implicit `nil` clause body — `handle_literal(nil,
        # StabToken)` upstream, i.e. encoded via the literal_encoder with the `->` token's position
        # (when an encoder is set; bare `nil` otherwise).
        encode_implicit_nil(args_node, body_node, view, opts, acc, nid)

      # A LEADING `;` (`fn x -> ; end`, `fn x -> ; 1 end`) is an empty first body expression:
      # the same implicit nil as an empty body — anchored at the `->`, with the semicolon as its
      # `end_of_expression` (F7). Any following statements join it in a `__block__`.
      [{:node, :empty_stmt, _sp, _ch, _f, _d} = semi | rest] ->
        {nil_ast, acc, nid} = encode_implicit_nil(args_node, body_node, view, opts, acc, nid)
        nil_ast = attach_semi_eoe(nil_ast, semi, opts)

        case rest do
          [] ->
            {nil_ast, acc, nid}

          rest ->
            {{:__block__, _m, asts}, acc, nid} =
              wrap_block(lower_stmts(rest, view, opts, acc, nid))

            {{:__block__, [], [nil_ast | asts]}, acc, nid}
        end

      [one] ->
        {ast, acc, nid} = lower(one, view, opts, acc, nid)
        {wrap_splice(attach_eoe(ast, one, view, opts)), acc, nid}

      many ->
        wrap_block(lower_stmts(many, view, opts, acc, nid))
    end
  end

  # `end_of_expression` for the implicit nil of a leading `;` body: the eoe scan starts AT the
  # semicolon (the nil is zero-width just before it), so the `;` itself becomes the terminator.
  defp attach_semi_eoe({f, meta, a}, semi, opts) do
    with true <- tm?(opts),
         {sl, sc, _, _} <- cspan(semi),
         [_ | _] = kw <- scan_eoe(opts, sl, sc, 0, false, nil) do
      {f, Enum.concat(kw, meta), a}
    else
      _ -> {f, meta, a}
    end
  end

  defp attach_semi_eoe(ast, _semi, _opts), do: ast

  # The implicit `nil` body of an empty stab clause is encoded through the literal_encoder (if any),
  # anchored at the `->` token — matching `handle_literal(nil, StabToken)` upstream. With no encoder
  # it stays bare `nil`.
  defp encode_implicit_nil(args_node, body_node, view, opts, acc, nid) do
    case opts.literal_encoder do
      nil ->
        {nil, acc, nid}

      enc ->
        meta = arrow_anchor(args_node, body_node, view, opts)
        run_encoder_meta(enc, nil, meta, nil, acc, nid)
    end
  end

  # The `->` token's `[line:, column:]` (for anchoring the implicit-nil body). Reuses the same
  # source scan as `stab_arrow_meta`, but is needed even without token_metadata (the literal_encoder
  # runs in default mode too).
  defp arrow_anchor(args_node, body_node, view, opts) do
    with {line, col} <- arrow_scan_start(args_node, view),
         last <- with({bsl, _, _, _} <- child_span(body_node, view), do: bsl, else: (_ -> line)),
         [line: _, column: _] = arrow <- scan_op(opts, line, col, "->", last) do
      arrow
    else
      _ -> []
    end
  end

  defp wrap_block({asts, acc, nid}), do: {{:__block__, [], asts}, acc, nid}

  # `unquote_splicing(x)` as the SOLE statement of a block / paren / clause body is wrapped in a
  # `__block__` (it is only valid in a list/block context) — `(unquote_splicing(x))` => `{:__block__,
  # [], [it]}`. As a list element (`[unquote_splicing(x)]`) it is NOT wrapped (a different path).
  # Upstream's `build_block` special case matches EXACTLY ONE argument: `unquote_splicing()` and
  # `unquote_splicing(x, y)` stay ordinary calls, and a do-block call is never a splice.
  defp wrap_splice(ast), do: wrap_splice(ast, [])

  defp wrap_splice({:unquote_splicing, _, [_]} = ast, meta), do: {:__block__, meta, [ast]}
  defp wrap_splice(ast, _meta), do: ast

  # `a not in b` => `{:not, [], [{:in, [], [a, b]}]}` (the canonical Elixir shape; the rewrite
  # lives here, not in the parser — P5).
  defp lower_not_in([lhs, rhs], view, opts, acc, nid) do
    {l, acc, nid} = lower(lhs, view, opts, acc, nid)
    {r, acc, nid} = lower(rhs, view, opts, acc, nid)
    {not_m, in_m} = not_in_meta(lhs, rhs, view, opts)
    {{:not, not_m, [{:in, in_m, [l, r]}]}, acc, nid}
  end

  # `x not in y`: `not` and `in` are separate keywords after the lhs (`x not in …`); anchor each at
  # its keyword position, found by scanning the source just past the lhs.
  defp not_in_meta(_lhs, _rhs, _view, %{token_metadata: false}), do: {[], []}

  defp not_in_meta(lhs, rhs, view, opts) do
    with {_, _, lel, lec} <- child_span(lhs, view),
         {rsl, _, _, _} <- child_span(rhs, view),
         [line: nl, column: nc] = not_m <- scan_op(opts, lel, lec, "not", rsl) do
      # Upstream records the newline(s) BEFORE the fused `not` (`x\nnot in y` =>
      # `{:not, [newlines: 1, …]}`, from the tokenizer's previous_was_eol) — comment-aware.
      not_m =
        case gap_newlines(opts, lel, lec) do
          n when n > 0 -> [{:newlines, n} | not_m]
          _ -> not_m
        end

      {not_m, scan_op(opts, nl, nc + 3, "in", rsl)}
    else
      _ -> {[], []}
    end
  end

  # `key => value` map entry => `{key, value}` 2-tuple.
  defp lower_assoc([key, val], view, opts, acc, nid) do
    {k, acc, nid} = lower(key, view, opts, acc, nid)
    {v, acc, nid} = lower(val, view, opts, acc, nid)
    {{put_assoc(k, key, view, opts), v}, acc, nid}
  end

  # `assoc:` — for a `key => value` pair, the key's meta records the `=>` operator position (found in
  # the source just past the key). Only carried under `token_metadata: true`, and only when the key
  # lowered to a node with a metadata slot (a bare un-encoded literal has nowhere to put it).
  defp put_assoc(k, _key, _view, %{token_metadata: false}), do: k

  defp put_assoc({f, meta, a}, key, view, opts) do
    case assoc_pos(key, view, opts) do
      nil -> {f, meta, a}
      pos -> {f, [{:assoc, pos} | meta], a}
    end
  end

  defp put_assoc(k, _key, _view, _opts), do: k

  defp assoc_pos(key, view, opts) do
    # Scan forward from the key's end for `=>` — multi-line, so an `=>` on a later line than the key
    # (`%{:a\n=> 1}`) still records `assoc:` at the `=>` position (matching Elixir).
    with {_sl, _sc, kel, kec} <- child_span(key, view),
         [line: _, column: _] = pos <- scan_op(opts, kel, kec, "=>", src_line_count(opts)) do
      pos
    else
      _ -> nil
    end
  end

  # Thread the accumulator while lowering a list of children. Direct recursion rather than an
  # Enum.reduce closure (no per-element apply / closure frame) — this is the central child-list
  # walker, called from lists, tuples, maps, clauses, args, blocks, …
  defp lower_each(children, view, opts, acc, nid),
    do: lower_each(children, view, opts, acc, nid, [])

  defp lower_each([child | rest], view, opts, acc, nid, asts) do
    {ast, acc, nid} = lower(child, view, opts, acc, nid)
    lower_each(rest, view, opts, acc, nid, [ast | asts])
  end

  defp lower_each([], _view, _opts, acc, nid, asts), do: {:lists.reverse(asts), acc, nid}

  # `lower_each` that stops at the REVERSED accumulator, so the arg-list path can push the keyword
  # and do-block args on and reverse once — instead of `Enum.concat(args, [kw])` re-copying the
  # whole arg list. Kept as its own loop rather than a wrapper around a shared one: a wrapper would
  # add a return tuple per `lower_each` call, and `lower_each` runs on every container node.
  defp lower_rev([child | rest], view, opts, acc, nid, asts) do
    {ast, acc, nid} = lower(child, view, opts, acc, nid)
    lower_rev(rest, view, opts, acc, nid, [ast | asts])
  end

  defp lower_rev([], _view, _opts, acc, nid, asts), do: {asts, acc, nid}

  # --- error nodes (invalid CST; never raises) ---------------------------

  defp error_ast(cst, view),
    do: {:__error__, error_meta(cst, view), %{diag_ids: CST.diag_ids(cst)}}

  defp error_meta(cst, view) do
    case ctag(cst) do
      :node -> span_meta(cspan(cst))
      :token -> tmeta(view, ctoki(cst))
      :missing -> tmeta(view, CST.anchor_index(cst))
    end
  end

  # --- helpers -----------------------------------------------------------

  defp op_atom(op_leaf, view), do: tv(view, ctoki(op_leaf))
  defp op_meta(op_leaf, view), do: tmeta(view, ctoki(op_leaf))

  # `[line: l, column: c]` => `[line: l, column: c + 1]` (the `//` capture's outer `/` anchor). A
  # column-less meta (columns disabled) is returned unchanged.
  defp bump_column(meta) do
    Enum.map(meta, fn
      {:column, c} -> {:column, c + 1}
      kv -> kv
    end)
  end

  defp name_span(cst, view), do: tspan(view, ctoki(cst)) || {1, 1, 1, 1}

  # Read the start line/col straight off the token tuple. Going through `Tokens.span/2` allocated a
  # throwaway `{sl,sc,el,ec}` per node just to drop `el,ec` — tprof flagged it as ~quarter of all
  # `Token.span` calls in lowering.
  defp tmeta(view, idx) do
    case tt(view, idx) do
      {_kind, sl, sc, _el, _ec, _v} -> [line: sl, column: sc]
      :eof -> []
    end
  end

  defp span_meta({sl, sc, _el, _ec}), do: [line: sl, column: sc]
  defp span_meta(_), do: []

  defp to_atom(bin, opts) do
    if opts.existing_atoms_only do
      {:ok, String.to_existing_atom(bin)}
    else
      {:ok, String.to_atom(bin)}
    end
  rescue
    ArgumentError -> :error
  end

  # Totality helper (P5): `String.to_charlist` RAISES on invalid UTF-8, but a tolerant lexer/parser
  # may carry truncated bytes (`'<bad utf8>'`). Charlists don't touch the atom table, so a
  # non-raising best-effort (raw byte list) is fine; atom names instead route through the gated
  # `to_atom/2` (which returns `:error` rather than minting on bad input).
  defp safe_to_charlist(bin) when is_binary(bin) do
    if String.valid?(bin), do: String.to_charlist(bin), else: :erlang.binary_to_list(bin)
  end
end
