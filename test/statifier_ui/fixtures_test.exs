defmodule StatifierUI.FixturesTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Fixtures.AuthorizationSource
  alias StatifierUI.Test.Support.Fixtures.BehaviourOnlySource
  alias StatifierUI.Test.Support.Fixtures.EventsOnlySource

  describe "new/1" do
    test "builds a valid bundle" do
      assert {:ok, %Fixtures{} = fixtures} =
               Fixtures.new(
                 scenarios: %{"within-budget-account" => %{"tier" => "gold"}},
                 events: %{"authorize.approved" => %{"amount_cents" => 1999}}
               )

      assert fixtures.scenarios == %{"within-budget-account" => %{"tier" => "gold"}}
      assert fixtures.events == %{"authorize.approved" => %{"amount_cents" => 1999}}
      assert fixtures.diagnostics == []
    end

    test "defaults scenarios, events, datasets, and expressions to empty maps" do
      assert {:ok, %Fixtures{scenarios: %{}, events: %{}, datasets: %{}, expressions: %{}}} =
               Fixtures.new()
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
               Fixtures.new(
                 datasets: %{"variant-a-early" => %{"signup" => %{"steps_completed" => 1}}}
               )

      assert datasets == %{"variant-a-early" => %{"signup" => %{"steps_completed" => 1}}}
    end

    test "rejects a non-map datasets value" do
      assert {:error, {:invalid_datasets, [{"a", %{}}]}} =
               Fixtures.new(datasets: [{"a", %{}}])
    end

    test "rejects a non-binary dataset name" do
      assert {:error, {:invalid_dataset_name, :variant_a_early}} =
               Fixtures.new(datasets: %{variant_a_early: %{}})
    end

    test "rejects a non-map dataset entry, naming the dataset" do
      assert {:error, {:invalid_dataset, "variant-a-early"}} =
               Fixtures.new(datasets: %{"variant-a-early" => "not-a-map"})
    end

    test "rejects an atom key at depth, naming the dataset in its path" do
      dataset = %{"user" => %{ok: 1}}

      assert {:error, {:invalid_key, :ok, ["variant-a-early", "user"]}} =
               Fixtures.new(datasets: %{"variant-a-early" => dataset})
    end

    test "a duration in dataset data says :duration_in_dataset, naming the path" do
      dataset = %{"trial_left" => %{days: 14}}

      assert {:error, {:duration_in_dataset, ["variant-a-early", "trial_left"]}} =
               Fixtures.new(datasets: %{"variant-a-early" => dataset})
    end
  end

  describe "new/1 - expressions" do
    test "builds a valid bundle" do
      assert {:ok, %Fixtures{expressions: expressions}} =
               Fixtures.new(
                 expressions: %{
                   "is-complete-variant-b" => %{
                     "source" => "signup.steps_completed >= 3",
                     "expect" => %{"variant-a-early" => false, "variant-b-complete" => true}
                   }
                 }
               )

      assert expressions == %{
               "is-complete-variant-b" => %{
                 "source" => "signup.steps_completed >= 3",
                 "expect" => %{"variant-a-early" => false, "variant-b-complete" => true}
               }
             }
    end

    test "rejects a non-map expressions value" do
      assert {:error, {:invalid_expressions, [{"a", %{}}]}} =
               Fixtures.new(expressions: [{"a", %{}}])
    end

    test "rejects a non-binary expression name" do
      assert {:error, {:invalid_expression_name, :e}} =
               Fixtures.new(expressions: %{e: %{"source" => "x"}})
    end

    test "rejects a non-map expression entry, naming the expression" do
      assert {:error, {:invalid_expression, "e"}} =
               Fixtures.new(expressions: %{"e" => "not-a-map"})
    end

    test "rejects an entry with no source key" do
      assert {:error, {:invalid_expression_source, "e"}} =
               Fixtures.new(expressions: %{"e" => %{}})
    end

    test "rejects an entry whose source is not a binary" do
      assert {:error, {:invalid_expression_source, "e"}} =
               Fixtures.new(expressions: %{"e" => %{"source" => 1}})
    end

    test "accepts an entry with no expect key" do
      assert {:ok, %Fixtures{}} = Fixtures.new(expressions: %{"e" => %{"source" => "x"}})
    end

    test "rejects an entry whose expect is not a map" do
      assert {:error, {:invalid_expect, "e"}} =
               Fixtures.new(expressions: %{"e" => %{"source" => "x", "expect" => "not-a-map"}})
    end

    test "rejects an entry whose expect has a non-binary key" do
      assert {:error, {:invalid_expect, "e"}} =
               Fixtures.new(
                 expressions: %{"e" => %{"source" => "x", "expect" => %{variant_a_early: false}}}
               )
    end

    test "accepts a duration as an expect value, since expect values are not key-walked" do
      assert {:ok, %Fixtures{}} =
               Fixtures.new(
                 expressions: %{
                   "e" => %{"source" => "x", "expect" => %{"variant-a-early" => %{days: 14}}}
                 }
               )
    end

    test "rejects an entry with a non-binary key other than source or expect" do
      assert {:error, {:invalid_expression_key, "e", :note}} =
               Fixtures.new(expressions: %{"e" => %{"source" => "x", note: "hi"}})
    end

    test "preserves an entry key other than source and expect verbatim" do
      assert {:ok, fixtures} =
               Fixtures.new(expressions: %{"e" => %{"source" => "x", "note" => "hi"}})

      assert {:ok, %{"note" => "hi"}} = Fixtures.expression(fixtures, "e")
    end
  end

  describe "expression_names/1" do
    test "returns names in sorted order" do
      {:ok, fixtures} =
        Fixtures.new(
          expressions: %{
            "z" => %{"source" => "x"},
            "a" => %{"source" => "x"}
          }
        )

      assert Fixtures.expression_names(fixtures) == ["a", "z"]
    end
  end

  describe "expect/3" do
    setup do
      {:ok, fixtures} =
        Fixtures.new(
          expressions: %{
            "is-complete-variant-b" => %{
              "source" => "signup.steps_completed >= 3",
              "expect" => %{"variant-a-early" => false, "variant-b-complete" => true}
            },
            "no-expectations" => %{"source" => "x"}
          }
        )

      %{fixtures: fixtures}
    end

    test "returns the stated expectation", %{fixtures: fixtures} do
      assert Fixtures.expect(fixtures, "is-complete-variant-b", "variant-b-complete") ==
               {:ok, true}
    end

    test "returns :error when no expectation is stated for a real dataset", %{fixtures: fixtures} do
      assert Fixtures.expect(fixtures, "no-expectations", "variant-b-complete") == :error
    end

    test "returns :error for an unknown expression", %{fixtures: fixtures} do
      assert Fixtures.expect(fixtures, "no-such-expression", "variant-b-complete") == :error
    end
  end

  describe "from_source/1" do
    test "builds a bundle from a full source" do
      assert {:ok, fixtures} = Fixtures.from_source(AuthorizationSource)

      assert Fixtures.scenario(fixtures, "within-budget-account") ==
               {:ok, AuthorizationSource.scenarios()["within-budget-account"]}

      assert Fixtures.event(fixtures, "authorize.approved") ==
               {:ok, %{"amount_cents" => 1999, "currency" => "USD"}}
    end

    test "builds a bundle from an events-only source, defaulting scenarios, datasets, and expressions to %{}" do
      assert {:ok, %Fixtures{scenarios: %{}, datasets: %{}, expressions: %{}}} =
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
      {:ok, fixtures} =
        Fixtures.new(datasets: %{"variant-a-early" => %{"signup" => %{"steps_completed" => 1}}})

      assert Fixtures.dataset(fixtures, "variant-a-early") ==
               {:ok, %{"signup" => %{"steps_completed" => 1}}}
    end
  end
end
