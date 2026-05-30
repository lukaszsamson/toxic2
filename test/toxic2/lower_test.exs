defmodule Toxic2.LowerTest do
  use ExUnit.Case, async: true

  describe "parse_to_ast pipeline" do
    test "binary op lowers to the Elixir operator node" do
      assert {{:+, _, [1, 2]}, []} = Toxic2.parse_to_ast("1 + 2")
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
  end

  describe "invalid input lowers tolerantly (never raises)" do
    test "a stray closer lowers to an __error__ node with a diagnostic" do
      {ast, diags} = Toxic2.parse_to_ast(")")
      assert {:__error__, _meta, %{diag_ids: [_ | _]}} = ast
      assert diags != []
    end
  end
end
