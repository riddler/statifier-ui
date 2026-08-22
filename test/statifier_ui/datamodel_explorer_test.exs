defmodule StatifierUI.DatamodelExplorerTest do
  use ExUnit.Case, async: true

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Fixtures.PaymentSource
  alias StatifierUI.Test.Support.Trace.SessionCase

  # One <data> declaration the "gold-tier-user" scenario names ("tier") and
  # one it does not name ("count") - so promotion and pass-through both
  # exercise on the same chart. No `name` attribute, matching scope_test.exs.
  @chart """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <datamodel>
          <data id="tier"/>
          <data id="count"/>
      </datamodel>
      <state id="a"/>
  </scxml>
  """

  setup do
    machine = SessionCase.compile!(@chart)
    {:ok, fixtures} = Fixtures.from_source(PaymentSource)
    {:ok, machine: machine, fixtures: fixtures}
  end

  describe "build_authoring/3 - nil fixtures" do
    test "scenario nil, scenario_names empty, every tier-1 entry :undefined", %{machine: machine} do
      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, nil)

      assert %DatamodelExplorer{
               mode: :authoring,
               session: nil,
               scenario: nil,
               scenario_names: [],
               macrostep: nil,
               truncated?: false,
               diagnostics: []
             } = pane

      assert Enum.all?(DatamodelExplorer.entries(pane, :data), &(&1.value == :undefined))
    end
  end

  describe "build_authoring/3 - a scenario naming a declared <data id>" do
    test "that entry's shape becomes the scenario value's, tier stays :data, d_index intact", %{
      machine: machine,
      fixtures: fixtures
    } do
      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      [tier_entry] = Enum.filter(DatamodelExplorer.entries(pane, :data), &(&1.name == "tier"))

      assert %{
               name: "tier",
               tier: :data,
               d_index: 0,
               value: "gold",
               shape: :string
             } = tier_entry
    end

    test "a tier-1 entry the scenario does not name stays :undefined", %{
      machine: machine,
      fixtures: fixtures
    } do
      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      assert %{tier: :data, value: :undefined} =
               Enum.find(DatamodelExplorer.entries(pane, :data), &(&1.name == "count"))
    end
  end

  describe "build_authoring/3 - a scenario naming something the chart does not declare" do
    test "a :scenario entry appears", %{machine: machine} do
      {:ok, fixtures} =
        Fixtures.new(scenarios: %{"gold-tier-user" => %{"user_id" => "u-1999"}})

      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      assert [%{name: "user_id", tier: :scenario, value: "u-1999", shape: :string}] =
               DatamodelExplorer.entries(pane, :scenario)
    end
  end

  describe "build_authoring/3 - scenario selection" do
    test "explicit :scenario selects that scenario", %{machine: machine, fixtures: fixtures} do
      assert {:ok, pane} =
               DatamodelExplorer.build_authoring(machine, fixtures, scenario: "gold-tier-user")

      assert pane.scenario == "gold-tier-user"
    end

    test "an unknown :scenario name returns {:error, {:unknown_scenario, name}}", %{
      machine: machine,
      fixtures: fixtures
    } do
      assert {:error, {:unknown_scenario, "no-such-scenario"}} =
               DatamodelExplorer.build_authoring(machine, fixtures, scenario: "no-such-scenario")
    end

    test "an unknown :scenario with nil fixtures also returns {:error, {:unknown_scenario, _}}",
         %{
           machine: machine
         } do
      assert {:error, {:unknown_scenario, "anything"}} =
               DatamodelExplorer.build_authoring(machine, nil, scenario: "anything")
    end

    test "default selection is the first sorted name, not the first inserted", %{
      machine: machine
    } do
      {:ok, fixtures} =
        Fixtures.new(
          scenarios: %{
            "zeta-scenario" => %{"tier" => "zeta"},
            "alpha-scenario" => %{"tier" => "alpha"}
          }
        )

      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      assert pane.scenario == "alpha-scenario"

      assert %{value: "alpha"} =
               Enum.find(DatamodelExplorer.entries(pane, :data), &(&1.name == "tier"))
    end
  end

  describe "build_authoring/3 - decoded values are not re-encoded" do
    test "a scenario value that is already a decoded Date infers :date, not a $-tagged map", %{
      machine: machine
    } do
      {:ok, fixtures} =
        Fixtures.new(scenarios: %{"gold-tier-user" => %{"tier" => ~D[2026-08-22]}})

      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      assert %{value: ~D[2026-08-22], shape: :date} =
               Enum.find(DatamodelExplorer.entries(pane, :data), &(&1.name == "tier"))
    end
  end

  describe "entries/2" do
    test "filters by tier", %{machine: machine, fixtures: fixtures} do
      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      assert Enum.all?(DatamodelExplorer.entries(pane, :data), &(&1.tier == :data))
      assert Enum.all?(DatamodelExplorer.entries(pane, :system), &(&1.tier == :system))
      assert Enum.all?(DatamodelExplorer.entries(pane, :function), &(&1.tier == :function))

      assert DatamodelExplorer.entries(pane) ==
               DatamodelExplorer.entries(pane, :data) ++
                 DatamodelExplorer.entries(pane, :system) ++
                 DatamodelExplorer.entries(pane, :function) ++
                 DatamodelExplorer.entries(pane, :scenario)
    end
  end

  describe "diagnostics/1" do
    test "bundle diagnostics are carried through ahead of the scope's own", %{machine: machine} do
      fixtures = %Fixtures{
        scenarios: %{"gold-tier-user" => %{"tier" => "gold"}},
        diagnostics: [
          %{kind: :some_bundle_problem, message: "pre-existing", path: ["x"], source: nil}
        ]
      }

      assert {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      assert [%{kind: :some_bundle_problem}] = DatamodelExplorer.diagnostics(pane)
    end
  end
end
