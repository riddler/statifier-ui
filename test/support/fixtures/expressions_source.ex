defmodule StatifierUI.Test.Support.Fixtures.ExpressionsSource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` used by the sidecar-vs-behaviour
  convergence test. Describes the same bundle as
  `test/support/fixtures/expressions.fixtures.json`: two datasets and one
  expression, written in Elixir terms instead of ADR-0005's JSON tagged
  encoding - `:undefined` and a real `Date` inside the `"expect"` map, per
  `test/support/fixtures/tagged_source.ex`'s convention for this pair.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def datasets do
    %{
      "minor" => %{"user" => %{"age" => 15, "country" => "US"}},
      "adult-us" => %{"user" => %{"age" => 30, "country" => "US"}}
    }
  end

  @impl StatifierUI.Fixtures.Source
  def expressions do
    %{
      "is-adult-us" => %{
        "source" => "user.age >= 18 and user.country == 'US'",
        "expect" => %{
          "minor" => false,
          "adult-us" => true
        }
      },
      "signup-date" => %{
        "source" => "user.signup_date",
        "expect" => %{
          "minor" => :undefined,
          "adult-us" => ~D[2026-01-15]
        }
      }
    }
  end
end
