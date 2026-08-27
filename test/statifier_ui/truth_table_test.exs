defmodule StatifierUI.TruthTableTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Fixtures.ExpressionsSource
  alias StatifierUI.TruthTable

  doctest StatifierUI.TruthTable

  # Three datasets and a malformed expression, chosen so every verdict the
  # type carries is reachable from one bundle: a completed variant-B signup
  # with a start date, a completed one without, and an early variant-A signup.
  defp bundle do
    {:ok, fixtures} =
      Fixtures.new(
        datasets: %{
          "variant-b-complete" => %{
            "signup" => %{"steps_completed" => 4, "variant" => "B", "started_at" => "2026-01-15"}
          },
          "variant-b-sparse" => %{"signup" => %{"steps_completed" => 4, "variant" => "B"}},
          "variant-a-early" => %{"signup" => %{"steps_completed" => 1, "variant" => "A"}}
        },
        expressions: %{
          "is-complete-variant-b" => %{
            "source" => "signup.steps_completed >= 3 and signup.variant == 'B'"
          },
          "started-date" => %{"source" => "signup.started_at"},
          "malformed" => %{"source" => "signup.steps_completed +"}
        }
      )

    fixtures
  end

  defp verdict(table, expression, dataset) do
    {:ok, cell} = TruthTable.cell(table, expression, dataset)
    cell.verdict
  end

  describe "build/2 axes" do
    test "defaults to every expression and dataset, both sorted" do
      table = TruthTable.build(bundle())

      assert Enum.map(table.expressions, & &1.name) == [
               "is-complete-variant-b",
               "malformed",
               "started-date"
             ]

      assert table.datasets == ["variant-a-early", "variant-b-complete", "variant-b-sparse"]
    end

    test "carries each expression's source onto the axis" do
      table = TruthTable.build(bundle())

      assert %{
               name: "is-complete-variant-b",
               source: "signup.steps_completed >= 3 and signup.variant == 'B'"
             } =
               Enum.find(table.expressions, &(&1.name == "is-complete-variant-b"))
    end

    test "narrows and orders both axes when given them" do
      table =
        TruthTable.build(bundle(),
          expressions: ["started-date", "is-complete-variant-b"],
          datasets: ["variant-a-early", "variant-b-complete"]
        )

      assert Enum.map(table.expressions, & &1.name) == ["started-date", "is-complete-variant-b"]
      assert table.datasets == ["variant-a-early", "variant-b-complete"]
      assert map_size(table.cells) == 4
    end
  end

  describe "build/2 verdicts" do
    setup do
      %{table: TruthTable.build(bundle())}
    end

    test "a satisfied predicate is :satisfied, carrying the true it evaluated to", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "is-complete-variant-b", "variant-b-complete")

      assert cell.verdict == :satisfied
      assert cell.value == true
      assert cell.label == "true"
      assert cell.error == nil
    end

    test "an unsatisfied predicate is :unsatisfied", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "is-complete-variant-b", "variant-a-early")

      assert cell.verdict == :unsatisfied
      assert cell.value == false
      assert cell.label == "false"
    end

    test "an absent input is :undefined, never :unsatisfied", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "started-date", "variant-b-sparse")

      assert cell.verdict == :undefined
      assert cell.value == :undefined
      assert cell.label == "undefined"
    end

    test "a non-boolean result is :value, labelled with the value", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "started-date", "variant-b-complete")

      assert cell.verdict == :value
      assert cell.value == "2026-01-15"
      assert cell.label == "2026-01-15"
    end

    test "an evaluation failure is :error carrying the error as data", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "malformed", "variant-b-complete")

      assert cell.verdict == :error
      assert cell.value == nil
      assert %Predicator.Errors.ParseError{} = cell.error
    end
  end

  describe "undefined is never conflated with false" do
    setup do
      %{table: TruthTable.build(bundle())}
    end

    test "the undefined and unsatisfied verdicts are distinct terms", %{table: table} do
      undefined = verdict(table, "started-date", "variant-b-sparse")
      unsatisfied = verdict(table, "is-complete-variant-b", "variant-a-early")

      refute undefined == unsatisfied
      assert TruthTable.label(undefined) != TruthTable.label(unsatisfied)
    end

    test "no verdict is a boolean, so truthiness cannot sort undefined onto a side", %{
      table: table
    } do
      verdicts = table |> TruthTable.cells() |> Enum.map(& &1.verdict) |> Enum.uniq()

      assert verdicts != []
      refute Enum.any?(verdicts, &is_boolean/1)
    end

    test "the three truth values have three distinct labels" do
      labels = Enum.map([:satisfied, :unsatisfied, :undefined], &TruthTable.label/1)

      assert labels == ["true", "false", "undefined"]
      assert length(Enum.uniq(labels)) == 3
    end
  end

  describe "build/2 names that are on an axis but not in the bundle" do
    test "an unknown dataset yields :missing_dataset rather than a dropped column" do
      table = TruthTable.build(bundle(), datasets: ["variant-a-early", "no-such-dataset"])

      assert table.datasets == ["variant-a-early", "no-such-dataset"]
      {:ok, cell} = TruthTable.cell(table, "is-complete-variant-b", "no-such-dataset")

      assert cell.verdict == :missing_dataset
      assert cell.label == "no dataset"
      assert cell.value == nil
    end

    test "an unknown expression yields an :unknown_expression error and a nil source" do
      table = TruthTable.build(bundle(), expressions: ["no-such-expression"])

      assert [%{name: "no-such-expression", source: nil}] = table.expressions
      {:ok, cell} = TruthTable.cell(table, "no-such-expression", "variant-a-early")

      assert cell.verdict == :error
      assert cell.error == {:unknown_expression, "no-such-expression"}
    end
  end

  describe "row/2, column/2, cells/1 and cell/3" do
    setup do
      table =
        TruthTable.build(bundle(),
          expressions: ["is-complete-variant-b", "started-date"],
          datasets: ["variant-a-early", "variant-b-complete"]
        )

      %{table: table}
    end

    test "row/2 walks the dataset axis in order", %{table: table} do
      assert table |> TruthTable.row("is-complete-variant-b") |> Enum.map(& &1.dataset) ==
               ["variant-a-early", "variant-b-complete"]
    end

    test "column/2 walks the expression axis in order", %{table: table} do
      assert table |> TruthTable.column("variant-a-early") |> Enum.map(& &1.expression) ==
               ["is-complete-variant-b", "started-date"]
    end

    test "cells/1 is expression-then-dataset order", %{table: table} do
      assert table |> TruthTable.cells() |> Enum.map(&{&1.expression, &1.dataset}) == [
               {"is-complete-variant-b", "variant-a-early"},
               {"is-complete-variant-b", "variant-b-complete"},
               {"started-date", "variant-a-early"},
               {"started-date", "variant-b-complete"}
             ]
    end

    test "cell/3 returns :error for a name off the axes", %{table: table} do
      assert TruthTable.cell(table, "is-complete-variant-b", "variant-b-sparse") == :error
      assert TruthTable.cell(table, "malformed", "variant-a-early") == :error
    end

    test "row/2 for an off-axis expression reports it rather than returning nothing", %{
      table: table
    } do
      [cell | _rest] = TruthTable.row(table, "malformed")

      assert cell.verdict == :error
      assert cell.error == {:off_axis, "malformed", "variant-a-early"}
    end
  end

  describe "over the shared ADR-0006 fixture source" do
    test "builds the matrix ADR-0006 describes with no expectations consulted" do
      {:ok, fixtures} = Fixtures.from_source(ExpressionsSource)
      table = TruthTable.build(fixtures)

      assert Enum.map(table.expressions, & &1.name) == ["is-complete-variant-b", "started-date"]
      assert table.datasets == ["variant-a-early", "variant-b-complete"]

      assert verdict(table, "is-complete-variant-b", "variant-b-complete") == :satisfied
      assert verdict(table, "is-complete-variant-b", "variant-a-early") == :unsatisfied

      # Neither dataset carries a started_at, so both cells are undefined -
      # including the one whose stated `expect` is a Date. The table reports
      # what evaluates, not what was hoped for; disagreement with `expect` is
      # StatifierUI.Fixtures.Expectations' question.
      assert verdict(table, "started-date", "variant-b-complete") == :undefined
      assert verdict(table, "started-date", "variant-a-early") == :undefined
    end
  end

  describe "an empty bundle" do
    test "builds an empty table rather than failing" do
      {:ok, fixtures} = Fixtures.new()
      table = TruthTable.build(fixtures)

      assert table.expressions == []
      assert table.datasets == []
      assert table.cells == %{}
      assert TruthTable.cells(table) == []
    end
  end
end
