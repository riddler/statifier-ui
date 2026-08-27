defmodule StatifierUI.TruthTable.MarkdownTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.TruthTable
  alias StatifierUI.TruthTable.Markdown

  defp table(opts \\ []) do
    {:ok, fixtures} =
      Fixtures.new(
        datasets: %{
          "variant-b-complete" => %{"signup" => %{"steps_completed" => 4, "variant" => "B"}},
          "variant-b-sparse" => %{"signup" => %{"variant" => "B"}},
          "variant-a-early" => %{"signup" => %{"steps_completed" => 1, "variant" => "A"}}
        },
        expressions: %{
          "is-complete-variant-b" => %{
            "source" => "signup.steps_completed >= 3 and signup.variant == 'B'"
          },
          "steps" => %{"source" => "signup.steps_completed"}
        }
      )

    TruthTable.build(fixtures, opts)
  end

  defp table_rows(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "|"))
    |> Enum.map(fn line ->
      line |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
    end)
  end

  describe "render/2 default orientation" do
    test "puts datasets down the rows and expressions across the columns" do
      rows = table() |> Markdown.render() |> table_rows()

      assert [header, separator | body] = rows
      assert header == ["dataset", "is-complete-variant-b", "steps"]
      assert separator == ["---", "---", "---"]

      assert Enum.map(body, &hd/1) == [
               "variant-a-early",
               "variant-b-complete",
               "variant-b-sparse"
             ]
    end

    test "renders the three truth values as three distinct cells" do
      [_header, _separator | body] = table() |> Markdown.render() |> table_rows()

      assert [
               ["variant-a-early", "false", "`1`"],
               ["variant-b-complete", "**true**", "`4`"],
               ["variant-b-sparse", "_undefined_", "_undefined_"]
             ] = body
    end

    test "every truth cell still names its value once emphasis is stripped" do
      [_header, _separator | body] = table() |> Markdown.render() |> table_rows()

      words =
        body
        |> Enum.flat_map(&tl/1)
        |> Enum.map(&String.replace(&1, ["*", "_", "`"], ""))
        |> Enum.uniq()
        |> Enum.sort()

      assert words == ["1", "4", "false", "true", "undefined"]
    end
  end

  describe "render/2 with orientation: :expressions_as_rows" do
    test "transposes to the orientation ADR-0006's prose uses" do
      rows =
        table()
        |> Markdown.render(orientation: :expressions_as_rows)
        |> table_rows()

      assert [header, _separator | body] = rows
      assert header == ["expression", "variant-a-early", "variant-b-complete", "variant-b-sparse"]
      assert Enum.map(body, &hd/1) == ["is-complete-variant-b", "steps"]
      assert ["is-complete-variant-b", "false", "**true**", "_undefined_"] in body
    end
  end

  describe "render/2 surrounding blocks" do
    test "leads with the title and the legend by default" do
      markdown = Markdown.render(table())

      assert String.starts_with?(markdown, "# Truth table\n\n")
      assert markdown =~ "three separate results"
      assert markdown =~ "not that it"
    end

    test "drops the title and the legend when asked" do
      markdown = Markdown.render(table(), title: nil, legend: false)

      refute markdown =~ "# Truth table"
      refute markdown =~ "three separate results"
      assert String.starts_with?(markdown, "| dataset |")
    end

    test "lists each expression's source under the matrix" do
      markdown = Markdown.render(table())

      assert markdown =~ "Expressions:"

      assert markdown =~
               "- **is-complete-variant-b**: `signup.steps_completed >= 3 and signup.variant == 'B'`"

      assert markdown =~ "- **steps**: `signup.steps_completed`"
    end

    test "omits the source list when asked" do
      refute Markdown.render(table(), sources: false) =~ "Expressions:"
    end

    test "names an expression that is on the axis but not in the bundle" do
      markdown = Markdown.render(table(expressions: ["ghost"]))

      assert markdown =~ "- **ghost**: not in this bundle"
    end
  end

  describe "render/2 error and gap reporting" do
    test "shows an error cell and explains it below the matrix" do
      {:ok, fixtures} =
        Fixtures.new(
          datasets: %{"any" => %{"user" => %{}}},
          expressions: %{"malformed" => %{"source" => "signup.steps_completed +"}}
        )

      markdown = fixtures |> TruthTable.build() |> Markdown.render()

      assert [_header, _separator, ["any", "**error**"]] = table_rows(markdown)
      assert markdown =~ "Errors:"
      assert markdown =~ "- **malformed** / **any**: Expected number"
    end

    test "renders a missing dataset as its own cell, not as false" do
      markdown = Markdown.render(table(datasets: ["ghost"]))

      assert [_header, _separator, ["ghost", "_no dataset_", "_no dataset_"]] =
               table_rows(markdown)
    end

    test "omits the error block when nothing failed" do
      refute Markdown.render(table()) =~ "Errors:"
    end
  end

  describe "render/2 with an empty axis" do
    test "says there are no expressions rather than rendering a headers-only table" do
      {:ok, fixtures} = Fixtures.new(datasets: %{"any" => %{}})
      markdown = fixtures |> TruthTable.build() |> Markdown.render()

      assert markdown =~ "No expressions in this bundle."
      assert table_rows(markdown) == []
    end

    test "says there are no datasets when the expressions have nothing to run against" do
      {:ok, fixtures} =
        Fixtures.new(expressions: %{"steps" => %{"source" => "signup.steps_completed"}})

      markdown = fixtures |> TruthTable.build() |> Markdown.render()

      assert markdown =~ "No datasets in this bundle."
      assert table_rows(markdown) == []
    end
  end
end
