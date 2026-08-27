defmodule StatifierUI.Fixtures.LintTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Lint

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp fixtures!(opts) do
    {:ok, fixtures} = Fixtures.new(opts)
    fixtures
  end

  @guarded """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <state id="a">
          <transition cond="signup.steps_completed &gt;= 4" target="b"/>
        </state>
        <state id="b"/>
      </scxml>
  """

  # Same guard as @guarded, with one state inserted above it so every
  # t_index in the document shifts. The transition's guard source text is
  # unchanged.
  @guarded_shifted """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="inserted" datamodel="predicator">
        <state id="inserted">
          <transition event="go" target="a"/>
        </state>
        <state id="a">
          <transition cond="signup.steps_completed &gt;= 4" target="b"/>
        </state>
        <state id="b"/>
      </scxml>
  """

  @static_and_bare """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
        <state id="a">
          <transition cond="true" target="b"/>
        </state>
        <state id="b">
          <transition event="go" target="a"/>
        </state>
      </scxml>
  """

  describe "guard_matches/2" do
    test "matches an expression whose source is byte-equal to a guard, naming its t_index" do
      machine = compile!(@guarded)

      fixtures =
        fixtures!(expressions: %{"is-complete" => %{"source" => "signup.steps_completed >= 4"}})

      assert %{"is-complete" => [t_index]} = Lint.guard_matches(fixtures, machine)
      assert is_integer(t_index)
    end

    test "does not match a source differing only by whitespace or quoting" do
      machine = compile!(@guarded)

      fixtures =
        fixtures!(expressions: %{"is-complete" => %{"source" => "signup.steps_completed  >=  4"}})

      assert Lint.guard_matches(fixtures, machine) == %{"is-complete" => []}
    end

    test "keeps matching the same guard after an edit shifts t_index values" do
      before_machine = compile!(@guarded)
      after_machine = compile!(@guarded_shifted)

      fixtures =
        fixtures!(expressions: %{"is-complete" => %{"source" => "signup.steps_completed >= 4"}})

      assert %{"is-complete" => [before_t_index]} = Lint.guard_matches(fixtures, before_machine)
      assert %{"is-complete" => [after_t_index]} = Lint.guard_matches(fixtures, after_machine)

      # The match is on the guard's source text, not on any particular
      # index - the state inserted above shifted the transition's t_index,
      # and the match survives that shift by construction. Assert the
      # matched transition's guard source is the same in both machines,
      # which is the property that actually matters (the indexes
      # themselves may or may not differ depending on compiler internals).
      assert Statifier.Machine.transition(before_machine, before_t_index).cond ==
               Statifier.Machine.transition(after_machine, after_t_index).cond
    end

    test "skips a static-literal guard and a transition with no cond, without error" do
      machine = compile!(@static_and_bare)

      fixtures =
        fixtures!(expressions: %{"unrelated" => %{"source" => "1 + 1"}})

      assert Lint.guard_matches(fixtures, machine) == %{"unrelated" => []}
    end

    test "a bundle with no expressions lints clean against any chart" do
      machine = compile!(@guarded)
      fixtures = fixtures!([])

      assert Lint.guard_matches(fixtures, machine) == %{}
    end
  end

  describe "unmatched_expressions/2" do
    test "emits a warning for a source with no byte-equal guard" do
      machine = compile!(@guarded)

      fixtures =
        fixtures!(expressions: %{"is-complete" => %{"source" => "signup.steps_completed  >=  4"}})

      assert [diagnostic] = Lint.unmatched_expressions(fixtures, machine)
      assert diagnostic.kind == :unmatched_expression
      assert diagnostic.path == ["is-complete"]
    end

    # Sabotage: dropped the `: #{inspect(source)}` half of the message in
    # `unmatched_expressions/2` - this test went red on the second assert,
    # the two below it stayed green.
    test "the message carries the source text, so a near miss is readable" do
      machine = compile!(@guarded)

      # Byte-unequal to @guarded's "user.age >= 21" by whitespace alone -
      # the drift a bare "no match" message leaves invisible.
      fixtures =
        fixtures!(expressions: %{"is-adult" => %{"source" => "user.age  >=  21"}})

      assert [diagnostic] = Lint.unmatched_expressions(fixtures, machine)
      assert diagnostic.message =~ inspect("user.age  >=  21")
      assert diagnostic.message =~ "is-adult"
    end

    test "emits nothing for a matched expression" do
      machine = compile!(@guarded)

      fixtures =
        fixtures!(expressions: %{"is-complete" => %{"source" => "signup.steps_completed >= 4"}})

      assert Lint.unmatched_expressions(fixtures, machine) == []
    end

    test "a bundle with no expressions lints clean" do
      machine = compile!(@guarded)
      fixtures = fixtures!([])

      assert Lint.unmatched_expressions(fixtures, machine) == []
    end
  end

  describe "dangling_expect_keys/1" do
    test "emits exactly one finding for an expect key naming no dataset" do
      fixtures =
        fixtures!(
          datasets: %{"variant-b-complete" => %{"signup" => %{"steps_completed" => 4}}},
          expressions: %{
            "is-complete" => %{
              "source" => "signup.steps_completed >= 4",
              "expect" => %{"variant-b-complete" => true, "missing-dataset" => true}
            }
          }
        )

      assert [diagnostic] = Lint.dangling_expect_keys(fixtures)
      assert diagnostic.kind == :dangling_expect_dataset
      assert diagnostic.path == ["is-complete", "expect", "missing-dataset"]
    end

    test "emits nothing when every expect key names a real dataset" do
      fixtures =
        fixtures!(
          datasets: %{"variant-b-complete" => %{"signup" => %{"steps_completed" => 4}}},
          expressions: %{
            "is-complete" => %{
              "source" => "signup.steps_completed >= 4",
              "expect" => %{"variant-b-complete" => true}
            }
          }
        )

      assert Lint.dangling_expect_keys(fixtures) == []
    end

    test "needs no machine - callable on a bundle alone" do
      fixtures =
        fixtures!(
          expressions: %{
            "is-complete" => %{"source" => "signup.steps_completed >= 4", "expect" => %{"x" => 1}}
          }
        )

      assert [%{kind: :dangling_expect_dataset}] = Lint.dangling_expect_keys(fixtures)
    end
  end

  describe "lint/2" do
    test "composes both checks and sorts by path" do
      machine = compile!(@guarded)

      fixtures =
        fixtures!(
          datasets: %{"variant-b-complete" => %{"signup" => %{"steps_completed" => 4}}},
          expressions: %{
            "unmatched" => %{"source" => "does not match anything"},
            "is-complete" => %{
              "source" => "signup.steps_completed >= 4",
              "expect" => %{"missing-dataset" => true}
            }
          }
        )

      findings = Lint.lint(fixtures, machine)

      assert findings == Enum.sort_by(findings, & &1.path)

      assert Enum.map(findings, & &1.kind) |> Enum.sort() ==
               [:dangling_expect_dataset, :unmatched_expression]
    end

    test "with nil machine, runs only the machine-free check" do
      fixtures =
        fixtures!(
          expressions: %{
            "unmatched" => %{"source" => "does not match anything"},
            "is-complete" => %{
              "source" => "signup.steps_completed >= 4",
              "expect" => %{"missing-dataset" => true}
            }
          }
        )

      findings = Lint.lint(fixtures, nil)

      assert Enum.map(findings, & &1.kind) == [:dangling_expect_dataset]
    end

    test "every finding's kind is a warning kind, never an error tuple" do
      machine = compile!(@guarded)

      fixtures =
        fixtures!(
          expressions: %{
            "unmatched" => %{
              "source" => "nonsense that matches nothing",
              "expect" => %{"nonexistent-dataset" => true}
            }
          }
        )

      findings = Lint.lint(fixtures, machine)

      assert is_list(findings)

      assert Enum.all?(findings, fn %{kind: kind} ->
               kind in [:unmatched_expression, :dangling_expect_dataset]
             end)
    end
  end
end
