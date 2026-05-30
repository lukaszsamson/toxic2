defmodule Mix.Tasks.Toxic2.GuardTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Toxic2.Guard

  @tmp Path.join(System.tmp_dir!(), "toxic2_guard_test")

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(Path.join(@tmp, "lib/toxic2"))
    File.mkdir_p!(Path.join(@tmp, "test/support"))
    on_exit(fn -> File.rm_rf!(@tmp) end)
    :ok
  end

  # Forbidden literals are assembled from fragments so this test source never trips the
  # guard when the real `mix toxic2.guard` scans test/**.
  defp builtin_parser_call, do: "Code." <> "string_to_quoted" <> "(src)"
  defp macro_to_string_call, do: "Macro." <> "to_string" <> "(ast)"
  defp assert_true_literal, do: "assert " <> "true"
  defp skip_tag_literal, do: "@tag " <> ":skip"

  defp write(rel, content) do
    path = Path.join(@tmp, rel)
    File.write!(path, content)
    path
  end

  defp rules(path), do: path |> List.wrap() |> Guard.violations() |> Enum.map(&elem(&1, 2))

  test "clean library file produces no violations" do
    path = write("lib/toxic2/clean.ex", "defmodule Clean do\n  def f(x), do: x + 1\nend\n")
    assert rules(path) == []
  end

  test "flags the built-in parser in library code" do
    path =
      write(
        "lib/toxic2/cheater.ex",
        "defmodule C do\n  def p(src), do: #{builtin_parser_call()}\nend\n"
      )

    assert :builtin_parser in rules(path)
  end

  test "flags the built-in parser in a non-oracle test" do
    path = write("test/sneaky_test.exs", "test \"x\" do\n  #{builtin_parser_call()}\nend\n")
    assert :builtin_parser in rules(path)
  end

  test "ALLOWS the built-in parser in the oracle (the one legitimate place)" do
    path =
      write(
        "test/support/oracle.ex",
        "defmodule Oracle do\n  def ref(src), do: #{builtin_parser_call()}\nend\n"
      )

    refute :builtin_parser in rules(path)
  end

  test "flags Macro.to_string in library code" do
    path =
      write(
        "lib/toxic2/lossy.ex",
        "defmodule L do\n  def eq(ast), do: #{macro_to_string_call()}\nend\n"
      )

    assert :macro_to_string_in_lib in rules(path)
  end

  test "flags tautological asserts and skip tags in tests" do
    content = """
    defmodule HackyTest do
      #{skip_tag_literal()}
      test "todo" do
        #{assert_true_literal()}
      end
    end
    """

    path = write("test/hacky_test.exs", content)

    found = rules(path)
    assert :tautological_assert in found
    assert :skip_tag in found
  end

  test "does NOT flag legitimate equality assertions" do
    path = write("test/real_test.exs", "test \"x\" do\n  assert true == compute()\nend\n")
    refute :tautological_assert in rules(path)
  end

  test "flags the ++ list-append operator in hot library code" do
    path = write("lib/toxic2/appender.ex", "defmodule A do\n  def f(a, b), do: a ++ b\nend\n")
    assert :list_append_in_hot_module in rules(path)
  end

  test "does NOT flag ++ used as data (operator tables: \"++\", :++, +++)" do
    body = ~s(  @t %{"++" => {:concat_op, :++}, "+++" => {:concat_op, :+++}}\n)
    path = write("lib/toxic2/optable.ex", "defmodule T do\n#{body}end\n")
    refute :list_append_in_hot_module in rules(path)
  end

  test "the trailing # guard:allow marker exempts a line" do
    line = "  def p(src), do: #{builtin_parser_call()} # guard:allow"
    path = write("lib/toxic2/exception.ex", "defmodule E do\n#{line}\nend\n")
    assert rules(path) == []
  end

  test "the real project tree is clean under the guard" do
    File.cd!(Path.expand("../../..", __DIR__), fn ->
      paths = Path.wildcard("lib/toxic2/**/*.ex") ++ Path.wildcard("test/**/*.exs")
      assert Guard.violations(paths) == []
    end)
  end
end
