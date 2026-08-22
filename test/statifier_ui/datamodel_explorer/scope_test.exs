defmodule StatifierUI.DatamodelExplorer.ScopeTest do
  use ExUnit.Case, async: true

  alias Statifier.Evaluator.SystemVariables
  alias StatifierUI.DatamodelExplorer.Scope
  alias StatifierUI.Test.Support.Trace.SessionCase

  # Three <data> elements - one bare, one with an `expr`, one bare again -
  # so d_index order, declared-source slicing, and the bare-element guard
  # (`value_location == location`) are all exercised on one chart. No
  # `name` attribute on `<scxml>`, so tier 2a's `_name` infers `:undefined`.
  @chart """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <datamodel>
          <data id="first"/>
          <data id="count" expr="41 + 1"/>
          <data id="third"/>
      </datamodel>
      <state id="a"/>
  </scxml>
  """

  setup do
    {:ok, machine: SessionCase.compile!(@chart)}
  end

  describe "build/2 - tier 1 (<data> declarations)" do
    test "entries come back in d_index order, all :undefined, with d_index set", %{
      machine: machine
    } do
      assert {:ok, %Scope{data: entries}} = Scope.build(machine)

      assert [
               %{name: "first", tier: :data, d_index: 0, value: :undefined},
               %{name: "count", tier: :data, d_index: 1, value: :undefined},
               %{name: "third", tier: :data, d_index: 2, value: :undefined}
             ] = entries
    end

    test "an expr-written element's declared_source holds the expression text, unevaluated", %{
      machine: machine
    } do
      assert {:ok, %Scope{data: entries}} = Scope.build(machine, source: @chart)

      assert %{value: :undefined, declared_source: "41 + 1"} =
               Enum.find(entries, &(&1.name == "count"))
    end

    test "a bare element's declared_source is nil even when :source is given", %{
      machine: machine
    } do
      assert {:ok, %Scope{data: entries}} = Scope.build(machine, source: @chart)

      assert %{declared_source: nil} = Enum.find(entries, &(&1.name == "first"))
      assert %{declared_source: nil} = Enum.find(entries, &(&1.name == "third"))
    end

    test "with :source omitted, every declared_source is nil and there are no diagnostics", %{
      machine: machine
    } do
      assert {:ok, %Scope{data: entries, diagnostics: diagnostics}} = Scope.build(machine)

      assert Enum.all?(entries, &is_nil(&1.declared_source))
      assert diagnostics == []
    end

    test "an out-of-range :source yields one diagnostic and a nil declared_source, not a failed build",
         %{machine: machine} do
      assert {:ok, %Scope{data: entries, diagnostics: diagnostics}} =
               Scope.build(machine, source: "x")

      assert %{declared_source: nil} = Enum.find(entries, &(&1.name == "count"))
      assert [%{kind: :unsliceable_declared_source, path: ["data", "count"]}] = diagnostics
    end
  end

  describe "build/2 - tier 2a (system variables)" do
    test "exactly the four names initial/2 seeds, with no _x", %{machine: machine} do
      assert {:ok, %Scope{system: entries}} = Scope.build(machine)

      assert Enum.map(entries, & &1.name) |> Enum.sort() ==
               ["_event", "_ioprocessors", "_name", "_sessionid"]
    end

    test "_sessionid infers :string, _ioprocessors a nested map, _event and _name :undefined", %{
      machine: machine
    } do
      assert {:ok, %Scope{system: entries}} = Scope.build(machine)
      by_name = Map.new(entries, &{&1.name, &1})

      assert %{shape: :string} = by_name["_sessionid"]
      assert %{shape: {:map, _pairs}} = by_name["_ioprocessors"]
      assert %{shape: :undefined, value: :undefined} = by_name["_event"]
      assert %{shape: :undefined, value: :undefined} = by_name["_name"]
    end

    test "_event's children are exactly the keys of SystemVariables.event/1's result", %{
      machine: machine
    } do
      assert {:ok, %Scope{system: entries}} = Scope.build(machine)
      event_entry = Enum.find(entries, &(&1.name == "_event"))

      expected =
        "(none)"
        |> Statifier.Event.external()
        |> SystemVariables.event()
        |> Map.keys()
        |> Enum.sort()

      assert Enum.map(event_entry.children, & &1.name) |> Enum.sort() == expected
      assert Enum.all?(event_entry.children, &(&1.value == :undefined))
    end
  end

  describe "build/2 - tier 2b (provider functions)" do
    test "In is present at arity 1, a multi-arity builtin renders name/a|b, entries sorted", %{
      machine: machine
    } do
      assert {:ok, %Scope{functions: entries}} = Scope.build(machine)

      assert %{arity: 1, label: "In/1", tier: :function} =
               Enum.find(entries, &(&1.name == "In"))

      assert %{arity: [2, 3], label: "substring/2|3"} =
               Enum.find(entries, &(&1.name == "substring"))

      names = Enum.map(entries, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "build/2 - invalid input" do
    test "returns {:error, {:invalid_machine, _}} for anything that is not a Machine" do
      assert {:error, {:invalid_machine, %{}}} = Scope.build(%{})
      assert {:error, {:invalid_machine, "nope"}} = Scope.build("nope")
    end
  end
end
