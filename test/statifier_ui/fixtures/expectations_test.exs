defmodule StatifierUI.Fixtures.ExpectationsTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.ExpectationError
  alias StatifierUI.Fixtures.Expectations
  alias StatifierUI.Fixtures.Sidecar

  @fixtures_dir "test/support/fixtures"

  defp fixtures!(opts) do
    {:ok, fixtures} = Fixtures.new(opts)
    fixtures
  end

  describe "ADR-0006's own example, over the real fixture file" do
    test "extended.fixtures.json's expectations all hold" do
      assert {:ok, fixtures} =
               Sidecar.load(Path.join(@fixtures_dir, "extended.fixtures.json"))

      assert Expectations.check(fixtures) == :ok
      assert Expectations.check!(fixtures) == :ok
    end

    test "run/2 reports both stated expectations as matches" do
      assert {:ok, fixtures} =
               Sidecar.load(Path.join(@fixtures_dir, "extended.fixtures.json"))

      results = Expectations.run(fixtures)

      assert Enum.map(results, &{&1.expression, &1.dataset, &1.status}) == [
               {"is-adult-us", "adult-us", :match},
               {"is-adult-us", "minor", :match}
             ]
    end
  end

  describe "a drifted expectation" do
    test "check/2 reports a mismatch naming both values" do
      fixtures =
        fixtures!(
          datasets: %{"adult-us" => %{"user" => %{"age" => 30, "country" => "US"}}},
          expressions: %{
            "is-adult-us" => %{
              "source" => "user.age >= 18 and user.country == 'US'",
              "expect" => %{"adult-us" => false}
            }
          }
        )

      assert {:error, [result]} = Expectations.check(fixtures)
      assert result.status == :mismatch
      assert result.expression == "is-adult-us"
      assert result.dataset == "adult-us"
      assert result.expected == false
      assert result.actual == true
    end

    test "check!/2 raises ExpectationError with a message naming the drift" do
      fixtures =
        fixtures!(
          datasets: %{"adult-us" => %{"user" => %{"age" => 30, "country" => "US"}}},
          expressions: %{
            "is-adult-us" => %{
              "source" => "user.age >= 18 and user.country == 'US'",
              "expect" => %{"adult-us" => false}
            }
          }
        )

      error =
        assert_raise ExpectationError, fn ->
          Expectations.check!(fixtures)
        end

      assert error.message =~ "is-adult-us"
      assert error.message =~ "adult-us"
      assert error.message =~ "false"
      assert error.message =~ "true"
    end
  end

  describe "the unbound-root versus missing-nested-path asymmetry" do
    # Predicator.evaluate/3 distinguishes a wholly unbound root variable (an
    # error) from a missing path underneath a bound one (an :undefined
    # value) - see the plan's Key Discoveries. These two cases pin that as
    # intentional, not a bug this runner papers over.
    test "an expression over a wholly unbound root is a :error result" do
      fixtures =
        fixtures!(
          datasets: %{"empty" => %{}},
          expressions: %{
            "reads-missing-root" => %{
              "source" => "missing",
              "expect" => %{"empty" => :undefined}
            }
          }
        )

      assert [result] = Expectations.run(fixtures)
      assert result.status == :error
      assert %Predicator.Errors.UndefinedVariableError{} = result.error
    end

    test "an expression over a missing nested path evaluates to :undefined" do
      fixtures =
        fixtures!(
          datasets: %{"bare-user" => %{"user" => %{}}},
          expressions: %{
            "reads-missing-path" => %{
              "source" => "user.nope",
              "expect" => %{"bare-user" => :undefined}
            }
          }
        )

      assert [result] = Expectations.run(fixtures)
      assert result.status == :match
      assert result.actual == :undefined
    end
  end

  describe "duration canonicalization" do
    test "a $duration expectation matches a seven-key evaluated duration" do
      fixtures =
        fixtures!(
          datasets: %{"empty" => %{}},
          expressions: %{
            "three-days" => %{
              "source" => "3d",
              "expect" => %{
                "empty" => %{
                  years: 0,
                  months: 0,
                  weeks: 0,
                  days: 3,
                  hours: 0,
                  minutes: 0,
                  seconds: 0
                }
              }
            }
          }
        )

      assert [result] = Expectations.run(fixtures)
      assert result.status == :match
    end
  end

  describe "a missing dataset" do
    test "an expect key naming no dataset is :missing_dataset, and check/2 fails" do
      fixtures =
        fixtures!(
          expressions: %{
            "orphaned" => %{
              "source" => "true",
              "expect" => %{"no-such-dataset" => true}
            }
          }
        )

      assert [result] = Expectations.run(fixtures)
      assert result.status == :missing_dataset
      assert result.actual == nil
      assert result.error == nil

      assert {:error, [^result]} = Expectations.check(fixtures)
    end
  end

  describe "an empty-expressions bundle" do
    test "run/2 returns [] and check/2 returns :ok" do
      fixtures = fixtures!([])

      assert Expectations.run(fixtures) == []
      assert Expectations.check(fixtures) == :ok
    end
  end

  describe "result ordering" do
    test "is stable, sorted by expression then dataset" do
      fixtures =
        fixtures!(
          datasets: %{
            "a" => %{},
            "b" => %{}
          },
          expressions: %{
            "z-expr" => %{"source" => "true", "expect" => %{"b" => true, "a" => true}},
            "a-expr" => %{"source" => "true", "expect" => %{"b" => true, "a" => true}}
          }
        )

      pairs = Enum.map(Expectations.run(fixtures), &{&1.expression, &1.dataset})

      assert pairs == [
               {"a-expr", "a"},
               {"a-expr", "b"},
               {"z-expr", "a"},
               {"z-expr", "b"}
             ]

      # Running again produces the same order.
      assert Enum.map(Expectations.run(fixtures), &{&1.expression, &1.dataset}) == pairs
    end
  end

  describe ":functions forwarding" do
    test "an expression calling a host-supplied function evaluates" do
      fixtures =
        fixtures!(
          datasets: %{"empty" => %{}},
          expressions: %{
            "doubled" => %{
              "source" => "double(21)",
              "expect" => %{"empty" => 42}
            }
          }
        )

      functions = %{"double" => {1, fn [n], _context -> {:ok, n * 2} end}}

      assert Expectations.check(fixtures, functions: functions) == :ok
    end
  end
end
