defmodule Toxic2.DiagnosticsTest do
  use ExUnit.Case, async: true

  alias Toxic2.Diagnostic
  alias Toxic2.Diagnostics

  describe "Diagnostic record" do
    test "constructor and accessors" do
      d = Diagnostic.new(1, :parser, :error, :expected_rparen, {1, 5, 1, 6}, %{got: :int})
      assert Diagnostic.id(d) == 1
      assert Diagnostic.phase(d) == :parser
      assert Diagnostic.severity(d) == :error
      assert Diagnostic.code(d) == :expected_rparen
      assert Diagnostic.span(d) == {1, 5, 1, 6}
      assert Diagnostic.details(d) == %{got: :int}
      assert Diagnostic.error?(d)
    end

    test "warning is not an error" do
      refute Diagnostic.error?(
               Diagnostic.new(1, :lowerer, :warning, :deprecated_not_in, {1, 1, 1, 7})
             )
    end
  end

  describe "accumulator" do
    test "emit allocates monotonic ids, prepends, returns the id" do
      {acc, next} = Diagnostics.new()
      assert {acc, next} == {[], 1}

      {id1, acc, next} = Diagnostics.emit(acc, next, :parser, :error, :a, {1, 1, 1, 2})
      {id2, acc, next} = Diagnostics.emit(acc, next, :parser, :warning, :b, {1, 3, 1, 4})

      assert {id1, id2, next} == {1, 2, 3}
      # prepended (reverse order internally)...
      assert [d2, d1] = acc
      assert Diagnostic.id(d1) == 1
      assert Diagnostic.id(d2) == 2
      # ...and to_list restores source-emission order
      assert Diagnostics.to_list(acc) |> Enum.map(&Diagnostic.id/1) == [1, 2]
    end

    test "errors/1 keeps only :error severity (the strict-mode filter)" do
      {acc, next} = Diagnostics.new()
      {_, acc, next} = Diagnostics.emit(acc, next, :parser, :error, :a, {1, 1, 1, 2})
      {_, acc, next} = Diagnostics.emit(acc, next, :lowerer, :warning, :b, {1, 3, 1, 4})
      {_, acc, _next} = Diagnostics.emit(acc, next, :lexer, :error, :c, {2, 1, 2, 2})

      codes = acc |> Diagnostics.to_list() |> Diagnostics.errors() |> Enum.map(&Diagnostic.code/1)
      assert codes == [:a, :c]
    end

    test "merge_sorted orders combined streams by start position" do
      lexer = [Diagnostic.new(1, :lexer, :error, :x, {3, 1, 3, 2})]
      parser = [Diagnostic.new(2, :parser, :error, :y, {1, 5, 1, 6})]
      lowerer = [Diagnostic.new(3, :lowerer, :warning, :z, {1, 1, 1, 4})]

      assert Diagnostics.merge_sorted([lexer, parser, lowerer])
             |> Enum.map(&Diagnostic.code/1) == [:z, :y, :x]
    end
  end
end
