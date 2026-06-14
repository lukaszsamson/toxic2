defmodule Toxic2.SemanticTokens do
  @moduledoc """
  LSP semantic-token classification (see `SEMANTIC_TOKENS.md`).

  Produces a **sparse, name-level** stream of classified spans on top of toxic2's tokens + green
  CST. The editor layer (e.g. ElixirLS) maps the `type`/`modifiers` atoms to a legend, converts
  the codepoint columns to the negotiated position encoding (UTF-16), and delta-encodes. This
  module deliberately emits nothing for structural tokens (operators, delimiters, control
  keywords, comments, string/sigil interiors) — TextMate keeps those.

  Every emitted span is **single-line and non-overlapping** by construction (string/heredoc
  interiors are never spanned and Elixir comments are single-line), so the editor never needs
  `multilineTokenSupport`/`overlappingTokenSupport`.

  `type` is one of:
  `:namespace :type :class :function :method :macro :property :number :variable :atom :attribute
   :typespec :sigil :capture`. Modifiers are a subset of
  `:definition :declaration :readonly :documentation :deprecated :defaultLibrary`.
  """

  alias Toxic2.{Tokens, Parser, CST}

  @type type ::
          :namespace
          | :type
          | :class
          | :function
          | :method
          | :macro
          | :property
          | :number
          | :variable
          | :atom
          | :attribute
          | :typespec
          | :sigil
          | :capture
  @type modifier ::
          :definition | :declaration | :readonly | :documentation | :deprecated | :defaultLibrary
  @type token ::
          {pos_integer(), pos_integer(), pos_integer(), pos_integer(), type(), [modifier()]}

  # Closed name-sets — the honest slice of "defaultLibrary" knowledge that needs no symbol table.
  # These all lex as :identifier (they are macros/special forms, NOT reserved words), so the
  # call-callee rule MUST consult them or it would repaint `if`/`case`/`def` as `function`.
  @def_family ~w(def defp defmacro defmacrop defguard defguardp)
  @macro_def ~w(defmacro defmacrop)
  @module_def ~w(defmodule defprotocol defimpl)
  @directives ~w(alias import require use)
  @control ~w(if unless case cond for with try receive quote unquote unquote_splicing fn raise throw)
  @doc_attrs ~w(moduledoc doc typedoc)
  @spec_attrs ~w(spec callback macrocallback)
  @type_attrs ~w(type typep opaque)
  # Block/control option keys in their inline keyword form (`if x, do: y, else: z`).
  @block_keys ~w(do else rescue catch after)

  @doc """
  Classify `source` into source-ordered, single-line semantic spans
  `{start_line, start_col, end_line, end_col, type, modifiers}` (1-based codepoint columns,
  end-exclusive). Tolerant: never raises (inherits toxic2's totality).
  """
  @spec tokens(binary(), keyword()) :: [token()]
  def tokens(source, opts \\ []) when is_binary(source) do
    {view, _warnings} = Tokens.from_source(source, opts)
    {cst, _diags} = Parser.parse_tokens(view)
    roles = role_map(cst, view)
    emit(view, roles)
  end

  # --- role walk: token_index => {type, modifiers} -----------------------------------------

  # A single pre-order walk. Authoritative roles are assigned at the *parent* node and the generic
  # fallbacks (call-callee `function`, the `variable` gate) use `Map.put_new`, so the more specific
  # role — assigned first because the walk is pre-order — always wins.
  defp role_map(cst, view), do: walk(cst, true, view, %{})

  # Top-level statements: the `variable` gate is per-statement — a statement with any error
  # suppresses all of its `variable` highlighting (mid-edit safety).
  defp walk({:node, :expr_list, _sp, ch, _f, _d}, _clean, view, acc) do
    Enum.reduce(ch, acc, fn child, acc -> walk(child, not CST.has_error?(child), view, acc) end)
  end

  defp walk({:node, kind, _sp, ch, _f, _d}, clean, view, acc) do
    acc = node_roles(kind, ch, view, acc)
    Enum.reduce(ch, acc, fn child, acc -> walk(child, clean, view, acc) end)
  end

  # Identifier leaf with no structural role, inside a clean statement → `variable`.
  defp walk({:token, i, _f, _d}, clean, view, acc) do
    if clean and Tokens.kind(view, i) == :identifier,
      do: Map.put_new(acc, i, {:variable, []}),
      else: acc
  end

  defp walk(_other, _clean, _view, acc), do: acc

  # --- per-node role assignment ------------------------------------------------------------

  defp node_roles(kind, [callee | args], view, acc) when kind in [:call, :np_call] do
    acc =
      case leaf_id(callee, view) do
        {ci, v} when v in @def_family -> mark_def_target(args, v, view, skip(acc, ci))
        {ci, v} when v in @module_def -> mark_module_target(args, view, skip(acc, ci))
        # directives (`alias`/`import`/…) and control forms (`if`/`case`/…): emit nothing for the
        # callee — TextMate's keyword scope is correct and richer. `:skip` blocks the `variable`
        # gate too, so these never leak through as variables.
        {ci, v} when v in @directives -> skip(acc, ci)
        {ci, v} when v in @control -> skip(acc, ci)
        {i, _v} -> Map.put_new(acc, i, {:function, []})
        nil -> acc
      end

    # Block/control option keys (`do:`/`else:`/…) as *call arguments* are structural keyword
    # syntax, not data — leave them to TextMate. A `[do: 1]` literal keeps `property` because there
    # the kw_pair sits under a `:list`, not a call.
    skip_block_option_keys(args, view, acc)
  end

  defp node_roles(:remote_call, [base, name | args], view, acc) do
    case leaf_id(name, view) do
      {i, _v} -> Map.put_new(acc, i, {remote_member_type(base, args), []})
      nil -> acc
    end
  end

  defp node_roles(:alias, ch, view, acc) do
    ch
    |> Enum.filter(&(CST.token_index(&1) && Tokens.kind(view, CST.token_index(&1)) == :alias))
    |> Enum.map(&CST.token_index/1)
    |> mark_alias_segments(acc)
  end

  defp node_roles(:unary_op, [op | rest], view, acc) do
    case op do
      {:token, i, _f, _d} ->
        case Tokens.kind(view, i) do
          :at_op -> mark_at(i, rest, view, acc)
          :capture_op -> mark_capture(rest, view, acc)
          _ -> acc
        end

      _ ->
        acc
    end
  end

  defp node_roles(:sigil, ch, view, acc) do
    case Enum.find(
           ch,
           &(CST.token_index(&1) && Tokens.kind(view, CST.token_index(&1)) == :sigil_start)
         ) do
      nil -> acc
      leaf -> Map.put_new(acc, CST.token_index(leaf), {:sigil, []})
    end
  end

  defp node_roles(_kind, _ch, _view, acc), do: acc

  # --- specific markers --------------------------------------------------------------------

  # `def foo(x)` => np_call[def, call[foo, x], ...]; target = name inside the header (first arg).
  defp mark_def_target([header | _], defword, view, acc) do
    type = if defword in @macro_def, do: :macro, else: :function

    case def_name_index(header, view) do
      nil -> acc
      i -> Map.put_new(acc, i, {type, [:definition]})
    end
  end

  defp mark_def_target([], _defword, _view, acc), do: acc

  defp def_name_index({:node, k, _sp, [c | _], _f, _d}, view) when k in [:call, :np_call],
    do: def_name_index(c, view)

  # Guarded head: `def foo(x) when guard` wraps the head in a `when` binary-op; the name is the
  # first child (the head before `when`). Only unwrap genuine when-guards.
  defp def_name_index({:node, :binary_op, _sp, [head | _] = ch, _f, _d}, view) do
    if Enum.any?(
         ch,
         &(CST.token_index(&1) && Tokens.kind(view, CST.token_index(&1)) == :when_op)
       ),
       do: def_name_index(head, view),
       else: nil
  end

  defp def_name_index({:token, i, _f, _d}, view),
    do: if(Tokens.kind(view, i) == :identifier, do: i, else: nil)

  defp def_name_index(_other, _view), do: nil

  # `defmodule Foo.Bar do…` => target = alias node; last segment is the defined class.
  defp mark_module_target([{:node, :alias, _sp, ch, _f, _d} | _], view, acc) do
    case alias_indices(ch, view) do
      [] ->
        acc

      idxs ->
        last = List.last(idxs)
        acc = Map.put_new(acc, last, {:class, [:definition]})
        idxs |> Enum.drop(-1) |> Enum.reduce(acc, &Map.put_new(&2, &1, {:namespace, []}))
    end
  end

  defp mark_module_target(_args, _view, acc), do: acc

  # Module attribute: `@name …`. The `@` (at_index) AND the name share the `attribute` token so the
  # whole `@name` colors as one unit — otherwise the `@` is left to TextMate and looks disjoint.
  # The operand is a single np_call whose callee is the attr name.
  defp mark_at(
         at_index,
         [{:node, :np_call, _sp, [{:token, i, _f, _d} | sig], _nf, _nd} | _],
         view,
         acc
       ) do
    name = Tokens.value(view, i)
    mods = attr_mods(name)
    acc = acc |> Map.put_new(at_index, {:attribute, mods}) |> Map.put_new(i, {:attribute, mods})

    cond do
      name in @spec_attrs -> mark_signature(:typespec, Enum.at(sig, 0), view, acc)
      name in @type_attrs -> mark_signature(:type, Enum.at(sig, 0), view, acc)
      true -> acc
    end
  end

  defp mark_at(at_index, [{:token, i, _f, _d} | _], view, acc) do
    acc = Map.put_new(acc, at_index, {:attribute, []})
    if Tokens.kind(view, i) == :identifier, do: Map.put_new(acc, i, {:attribute, []}), else: acc
  end

  defp mark_at(at_index, _rest, _view, acc), do: Map.put_new(acc, at_index, {:attribute, []})

  # `@spec foo(...) :: t` / `@type t :: …` — mark the named subject (function/type), not the `@name`.
  defp mark_signature(type, sig, view, acc) do
    subject =
      case sig do
        {:node, :binary_op, _sp, [first | _], _f, _d} -> first
        other -> other
      end

    idx =
      case subject do
        {:node, k, _sp, [c | _], _f, _d} when k in [:call, :np_call] -> id_index(c, view)
        {:token, i, _f, _d} -> if(Tokens.kind(view, i) in [:identifier, :alias], do: i, else: nil)
        _ -> nil
      end

    if idx, do: Map.put_new(acc, idx, {type, [:declaration]}), else: acc
  end

  # `&foo/1` => unary_op[capture_op, binary_op[foo, /, 1]]; mark the captured name.
  defp mark_capture(
         [{:node, :binary_op, _sp, [{:token, i, _f, _d} | _], _bf, _bd} | _],
         view,
         acc
       ),
       do:
         if(Tokens.kind(view, i) == :identifier,
           do: Map.put_new(acc, i, {:capture, []}),
           else: acc
         )

  defp mark_capture(_rest, _view, acc), do: acc

  defp mark_alias_segments([], acc), do: acc

  defp mark_alias_segments(idxs, acc) do
    last = List.last(idxs)
    acc = Map.put_new(acc, last, {:class, []})
    idxs |> Enum.drop(-1) |> Enum.reduce(acc, &Map.put_new(&2, &1, {:namespace, []}))
  end

  # Remote member: `Foo.bar()`/`conn.assigns` — UX-driven. Call-shape ⇒ method; else lean on the
  # base shape (capitalized alias base ⇒ method, variable base ⇒ property).
  defp remote_member_type(_base, args) when args != [], do: :method
  defp remote_member_type({:node, :alias, _sp, _ch, _f, _d}, _args), do: :method
  defp remote_member_type(_base, _args), do: :property

  # --- emission ----------------------------------------------------------------------------

  defp emit(view, roles) do
    size = Tokens.size(view)

    for i <- 0..(size - 1)//1,
        size > 0,
        {type, mods} = classify(i, view, roles),
        is_atom(type),
        type != :skip,
        span = emit_span(view, i, type, mods),
        span != nil do
      span
    end
  end

  defp classify(i, view, roles) do
    case Map.get(roles, i) do
      {_t, _m} = role -> role
      nil -> lexical(Tokens.kind(view, i))
    end
  end

  defp emit_span(view, i, type, mods) do
    case Tokens.span(view, i) do
      {sl, sc, el, ec} when el == sl ->
        {sl, sc, el, narrow_end(view, i, type, sc, ec), type, mods}

      _ ->
        # Multi-line (shouldn't happen for what we emit) — drop defensively.
        nil
    end
  end

  # `:kw_identifier` span includes the trailing `:`; highlight only the key text (value length).
  defp narrow_end(view, i, :property, sc, ec) do
    case Tokens.value(view, i) do
      v when is_binary(v) -> sc + String.length(v)
      _ -> ec
    end
  end

  defp narrow_end(_view, _i, _type, _sc, ec), do: ec

  # Lexical defaults — purely by token kind, no CST needed.
  defp lexical(:atom), do: {:atom, [:readonly]}
  defp lexical(:kw_identifier), do: {:property, []}
  defp lexical(:int), do: {:number, []}
  defp lexical(:flt), do: {:number, []}
  defp lexical(:char), do: {:number, []}
  defp lexical(:capture_int), do: {:capture, [:readonly]}
  defp lexical(:sigil_start), do: {:sigil, []}
  defp lexical(:alias), do: {:class, []}
  defp lexical(_kind), do: {:skip, []}

  # --- leaf helpers ------------------------------------------------------------------------

  defp leaf_id({:token, i, _f, _d}, view) do
    if Tokens.kind(view, i) == :identifier, do: {i, Tokens.value(view, i)}, else: nil
  end

  defp leaf_id(_other, _view), do: nil

  defp id_index({:token, i, _f, _d}, view),
    do: if(Tokens.kind(view, i) == :identifier, do: i, else: nil)

  defp id_index(_other, _view), do: nil

  defp alias_indices(ch, view) do
    for leaf <- ch,
        i = CST.token_index(leaf),
        i != nil,
        Tokens.kind(view, i) == :alias,
        do: i
  end

  defp attr_mods(name) when name in @doc_attrs, do: [:documentation]
  defp attr_mods("deprecated"), do: [:deprecated]
  defp attr_mods(_name), do: []

  # Skip the keys of `kw_pair` call-arguments whose key is a block/control option (`do:`/`else:`/…)
  # so TextMate keeps its keyword scope. Only direct call args — `[do: 1]` (kw_pair under a list)
  # is untouched and stays `property`.
  defp skip_block_option_keys(args, view, acc) do
    Enum.reduce(args, acc, fn
      {:node, :kw_pair, _sp, [{:token, i, _f, _d} | _], _kf, _kd}, acc ->
        if Tokens.kind(view, i) == :kw_identifier and Tokens.value(view, i) in @block_keys,
          do: skip(acc, i),
          else: acc

      _other, acc ->
        acc
    end)
  end

  # Mark a token index as deliberately un-emitted (lets the TextMate layer keep it) and block the
  # `variable` gate from later claiming it.
  defp skip(acc, i), do: Map.put_new(acc, i, {:skip, []})
end
