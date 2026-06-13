defmodule Toxic2.LowerTest do
  use ExUnit.Case, async: true

  describe "parse_to_ast pipeline" do
    test "binary op lowers to the Elixir operator node" do
      assert {{:+, _, [1, 2]}, []} = Toxic2.parse_to_ast("1 + 2")
    end

    test "unclosed grouping paren does not crash (degenerate span in add_parens_meta)" do
      # with token_metadata the lowerer slices the paren's source to detect `;`; an unclosed `(`
      # leaves a degenerate span that must not blow up String.slice
      for source <- ["(\n", "bar (\n", "Foo(\n", "a + (\n", "x\n(\n", "("] do
        assert {_ast, _diagnostics} = Toxic2.parse_to_ast(source, token_metadata: true)
      end
    end

    test "identifier lowers to a var, alias to __aliases__, atom to an atom" do
      assert {{:foo, _, nil}, []} = Toxic2.parse_to_ast("foo")
      assert {{:__aliases__, _, [:Foo]}, []} = Toxic2.parse_to_ast("Foo")
      assert {:sym, []} = Toxic2.parse_to_ast(":sym")
    end

    test "multiple top-level expressions lower to a __block__" do
      assert {{:__block__, _, [{:a, _, nil}, {:b, _, nil}]}, []} = Toxic2.parse_to_ast("a\nb")
    end

    test "existing_atoms_only: known atom lowers normally" do
      _ = :known_atom_xyz

      assert {:known_atom_xyz, []} =
               Toxic2.parse_to_ast(":known_atom_xyz", existing_atoms_only: true)
    end

    test "existing_atoms_only: an unknown atom does NOT raise (totality, P5)" do
      # lowers to an error node + a :lowerer :error diagnostic instead of raising
      {ast, diags} =
        Toxic2.parse_to_ast(":definitely_not_an_existing_atom_42", existing_atoms_only: true)

      assert {:__error__, _meta, %{diag_ids: [_ | _]}} = ast
      assert [{_id, :lowerer, :error, :nonexistent_atom, _, _, _, _, _}] = diags
    end

    test "existing_atoms_only gates EVERY source-derived name (no atom-table growth)" do
      # Each of these would mint a fresh atom; under the policy they must error, not create it.
      fresh = fn kind -> "zz_t2_#{kind}_#{:erlang.unique_integer([:positive])}" end

      sources = [
        "[#{fresh.(:kw)}: 1]",
        "a.\"#{fresh.(:remote)}\"",
        "Zz_T2_Alias_#{:erlang.unique_integer([:positive])}.Bar",
        "Zz_T2_Alias_#{:erlang.unique_integer([:positive])}",
        ":\"#{fresh.(:atom)}\"",
        fresh.(:var)
      ]

      for src <- sources do
        {_ast, diags} = Toxic2.parse_to_ast(src, existing_atoms_only: true)

        assert Enum.any?(diags, &(elem(&1, 2) == :error and elem(&1, 3) == :nonexistent_atom)),
               "expected #{inspect(src)} to be gated (no atom minted)"
      end
    end

    test "existing_atoms_only still accepts pre-existing names everywhere" do
      _ = [:ok_kw_key, :ok_remote, :ok_atom_lit]

      for src <- ["[ok_kw_key: 1]", "Enum.map", ":ok_atom_lit", "Map.get"] do
        {_ast, diags} = Toxic2.parse_to_ast(src, existing_atoms_only: true)
        refute Enum.any?(diags, &(elem(&1, 2) == :error)), "#{inspect(src)} should be clean"
      end
    end
  end

  describe "invalid input lowers tolerantly (never raises)" do
    test "a stray closer lowers to an __error__ node with a diagnostic" do
      {ast, diags} = Toxic2.parse_to_ast(")")
      assert {:__error__, _meta, %{diag_ids: [_ | _]}} = ast
      assert diags != []
    end
  end
end
