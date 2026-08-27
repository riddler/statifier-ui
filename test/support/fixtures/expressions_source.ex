defmodule StatifierUI.Test.Support.Fixtures.ExpressionsSource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` used by the sidecar-vs-behaviour
  convergence test. Describes the same bundle as
  `test/support/fixtures/expressions.fixtures.json`: two datasets and two
  expressions, written in Elixir terms instead of ADR-0005's JSON tagged
  encoding - `:undefined` and a real `Date` inside the `"expect"` map, per
  `test/support/fixtures/tagged_source.ex`'s convention for this pair.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def datasets do
    %{
      "variant-a-early" => %{"signup" => %{"steps_completed" => 1, "variant" => "A"}},
      "variant-b-complete" => %{"signup" => %{"steps_completed" => 4, "variant" => "B"}}
    }
  end

  @impl StatifierUI.Fixtures.Source
  def expressions do
    %{
      "is-complete-variant-b" => %{
        "source" => "signup.steps_completed >= 3 and signup.variant == 'B'",
        "expect" => %{
          "variant-a-early" => false,
          "variant-b-complete" => true
        }
      },
      "started-date" => %{
        "source" => "signup.started_at",
        "expect" => %{
          "variant-a-early" => :undefined,
          "variant-b-complete" => ~D[2026-01-15]
        }
      }
    }
  end
end
