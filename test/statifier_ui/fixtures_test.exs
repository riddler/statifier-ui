defmodule StatifierUI.FixturesTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Fixtures.BehaviourOnlySource
  alias StatifierUI.Test.Support.Fixtures.EventsOnlySource
  alias StatifierUI.Test.Support.Fixtures.PaymentSource

  describe "new/1" do
    test "builds a valid bundle" do
      assert {:ok, %Fixtures{} = fixtures} =
               Fixtures.new(
                 scenarios: %{"gold-tier-user" => %{"tier" => "gold"}},
                 events: %{"payment.success" => %{"amount" => 1999}}
               )

      assert fixtures.scenarios == %{"gold-tier-user" => %{"tier" => "gold"}}
      assert fixtures.events == %{"payment.success" => %{"amount" => 1999}}
      assert fixtures.diagnostics == []
    end

    test "defaults scenarios, events, and datasets to empty maps" do
      assert {:ok, %Fixtures{scenarios: %{}, events: %{}, datasets: %{}}} = Fixtures.new()
    end

    test "rejects a non-map scenarios value" do
      assert {:error, _reason} = Fixtures.new(scenarios: [{"a", %{}}])
    end

    test "rejects an atom key at the top level of a scenario, naming the scenario" do
      assert {:error, {:invalid_key, :ok, ["s"]}} =
               Fixtures.new(scenarios: %{"s" => %{ok: 1}})
    end

    test "rejects an atom key nested three levels deep inside a list of maps" do
      scenario = %{"a" => %{"b" => [%{ok: 1}]}}

      assert {:error, {:invalid_key, :ok, ["s", "a", "b", 0]}} =
               Fixtures.new(scenarios: %{"s" => scenario})
    end

    test "a key error names the scenario it came from, not just the key" do
      scenarios = %{
        "fine" => %{"tier" => "gold"},
        "broken" => %{"user" => %{bad: 1}}
      }

      assert {:error, {:invalid_key, :bad, ["broken", "user"]}} =
               Fixtures.new(scenarios: scenarios)
    end

    # The engine's own rule is `is_atom(key) and not is_boolean(key)`, so it
    # accepts these two; a sidecar can never express them, so we do not.
    test "is stricter than the engine: an integer key is rejected" do
      assert {:error, {:invalid_key, 1, ["s"]}} = Fixtures.new(scenarios: %{"s" => %{1 => "x"}})
    end

    test "is stricter than the engine: a boolean key is rejected" do
      assert {:error, {:invalid_key, true, ["s"]}} =
               Fixtures.new(scenarios: %{"s" => %{true => "x"}})
    end

    test "a duration in scenario data says so, rather than naming a unit key" do
      scenario = %{"trial_left" => %{days: 14}}

      assert {:error, {:duration_in_scenario, ["s", "trial_left"]}} =
               Fixtures.new(scenarios: %{"s" => scenario})
    end

    test "a duration in an event payload is accepted" do
      assert {:ok, %Fixtures{}} =
               Fixtures.new(events: %{"grace.granted" => %{days: 14}})
    end

    test "accepts Date and DateTime struct values without walking them" do
      scenario = %{"created_at" => Date.utc_today(), "updated_at" => DateTime.utc_now()}
      assert {:ok, %Fixtures{}} = Fixtures.new(scenarios: %{"s" => scenario})
    end

    test "preserves an event value of nil" do
      assert {:ok, fixtures} = Fixtures.new(events: %{"ping" => nil})
      assert Fixtures.event(fixtures, "ping") == {:ok, nil}
    end

    test "preserves an event value of :undefined" do
      assert {:ok, fixtures} = Fixtures.new(events: %{"ping" => :undefined})
      assert Fixtures.event(fixtures, "ping") == {:ok, :undefined}
    end

    test "preserves an event value of %{} distinct from nil and :undefined" do
      assert {:ok, fixtures} = Fixtures.new(events: %{"ping" => %{}})
      assert Fixtures.event(fixtures, "ping") == {:ok, %{}}
    end
  end

  describe "new/1 - datasets" do
    test "builds a valid bundle" do
      assert {:ok, %Fixtures{datasets: datasets}} =
               Fixtures.new(datasets: %{"minor" => %{"user" => %{"age" => 15}}})

      assert datasets == %{"minor" => %{"user" => %{"age" => 15}}}
    end

    test "rejects a non-map datasets value" do
      assert {:error, {:invalid_datasets, [{"a", %{}}]}} =
               Fixtures.new(datasets: [{"a", %{}}])
    end

    test "rejects a non-binary dataset name" do
      assert {:error, {:invalid_dataset_name, :minor}} =
               Fixtures.new(datasets: %{minor: %{}})
    end

    test "rejects a non-map dataset entry, naming the dataset" do
      assert {:error, {:invalid_dataset, "minor"}} =
               Fixtures.new(datasets: %{"minor" => "not-a-map"})
    end

    test "rejects an atom key at depth, naming the dataset in its path" do
      dataset = %{"user" => %{ok: 1}}

      assert {:error, {:invalid_key, :ok, ["minor", "user"]}} =
               Fixtures.new(datasets: %{"minor" => dataset})
    end

    test "a duration in dataset data says :duration_in_dataset, naming the path" do
      dataset = %{"trial_left" => %{days: 14}}

      assert {:error, {:duration_in_dataset, ["minor", "trial_left"]}} =
               Fixtures.new(datasets: %{"minor" => dataset})
    end
  end

  describe "from_source/1" do
    test "builds a bundle from a full source" do
      assert {:ok, fixtures} = Fixtures.from_source(PaymentSource)

      assert Fixtures.scenario(fixtures, "gold-tier-user") ==
               {:ok, PaymentSource.scenarios()["gold-tier-user"]}

      assert Fixtures.event(fixtures, "payment.success") ==
               {:ok, %{"amount" => 1999, "currency" => "USD"}}
    end

    test "builds a bundle from an events-only source, defaulting scenarios and datasets to %{}" do
      assert {:ok, %Fixtures{scenarios: %{}, datasets: %{}}} =
               Fixtures.from_source(EventsOnlySource)
    end

    test "errors on a module that is not a source" do
      assert {:error, {:not_a_source, String}} = Fixtures.from_source(String)
    end

    test "errors on a module that does not exist" do
      assert {:error, {:not_a_source, StatifierUI.NoSuchModule}} =
               Fixtures.from_source(StatifierUI.NoSuchModule)
    end

    test "builds a bundle from a hand-written @behaviour module (no use), defaulting datasets to %{}" do
      assert {:ok, %Fixtures{datasets: %{}} = fixtures} =
               Fixtures.from_source(BehaviourOnlySource)

      assert Fixtures.scenario(fixtures, "handwritten") == {:ok, %{"ok" => true}}
    end
  end

  describe "scenario_names/1, event_names/1, and dataset_names/1" do
    test "return keys in sorted order" do
      {:ok, fixtures} =
        Fixtures.new(
          scenarios: %{"b" => %{}, "a" => %{}, "c" => %{}},
          events: %{"z" => nil, "a" => nil},
          datasets: %{"y" => %{}, "b" => %{}}
        )

      assert Fixtures.scenario_names(fixtures) == ["a", "b", "c"]
      assert Fixtures.event_names(fixtures) == ["a", "z"]
      assert Fixtures.dataset_names(fixtures) == ["b", "y"]
    end
  end

  describe "scenario/2, event/2, and dataset/2" do
    test "return :error for a missing key" do
      {:ok, fixtures} = Fixtures.new()

      assert Fixtures.scenario(fixtures, "missing") == :error
      assert Fixtures.event(fixtures, "missing") == :error
      assert Fixtures.dataset(fixtures, "missing") == :error
    end

    test "dataset/2 fetches a dataset by name" do
      {:ok, fixtures} = Fixtures.new(datasets: %{"minor" => %{"user" => %{"age" => 15}}})

      assert Fixtures.dataset(fixtures, "minor") == {:ok, %{"user" => %{"age" => 15}}}
    end
  end
end
