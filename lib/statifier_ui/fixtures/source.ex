defmodule StatifierUI.Fixtures.Source do
  @moduledoc """
  Behaviour for a host-application module that supplies fixture data.

  A host implements `scenarios/0` and `example_events/0`; `StatifierUI.Fixtures.from_source/1`
  calls both and routes the results through the same validation `new/1` applies
  to a JSON sidecar, so the two delivery paths in ADR-0003 converge on one
  struct. `datasets/0` and `expressions/0` are optional (ADR-0006): a host
  with no expressions to evaluate need not implement either.

  `use StatifierUI.Fixtures.Source` injects empty defaults for all four
  callbacks, so a host that only has scenarios (or only events, or only
  datasets, or only expressions) can implement just the one it has.
  """

  @typedoc "A named example datamodel, as `scenarios/0` returns it."
  @type scenarios :: %{optional(String.t()) => map()}

  @typedoc "A named example event payload, as `example_events/0` returns it."
  @type example_events :: %{optional(String.t()) => term()}

  @typedoc "A named example datamodel for evaluating expressions, as `datasets/0` returns it."
  @type datasets :: %{optional(String.t()) => map()}

  @typedoc "A named free-standing expression fixture, as `expressions/0` returns it."
  @type expressions :: %{optional(String.t()) => map()}

  @doc """
  Named example datamodels: a scenario name mapped to a complete example
  datamodel for that situation.
  """
  @callback scenarios() :: scenarios()

  @doc """
  Example event payloads: an event name mapped to a sample `_event.data`
  value.
  """
  @callback example_events() :: example_events()

  @doc """
  Named example datamodels for evaluating expressions against (ADR-0006): a
  dataset name mapped to a situation, which may be as small as an expression
  needs.
  """
  @callback datasets() :: datasets()

  @doc """
  Named free-standing expression fixtures (ADR-0006): an expression name
  mapped to a predicator `"source"` string and an optional `"expect"` map of
  expected results keyed by dataset name.
  """
  @callback expressions() :: expressions()

  @optional_callbacks datasets: 0, expressions: 0

  defmacro __using__(_opts) do
    quote do
      @behaviour StatifierUI.Fixtures.Source

      @impl StatifierUI.Fixtures.Source
      @spec scenarios() :: StatifierUI.Fixtures.Source.scenarios()
      def scenarios, do: %{}

      @impl StatifierUI.Fixtures.Source
      @spec example_events() :: StatifierUI.Fixtures.Source.example_events()
      def example_events, do: %{}

      @impl StatifierUI.Fixtures.Source
      @spec datasets() :: StatifierUI.Fixtures.Source.datasets()
      def datasets, do: %{}

      @impl StatifierUI.Fixtures.Source
      @spec expressions() :: StatifierUI.Fixtures.Source.expressions()
      def expressions, do: %{}

      defoverridable scenarios: 0, example_events: 0, datasets: 0, expressions: 0
    end
  end
end
