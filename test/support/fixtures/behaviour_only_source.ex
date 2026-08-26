defmodule StatifierUI.Test.Support.Fixtures.BehaviourOnlySource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` implemented by hand with `@behaviour`
  rather than `use`, declaring only the two original callbacks
  (`scenarios/0` and `example_events/0`). Exists to prove
  `@optional_callbacks datasets: 0` (`lib/statifier_ui/fixtures/source.ex`)
  is what it claims to be: without it, a module compiled this way would warn
  under `warnings_as_errors: true` for not implementing `datasets/0`, since
  `use` is the only path that injects a default.
  """

  @behaviour StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def scenarios, do: %{"handwritten" => %{"ok" => true}}

  @impl StatifierUI.Fixtures.Source
  def example_events, do: %{"handwritten.event" => nil}
end
