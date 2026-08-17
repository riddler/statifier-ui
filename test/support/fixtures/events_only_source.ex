defmodule StatifierUI.Test.Support.Fixtures.EventsOnlySource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` that defines only `example_events/0`,
  exercising the `scenarios/0` default `use StatifierUI.Fixtures.Source`
  injects.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def example_events do
    %{"ping" => nil}
  end
end
