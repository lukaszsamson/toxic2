defmodule Toxic2.CommentsTest do
  use ExUnit.Case, async: true

  defp toxic_comments(source) do
    {_ast, _diags, comments} = Toxic2.string_to_quoted_with_comments(source)
    comments
  end

  defp elixir_comments(source) do
    {:ok, _ast, comments} = Code.string_to_quoted_with_comments(source, columns: true)
    comments
  end

  describe "string_to_quoted_with_comments/2" do
    test "returns no comments for comment-free source" do
      assert {_ast, _diags, []} = Toxic2.string_to_quoted_with_comments("x = 1\n")
    end

    test "collects a single full-line comment" do
      assert [%{line: 1, column: 3, text: "# some comment"}] =
               toxic_comments("  # some comment\n")
    end

    test "collects an inline (trailing) comment" do
      assert [%{line: 1, column: 7, text: "# bar", previous_eol_count: 0}] =
               toxic_comments("x = 1 # bar\n")
    end

    test "text includes the leading # and excludes the trailing newline" do
      assert [%{text: "#no space"}] = toxic_comments("#no space\n")
    end

    test "comments are returned in source order" do
      assert [%{line: 1}, %{line: 2}, %{line: 4}] =
               toxic_comments("# a\n# b\n\n# d\n")
    end

    test "comments do not reach the parser (ast matches parse_to_ast)" do
      source = "defmodule Foo do\n  # c\n  def bar, do: :ok\nend\n"
      {ast_with, _diags, _comments} = Toxic2.string_to_quoted_with_comments(source)
      {ast_plain, _diags2} = Toxic2.parse_to_ast(source)
      assert ast_with == ast_plain
    end

    test "still parses (best-effort) and returns comments for incomplete code" do
      assert {_ast, _diags, [%{text: "# c"}]} =
               Toxic2.string_to_quoted_with_comments("defmodule Foo do\n  # c\n")
    end
  end

  describe "parity with Code.string_to_quoted_with_comments/2" do
    defp normalize(comments) do
      Enum.map(
        comments,
        &Map.take(&1, [:line, :column, :text, :previous_eol_count, :next_eol_count])
      )
    end

    for {name, source} <- [
          single: "  # some comment\n",
          inline: "x = 1 # :bar\n",
          leading_blanks: "\n\n# c\n",
          block: "# a\n# b\n# c\n",
          block_with_gap: "# a\n\n# c\n",
          mixed: "# top\n\n\nx = 1\n\n\n# bottom\ny\n",
          inline_and_block: "defmodule Foo do\n  # doc\n  def bar, do: :ok # inline\nend\n",
          no_trailing_newline: "x = 1 # eof comment",
          empty_comment: "#\nx\n",
          crlf: "x = 1\r\n# crlf comment\r\ny = 2\r\n",
          hash_in_string: "x = \"a # b\" # real\n",
          hash_in_heredoc: "x = \"\"\"\n# not a comment\n\"\"\"\n"
        ] do
      test "matches Elixir: #{name}" do
        source = unquote(source)
        assert normalize(toxic_comments(source)) == normalize(elixir_comments(source))
      end
    end
  end
end
