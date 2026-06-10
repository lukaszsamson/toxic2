# Differential audit of Toxic2 vs the official elixir_parser.yrl grammar (Elixir 1.20 oracle).
# Cases are derived rule-by-rule from ~/elixir/lib/elixir/src/elixir_parser.yrl.
# Run: mix run grammar_audit.exs

defmodule GrammarAudit do
  def cases do
    [
      # --- grammar / expr_list / eoe ---
      "", ";", "\n", ";\n;", "1;2", "1\n2", "1;\n2", "1;", "1\n", "a;b;c",
      "\n\n1\n\n",

      # --- no_parens calls: one / many / ambig (grammar lines 252-261, 500-529) ---
      "f a", "f a, b", "f g a", "f g a, b", "f g h a, b", "f a, b: 1",
      "f a, b, c: 1, d: 2", "f(g a, b)", "f a, b: g(1)",
      "f -1", "f +1", "f -a", "f not a", "f ! a", "f ~~~1",
      "f.g a, b", "Mod.f a, b", "a.b.c d, e",
      "f g(a), b", "f g(a, b)",
      # op_identifier: ambiguous_op meta (build_call op_identifier with single arg)
      "f -a, b",
      # kw in no_parens
      "f a: 1", "f [a: 1]", "f a, [b: 1]",
      # when with kw (no_parens_op_expr -> when_op_eol call_args_no_parens_kw)
      "t when a: 1", "x when b: var", "@spec f(x) :: t when x: term()",
      "fun = fn x when a: 1 -> x end",

      # --- block_expr (lines 181-185) ---
      "f() do end", "f(1) do end", "f(1)(2) do end", "f.(1) do end",
      "f do end", "f do 1 end", "f a do end", "f a, b do end",
      "f a: 1 do end", "Mod.f do end", "a.b do end",
      "f -a do end",
      "if x do 1 end", "if x do 1 else 2 end",
      "try do 1 rescue e -> e after 2 end",
      "try do 1 catch :x, v -> v end",
      "case x do _ -> 1 end",
      "receive do x -> x after 0 -> :t end",
      "foo do else end", "foo do 1 else end", "foo do else 2 end",
      "foo do a -> 1 end",
      "foo do end do2", # invalid-ish
      "f do end.b", # block then dot? oracle errors
      "if true do true else false end |> IO.inspect()",
      # nested do blocks invalid: unmatched in no_parens args
      "if if true do true else false end do 1 end",
      "f g do end", # do attaches to f? grammar: dot_identifier call_args_no_parens_all do_block
      "f g, h do end",

      # --- stab / fn / paren-stab (lines 276-279, 344-366, 528-529) ---
      "fn -> 1 end", "fn x -> x end", "fn x, y -> x end",
      "fn x when x > 0 -> x end", "fn -> end", "fn x -> end",
      "fn (x) -> x end", "fn (x, y) -> x end", "fn (x, y) when x -> x end",
      "fn () -> 1 end", "fn () when node() -> 1 end",
      "fn\nx -> x\ny -> y\nend",
      "(-> 1)", "(() -> 1)", "(x -> 1)", "(x, y -> 1)", "(x, y when x -> 1)",
      "(() when x -> 1)", "(; 1)", "(;)", "(1; 2)", "(1;)", "(;1)",
      "(1\n2)", "(x -> 1; y -> 2)", "(a -> b\nc -> d)",
      "(a, b: 1 -> 2)", "(a: 1 -> 2)", # stab_parens_many kw
      "((a, b) -> 1)", # error? open_paren call_args_no_parens_many close_paren -> error_no_parens_strict
      "(a when b: 1 -> 2)", # call_args_no_parens_all incl. kw when?
      "fn a, b: 1 -> 2 end",
      "case x do a, b -> 1 end", # multi-arg stab in case: oracle?
      "->", "x ->", "-> 1", # bare stab outside container: errors
      "fn 1 end", # block instead of stab: error build_fn
      "(1; x -> 2)", # stab after expr: oracle?
      "fn x ->\n  x\nend",
      "for x <- [1], do: x",
      "with {:ok, a} <- f(), do: a, else: (_ -> :err)",

      # --- empty paren / paren exprs ---
      "()", "( )", "(\n)", "(1)", "((1))", "(1,)", # errors & warns
      "f()", "f ()", # f () -> warn_empty_paren? oracle: f(()) ?
      "(f a)", "(f a, b)", # no_parens in parens

      # --- access / bracket (lines 273-318) ---
      "a[1]", "a[:b]", "a[b: 1]", "a[1,]", "a[[1]]",
      "@a[1]", "@a.b[1]", "a.b[1]", "f(1)[2]", "%{}[1]", "[1][0]",
      "1[2]", "\"s\"[1]", "{1}[2]", "a[1][2]", "(f a)[1]",
      "a [1]", # space → call with list arg, not access
      "@ a[1]", # at_op_eol access_expr bracket_arg: @(a[1]) per bracket_at_expr
      "a[1, 2]", # error_too_many_access_syntax
      "fn -> 1 end[1]",
      "x[a: 1, b: 2]",

      # --- capture / capture_int (lines 275, 409-410) ---
      "&1", "& &1", "&f/1", "&f(&1, 2)", "&(&1)", "&//2", "&../2", "&-/2",
      "&Mod.f/2", "& 1", "&1.foo", "&1[2]", "&&&1", # &&& is and_op... oracle?
      "&+/2", "&&/2", # capture of && ?

      # --- nullary ops (lines 264-265) ---
      "..", "...", "(..)", "(...)", "f(..)", "[..]", "%{(..) => 1}",
      ".. + 1", "... + 1", "...foo", "... foo", "..a..", # weird but check status parity

      # --- unary / at / ellipsis distribution (lines 156-159, 167-170, 174-177) ---
      "-1", "+1", "!a", "^a", "not a", "~~~a", "@a", "@ a", "- a", "-\na",
      "@f a", "@f a, b", # at over no_parens call
      "-f a", "not f a, b", "&f a", # capture over no_parens
      "...f a",
      "@-1", "-@1", "!@a", "@@a", "^^a", "- -1", "--1", "+-1", "via!", "-..",
      "x = -y = 1", # unary over match? nonassoc
      "not not a", "!!a",

      # --- binary ops sanity + structure (build_op specials) ---
      "1..2//3", "1..2//3 + 1", "0..1//-1", "1//2", "a // b", # error unless after ..
      "(1..2)//3", # parens: oracle?
      "1..2//3..4", "a in b", "a not in b", "not a in b", "! a in b",
      "a not\nin b", "1 .. 2", "a <- b", "a \\\\ b", "a when b when c",
      "a |> b |> c", "a ++ b ++ c", "a = b = c", "a :: b :: c",
      "x ~>> y <<~ z",

      # --- dot forms (lines 474-498) ---
      "a.b", "a.b.c", "a.\nb", "a.b()", "a.()", "a.(1, 2)", "a.().b",
      "Foo.Bar", "Foo.Bar.Baz", "a.Bar", "f(1).Bar", "@a.B",
      "a.{b, c}", "a.{}", "a.{b}", "Foo.{Bar, Baz}", "a.{b, c,}",
      "a.'+'(1)", # erlang style: error
      "a.\"b\"", "a.\"b\"(1)", # quoted call
      "a.fn", # error
      "a.b a, b", "a.b.c d", "Mod.f do end",
      "1 .b", "1.b", # int dot: errors? "1.b" lexes as flt error?
      "a . b", # space around dot
      "f().g", "f().g()", "[1].g", "a.b.", # trailing dot error
      "a.do", # keyword after dot: do_identifier? oracle errors
      "a.true", "a.nil", # reserved words after dot

      # --- kw lists / kw_call vs kw_data (lines 566-596) ---
      "[a: 1]", "[a: 1, b: 2]", "[a: 1,]", "[1, a: 2]", "[1, 2, a: 3, b: 4]",
      "[a: 1, 2]", # maybe_bad_keyword_data_follow_up error
      "f(a: 1, 2)", # kw_call follow_up error
      "f(1, a: 2)", "f(1, a: 2,)", # trailing comma in call: error?
      "f(a: 1,)", "[\"a\": 1]", "[\"a\#{1}\": 1]", "['a': 1]",
      "[a!: 1]", "[a?: 1]", "[A: 1]", "[do: 1]", "[true: 1]", "[nil: 1]",
      "[when: 1]", "[and: 1]", "[in: 1]", "[not: 1]", "[fn: 1]", "[end: 1]",
      "f do: 1", "f do: 1, else: 2", "f 1, do: 2", "f a: 1 do end", # kw + do block
      "[a:\n1]", # kw_eol with eol
      "f(\na: 1\n)",
      "%{a: 1, 2 => 3}", # kw then assoc: error (kw must be last)
      "[a: 1 | 2]", # kw with cons: oracle?

      # --- containers: list/tuple/bits (lines 591-611) ---
      "[]", "[1]", "[1,]", "[1, 2]", "[1 | 2]", "[1, 2 | 3]",
      "[\n1,\n2\n]", "[1\n,2]",
      "{}", "{1}", "{1,}", "{1, 2}", "{1, 2, 3}", "{1, 2, 3,}",
      "{a: 1}", # bad_keyword tuple error
      "{1, a: 2}", "{1, 2, a: 3}", "{1, [a: 2]}",
      "<<>>", "<<1>>", "<<1,>>", "<<1, 2>>", "<<a::8>>", "<<a::size(8)>>",
      "<<a: 1>>", # bad_keyword bitstring error
      "<<1, a: 2>>", # container_args with kw tail in bits: oracle?
      "{1, a: 2,}", # trailing comma after kw: ?
      "[1, a: 2,]",

      # --- maps & structs (lines 615-657) ---
      "%{}", "%{1 => 2}", "%{a: 1}", "%{1 => 2, a: 3}", "%{a: 1, 1 => 2}",
      "%{1 => 2,}", "%{a: 1,}", "%{a => b}", "%{a() => b}",
      "%{%{} | a: 1}", "%{m | a: 1}", "%{m | a => 1}", "%{m | a => 1, b => 2}",
      "%{m | a => 1,}", "%{m | a => 1, b: 2}", "%{m | }", # error
      "%{m | a: 1, b => 2}", # kw then assoc in update: error
      "%{a | b | c}", # nested pipe: ?
      "%{if x do 1 end => 2}", # unmatched_expr assoc
      "%{1 => if x do 1 end}",
      "%{f a => 1}", # no_parens in map: error
      "%Foo{}", "%Foo{a: 1}", "%Foo{ a => 1}", "%foo{}", "%@m{}", "%m.f{}",
      "%unquote(x){}", "%^m{}", "%!m{}", "%-m{}", "%...{}", # map_base_expr unary forms
      "% Foo{}", # space after %: error? grammar says '%' map_base_expr map_args
      "%Foo\n{}", # eol between: map -> '%' map_base_expr eol map_args
      "%Foo{1 => 2}", "%Foo{m | a: 1}",
      "%{m | a: 1 | b: 2}", # ?
      "%{:a => 1, :a => 2}",
      "%fn -> 1 end{}", # fn as map_base? sub_matched includes access_expr incl fn: oracle?
      "%(1){}", # parens as base?
      "%1{}", "%\"s\"{}", "%[1]{}",

      # --- strings/heredocs/sigils/atoms/chars (access_expr literals) ---
      "\"abc\"", "\"a\#{1}b\"", "'abc'", "'a\#{1}b'",
      "\"\"\"\nabc\n\"\"\"", "'''\nabc\n'''",
      "\"\"\"\n  a\#{1}\n  \"\"\"",
      "~s(a)", "~s(a)x", "~S(a\#{1})", "~r/a\#{x}/imsx", "~D[2020-01-01]",
      "~w(a b c)a", "~MAT[1 2]", # multi-letter sigil (1.15+)
      ":abc", ":a@b", ":a!", ":a?", ":+", ":<<>>", ":%{}", ":%", ":{}", ":..", ":...",
      ":\"quoted\"", ":\"q\#{1}\"", ":'q'", ":'q\#{1}'",
      "?a", "?\\n", "?\\s", "? ", "?\\x41",
      "0x1F", "0b101", "0o17", "1_000", "1.5e10", "1.0e-3",
      "true", "false", "nil",

      # --- ints/floats meta: handle_number token meta (only with token_metadata) ---

      # --- error productions / status parity (grammar error_* actions) ---
      "f(a: 1) when x", # ?
      "1 a: 2", # error_invalid_kw_identifier (access_expr kw_identifier)
      "x = 1 b: 2",
      "f 1 a: 2", # ?
      "foo(a, bar b, c)", # error_no_parens_many_strict
      "foo a, bar b, c", # error (no_parens_expr in comma args)
      "[f a, b]", # error_no_parens_container_strict
      "{f a, b}", "%{f(a) => g b, c}", "<<f a, b>>",
      "f (g a, b)", # error_no_parens_strict
      "f (a: 1)", # error_no_parens_strict via kw
      "f(f a, b)", # error_no_parens_many_strict
      "foo 1, if true do 2 end", # unmatched in no_parens many: error
      "foo bar do end", # do-block call nested no parens: ?
      "foo (bar do end)",
      "a |> (b c, d)",

      # --- eol interplay (open/close eol rules, next_is_eol) ---
      "[1,\n2]", "[1\n]", "[\n]", "{1\n}", "<<1\n>>", "(1\n)",
      "a =\n1", "a\n= 1", # operator can't start a line (oracle errors? actually `=` newline before op is error)
      "a +\nb", "a\n+ b", # newline before binary op: continuation? oracle: `a\n+b` parses as two exprs (unary +b)? actually it's `a; +b`? No — elixir treats `\n+` as continuation only if op is at end of line. `a\n+ b` → two expressions.
      "a ..\nb", "a when\nb", "%{a:\n1}",
      "f(\n)", "f(1,\n2)", "f(\n1\n)",
      "a.\nb()", "a\n.b", # dot at line start: error? oracle allows `a\n.b`? no.
      "1 +\n\n2", # multiple newlines after op

      # --- semicolons in odd places ---
      "f(;)", "f(1;)", "f(1; 2)", "[1; 2]", "do; end", "fn ; x -> x end",
      "fn x -> x; end",
      "if x do ; 1 end", "if x do 1; else ; 2; end",

      # --- do-block edge: block_identifier handling ---
      "if x do 1 else 2 after 3 end", # after in if: parser-level ok? oracle: parses, semantic err later
      "case x do _ -> 1 else 2 end",
      "foo do 1 -> 2 else 3 -> 4 end",
      "foo do bar -> 1\nbaz end", # stab then block_identifier?? `baz end` -> ?
      "foo do 1 else 2 rescue 3 catch 4 after 5 end",
      "foo do else x -> 1 end",
      "foo do end\n.bar", # ?

      # --- struct/dot/call chains ---
      "f.()()", "f()()", "f()(1)", "f(1)(2)", "f.(1)(2)", "f.(1).(2)",
      "f(1)(2)(3)", # only two-level nesting in grammar: oracle errors?
      "Foo.Bar(1)", # alias call: error?
      "Foo .Bar", "foo.Bar.baz",

      # --- assorted real-world-ish regression shapes ---
      "def f(a \\\\ 1), do: a",
      "defmodule M do\n  use X\n  def f, do: :ok\nend",
      "quote do: unquote(x)",
      "import Kernel, except: [+: 2]",
      "[+: 1]", "[&&: 1]", "[//: 1]", "[..: 1]", "[...: 1]", "[when: 1, do: 2]",
      "f(<<x::binary>> <> rest)",
      "case a do\n  ^b -> 1\n  _ -> 2\nend",
      "x = %{m | k: v}",
      "raise ArgumentError, message: \"x\"",
      "spawn fn -> :ok end",
      "Enum.map(list, & &1 * 2)",
      "for {k, v} <- m, into: %{}, do: {k, v}",
      "with a <- 1, b when b > 0 <- 2, do: a + b",
      "@doc \"\"\"\nhey\n\"\"\"",
      "1 |> (& &1).()",
      "defp f(%{} = m), do: m",
      "a = b = c = nil",
      "send self(), {:msg, 1}",
      "x\n|> f()\n|> g()",
      "if x, do: 1, else: 2",
      "def f, do: 1",
      "def unquote(name)(), do: 1",
      "%{^k => v} = m",
      "<<x::utf8, rest::binary>> = s",
      "'abc' ++ 'def'",
      "fn %{a: a} -> a end",
      "&is_atom/1",
      "f = &Mod.g/2",
      "(fn -> 1 end).()",
      "add = fn a, b -> a + b end",
      "case x do %{a: 1} when true -> :ok\n_ -> :err end",

      # --- wave 2: helper-function special cases ---
      # build_paren_stab rearrange_uop: (not x) / (!x) keep a __block__ wrapper
      "(not x)", "(!x)", "(not x; 1)", "(; not x)", "(~~~x)", "(-x)", "(^x)",
      "y = (not x)", "(not x).a",
      # unwrap_splice / build_block unquote_splicing special
      "(unquote_splicing([1, 2]))", "(unquote_splicing([1, 2]); 1)",
      "(unquote_splicing([1, 2]) -> :ok)", "((unquote_splicing([1, 2])) -> :ok)",
      "fn unquote_splicing([a]) -> 1 end",
      "quote do (unquote_splicing(args)) end",
      # newline-before-comma/token across containers (close-only eol rules)
      "f(1\n, 2)", "{1\n, 2}", "<<1\n, 2>>", "%{:a\n=> 1}", "[a: 1\n, b: 2]",
      "f(1\n)", "%{a: 1\n}", "f a\n, b",
      # paren-stab as matched_expr operand
      "y = (a -> b)", "(a -> b)[0]", "(a -> b) ++ 1",
      # not in spacing
      "a not  in b", "a not in b and c",
      # capture + range step
      "&(1..2//3)", "& 1..2//3",
      # do-block on operator RHS warn_no_parens_after_do_op (warning, not error)
      "x = if true do 1 end",
      "foo do end + 1", "1 + foo do end"
    ]
  end

  def strip_meta(ast) do
    Macro.postwalk(ast, fn
      {a, _m, b} -> {a, [], b}
      other -> other
    end)
  end

  def encoder(lit, meta), do: {:ok, {:__lit__, meta, [lit]}}

  def oracle(src, opts \\ []) do
    try do
      Code.string_to_quoted(src, [columns: true, emit_warnings: false] ++ opts)
    rescue
      e -> {:raise, e}
    end
  end

  def toxic(src, opts \\ []) do
    try do
      {ast, diags} = Toxic2.parse_to_ast(src, opts)
      errors = Enum.filter(diags, &Toxic2.Diagnostic.error?/1)
      {:ok, ast, errors}
    rescue
      e -> {:raise, e, __STACKTRACE__}
    end
  end

  def run do
    tm = [token_metadata: true, literal_encoder: (&GrammarAudit.encoder/2)]

    results =
      for src <- cases() do
        # Default mode: structural parity (meta stripped, per P4) + error-status parity.
        v1 = verdict(:default, src, oracle(src), toxic(src), &strip_meta/1)
        # token_metadata mode: full-fidelity comparison (meta included).
        v2 = verdict(:tm, src, oracle(src, tm), toxic(src, tm), & &1)
        [v1, v2]
      end

    fails = results |> List.flatten() |> Enum.reject(&is_nil/1)
    IO.puts("\n=== #{length(cases())} cases, #{length(fails)} mismatches ===\n")

    Enum.each(fails, fn {mode, kind, src, detail} ->
      IO.puts("--- [#{mode}/#{kind}] #{inspect(src)}")
      IO.puts(detail <> "\n")
    end)
  end

  defp verdict(mode, src, {:raise, e}, _t, _norm), do: {mode, :oracle_raise, src, Exception.message(e)}

  defp verdict(mode, src, _o, {:raise, e, st}, _norm),
    do: {mode, :toxic_raise, src, Exception.format(:error, e, Enum.take(st, 5))}

  defp verdict(mode, src, {:ok, oast}, {:ok, tast, terrs}, norm) do
    cond do
      terrs != [] ->
        {mode, :false_error, src, "toxic2 errors on oracle-valid input: #{inspect(terrs, limit: 3)}"}

      norm.(oast) != norm.(tast) ->
        {mode, :ast_mismatch, src,
         "oracle: #{inspect(norm.(oast), limit: :infinity)}\ntoxic2: #{inspect(norm.(tast), limit: :infinity)}"}

      true ->
        nil
    end
  end

  defp verdict(mode, src, {:error, oerr}, {:ok, _tast, terrs}, _norm) do
    if terrs == [] do
      {mode, :missed_error, src, "oracle rejects (#{inspect(oerr, limit: 4)}) but toxic2 has no error diagnostic"}
    else
      nil
    end
  end
end

GrammarAudit.run()
