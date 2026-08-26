defmodule StatifierUI.TruthTableTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Fixtures.ExpressionsSource
  alias StatifierUI.TruthTable

  doctest StatifierUI.TruthTable

  # Four datasets chosen so every verdict the type carries is reachable from
  # one bundle: an adult with a signup date, an adult without one, a minor,
  # and a record whose age is the wrong type.
  defp bundle do
    {:ok, fixtures} =
      Fixtures.new(
        datasets: %{
          "adult-us" => %{
            "user" => %{"age" => 30, "country" => "US", "signup_date" => "2026-01-15"}
          },
          "adult-sparse" => %{"user" => %{"age" => 30, "country" => "US"}},
          "minor" => %{"user" => %{"age" => 15, "country" => "US"}}
        },
        expressions: %{
          "is-adult-us" => %{"source" => "user.age >= 18 and user.country == 'US'"},
          "signup-date" => %{"source" => "user.signup_date"},
          "malformed" => %{"source" => "user.age +"}
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

      assert Enum.map(table.expressions, & &1.name) == ["is-adult-us", "malformed", "signup-date"]
      assert table.datasets == ["adult-sparse", "adult-us", "minor"]
    end

    test "carries each expression's source onto the axis" do
      table = TruthTable.build(bundle())

      assert %{name: "is-adult-us", source: "user.age >= 18 and user.country == 'US'"} =
               Enum.find(table.expressions, &(&1.name == "is-adult-us"))
    end

    test "narrows and orders both axes when given them" do
      table =
        TruthTable.build(bundle(),
          expressions: ["signup-date", "is-adult-us"],
          datasets: ["minor", "adult-us"]
        )

      assert Enum.map(table.expressions, & &1.name) == ["signup-date", "is-adult-us"]
      assert table.datasets == ["minor", "adult-us"]
      assert map_size(table.cells) == 4
    end
  end

  describe "build/2 verdicts" do
    setup do
      %{table: TruthTable.build(bundle())}
    end

    test "a satisfied predicate is :satisfied, carrying the true it evaluated to", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "is-adult-us", "adult-us")

      assert cell.verdict == :satisfied
      assert cell.value == true
      assert cell.label == "true"
      assert cell.error == nil
    end

    test "an unsatisfied predicate is :unsatisfied", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "is-adult-us", "minor")

      assert cell.verdict == :unsatisfied
      assert cell.value == false
      assert cell.label == "false"
    end

    test "an absent input is :undefined, never :unsatisfied", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "signup-date", "adult-sparse")

      assert cell.verdict == :undefined
      assert cell.value == :undefined
      assert cell.label == "undefined"
    end

    test "a non-boolean result is :value, labelled with the value", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "signup-date", "adult-us")

      assert cell.verdict == :value
      assert cell.value == "2026-01-15"
      assert cell.label == "2026-01-15"
    end

    test "an evaluation failure is :error carrying the error as data", %{table: table} do
      {:ok, cell} = TruthTable.cell(table, "malformed", "adult-us")

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
      undefined = verdict(table, "signup-date", "adult-sparse")
      unsatisfied = verdict(table, "is-adult-us", "minor")

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
      table = TruthTable.build(bundle(), datasets: ["minor", "no-such-dataset"])

      assert table.datasets == ["minor", "no-such-dataset"]
      {:ok, cell} = TruthTable.cell(table, "is-adult-us", "no-such-dataset")

      assert cell.verdict == :missing_dataset
      assert cell.label == "no dataset"
      assert cell.value == nil
    end

    test "an unknown expression yields an :unknown_expression error and a nil source" do
      table = TruthTable.build(bundle(), expressions: ["no-such-expression"])

      assert [%{name: "no-such-expression", source: nil}] = table.expressions
      {:ok, cell} = TruthTable.cell(table, "no-such-expression", "minor")

      assert cell.verdict == :error
      assert cell.error == {:unknown_expression, "no-such-expression"}
    end
  end

  describe "row/2, column/2, cells/1 and cell/3" do
    setup do
      table =
        TruthTable.build(bundle(),
          expressions: ["is-adult-us", "signup-date"],
          datasets: ["minor", "adult-us"]
        )

      %{table: table}
    end

    test "row/2 walks the dataset axis in order", %{table: table} do
      assert table |> TruthTable.row("is-adult-us") |> Enum.map(& &1.dataset) ==
               ["minor", "adult-us"]
    end

    test "column/2 walks the expression axis in order", %{table: table} do
      assert table |> TruthTable.column("minor") |> Enum.map(& &1.expression) ==
               ["is-adult-us", "signup-date"]
    end

    test "cells/1 is expression-then-dataset order", %{table: table} do
      assert table |> TruthTable.cells() |> Enum.map(&{&1.expression, &1.dataset}) == [
               {"is-adult-us", "minor"},
               {"is-adult-us", "adult-us"},
               {"signup-date", "minor"},
               {"signup-date", "adult-us"}
             ]
    end

    test "cell/3 returns :error for a name off the axes", %{table: table} do
      assert TruthTable.cell(table, "is-adult-us", "adult-sparse") == :error
      assert TruthTable.cell(table, "malformed", "minor") == :error
    end

    test "row/2 for an off-axis expression reports it rather than returning nothing", %{
      table: table
    } do
      [cell | _rest] = TruthTable.row(table, "malformed")

      assert cell.verdict == :error
      assert cell.error == {:off_axis, "malformed", "minor"}
    end
  end

  describe "over the shared ADR-0006 fixture source" do
    test "builds the matrix ADR-0006 describes with no expectations consulted" do
      {:ok, fixtures} = Fixtures.from_source(ExpressionsSource)
      table = TruthTable.build(fixtures)

      assert Enum.map(table.expressions, & &1.name) == ["is-adult-us", "signup-date"]
      assert table.datasets == ["adult-us", "minor"]

      assert verdict(table, "is-adult-us", "adult-us") == :satisfied
      assert verdict(table, "is-adult-us", "minor") == :unsatisfied

      # Neither dataset carries a signup_date, so both cells are undefined -
      # including the one whose stated `expect` is a Date. The table reports
      # what evaluates, not what was hoped for; disagreement with `expect` is
      # StatifierUI.Fixtures.Expectations' question.
      assert verdict(table, "signup-date", "adult-us") == :undefined
      assert verdict(table, "signup-date", "minor") == :undefined
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
