defmodule StatifierUI.Test.Support.Fixtures.ExpressionsSource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` used by the sidecar-vs-behaviour
  convergence test. Describes the same bundle as
  `test/support/fixtures/expressions.fixtures.json`: two datasets for
  evaluating expressions against. A later phase adds the expression itself;
  for now this pair exists so the convergence comparison has a non-empty
  `datasets` map to compare rather than `%{} == %{}`.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def datasets do
    %{
      "minor" => %{"user" => %{"age" => 15, "country" => "US"}},
      "adult-us" => %{"user" => %{"age" => 30, "country" => "US"}}
    }
  end
end
