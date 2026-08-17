defmodule StatifierUI.FixturesTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
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

    test "defaults scenarios and events to empty maps" do
      assert {:ok, %Fixtures{scenarios: %{}, events: %{}}} = Fixtures.new()
    end

    test "rejects a non-map scenarios value" do
      assert {:error, _reason} = Fixtures.new(scenarios: [{"a", %{}}])
    end

    test "rejects an atom key at the top level of a scenario" do
      assert {:error, _reason} = Fixtures.new(scenarios: %{"s" => %{ok: 1}})
    end

    test "rejects an atom key nested three levels deep inside a list of maps" do
      scenario = %{"a" => %{"b" => [%{ok: 1}]}}
      assert {:error, _reason} = Fixtures.new(scenarios: %{"s" => scenario})
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

  describe "from_source/1" do
    test "builds a bundle from a full source" do
      assert {:ok, fixtures} = Fixtures.from_source(PaymentSource)

      assert Fixtures.scenario(fixtures, "gold-tier-user") ==
               {:ok, PaymentSource.scenarios()["gold-tier-user"]}

      assert Fixtures.event(fixtures, "payment.success") ==
               {:ok, %{"amount" => 1999, "currency" => "USD"}}
    end

    test "builds a bundle from an events-only source, defaulting scenarios to %{}" do
      assert {:ok, %Fixtures{scenarios: %{}}} = Fixtures.from_source(EventsOnlySource)
    end

    test "errors on a module that is not a source" do
      assert {:error, {:not_a_source, String}} = Fixtures.from_source(String)
    end

    test "errors on a module that does not exist" do
      assert {:error, {:not_a_source, StatifierUI.NoSuchModule}} =
               Fixtures.from_source(StatifierUI.NoSuchModule)
    end
  end

  describe "scenario_names/1 and event_names/1" do
    test "return keys in sorted order" do
      {:ok, fixtures} =
        Fixtures.new(
          scenarios: %{"b" => %{}, "a" => %{}, "c" => %{}},
          events: %{"z" => nil, "a" => nil}
        )

      assert Fixtures.scenario_names(fixtures) == ["a", "b", "c"]
      assert Fixtures.event_names(fixtures) == ["a", "z"]
    end
  end

  describe "scenario/2 and event/2" do
    test "return :error for a missing key" do
      {:ok, fixtures} = Fixtures.new()

      assert Fixtures.scenario(fixtures, "missing") == :error
      assert Fixtures.event(fixtures, "missing") == :error
    end
  end
end
