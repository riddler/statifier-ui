defmodule StatifierUI.Fixtures do
  @moduledoc """
  Example data a host supplies for a chart: named scenario datamodels, example
  event payloads, and named datasets for evaluating expressions (ADR-0003,
  ADR-0006).

  A fixture bundle is a set of maps:

    * `scenarios` - a scenario name (for example `"within-budget-account"`)
      mapped to a complete example of the host-supplied datamodel for that
      situation.
    * `events` - an event name (for example `"authorize.approved"`) mapped to
      a sample `_event.data` payload for that event.
    * `datasets` - a dataset name mapped to a situation for evaluating a
      free-standing expression against.

  A scenario and a dataset are not the same thing, even though both are
  string-keyed example data. A scenario is a complete example of the
  host-supplied datamodel for running a chart; it stands in for the whole
  state a chart would actually see. A dataset exists only to evaluate
  expressions and may be as small as the expression needs - a two-key map
  naming just the variables a single guard reads, with nothing else a real
  chart run would carry. ADR-0006 keeps datasets separate from scenarios
  rather than asking a scenario to double as both, so a dataset can stay
  minimal and a scenario can stay a faithful example.

  Two delivery paths converge on this one struct: a host module implementing
  `StatifierUI.Fixtures.Source` (`from_source/1`), and a JSON sidecar next to
  a chart (a later phase's loader). Every consumer downstream of either path
  is indifferent to which one produced the struct.

  `new/1` validates rather than raises: scenario datamodels must have string
  keys at every level, so a fixture that would blow up deep inside the engine
  is instead rejected at load time. Event payloads are preserved verbatim,
  including the three-way `:undefined` / `nil` / map distinction predicator's
  `_event.data` semantics require.

  Scenario validation is **deliberately stricter than the engine's**, not a
  mirror of it. `Statifier.MachineState.new/2` rejects only atom keys that
  are not booleans, so it accepts an integer or boolean key; this rejects
  every key that is not a string. The reason is convergence: a JSON object
  key is always a string, so a scenario a behaviour source could supply but
  a sidecar could never express would break the one-struct guarantee
  ADR-0003 rests on. Rejecting it in both paths keeps them interchangeable.

  A dataset is validated exactly as a scenario is - string keys at every
  depth, for the same convergence reason - so a predicator duration cannot
  appear inside a dataset either: it decodes to a bare atom-keyed map, and
  the same rule that rejects it inside a scenario
  (`test/support/fixtures/tagged_source.ex`) rejects it here.

  `expressions` is the fourth map: an expression name mapped to a
  free-standing predicator `"source"` string and an optional `"expect"` map
  of expected results, keyed by dataset name. Unlike a scenario or a dataset,
  an expression entry is not walked for string keys - it is validated only
  for the shape ADR-0006 fixes (a `"source"` string, an `"expect"` map with
  binary keys), because its `expect` *values* are predicator values in their
  own right and a duration is a legal one there, unlike inside a datamodel.
  An absent `"expect"` entry for a dataset name means no expectation is
  stated for that dataset - not that the expression is expected to be
  undefined against it - and `expect/3` returns `:error` for both that case
  and an unknown expression name, since neither is a bundle error.
  """

  alias StatifierUI.Shape

  @typedoc "The name of a fixture scenario."
  @type scenario_name :: String.t()

  @typedoc "The name of a fixture event, matching an SCXML event name."
  @type event_name :: String.t()

  @typedoc "An example datamodel: string keys at every level."
  @type datamodel :: %{optional(String.t()) => term()}

  @typedoc "The name of a fixture dataset."
  @type dataset_name :: String.t()

  @typedoc "The name of a fixture expression."
  @type expression_name :: String.t()

  @typedoc """
  A free-standing expression fixture: a predicator `"source"` string and an
  optional `"expect"` map keyed by dataset name (ADR-0006). Keys beyond those
  two are preserved verbatim.
  """
  @type expression :: %{required(String.t()) => term()}

  @typedoc """
  A diagnostic surfaced while loading a fixture bundle. `path` is the key
  path inside the bundle; `source` is the file it came from, or `nil` for a
  bundle that never was a file.
  """
  @type diagnostic :: %{
          kind: atom(),
          message: String.t(),
          path: [String.t()],
          source: Path.t() | nil
        }

  @type t :: %__MODULE__{
          scenarios: %{optional(scenario_name()) => datamodel()},
          events: %{optional(event_name()) => term()},
          datasets: %{optional(dataset_name()) => datamodel()},
          expressions: %{optional(expression_name()) => expression()},
          diagnostics: [diagnostic()]
        }

  defstruct scenarios: %{}, events: %{}, datasets: %{}, expressions: %{}, diagnostics: []

  @doc """
  Builds a validated fixture bundle from `:scenarios`, `:events`,
  `:datasets`, and `:expressions` options.

  All four options default to `%{}`. Returns `{:error, reason}` rather than
  raising when a scenario, event, or dataset key is not a string, when a
  scenario or dataset datamodel is not a map, or when one contains a
  non-string key at any depth. A non-string key found inside a datamodel is
  reported as `{:invalid_key, key, path}`, where `path` starts with the
  scenario or dataset name - or, when the offending map is a predicator
  duration, as `{:duration_in_scenario, path}` or `{:duration_in_dataset,
  path}`, which says why rather than naming a unit key the author never
  wrote.

  ## Examples

      iex> StatifierUI.Fixtures.new(scenarios: %{"within-budget-account" => %{"currency" => "USD"}})
      {:ok, %StatifierUI.Fixtures{scenarios: %{"within-budget-account" => %{"currency" => "USD"}}}}

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    scenarios = Keyword.get(opts, :scenarios, %{})
    events = Keyword.get(opts, :events, %{})
    datasets = Keyword.get(opts, :datasets, %{})
    expressions = Keyword.get(opts, :expressions, %{})

    with :ok <- validate_scenarios(scenarios),
         :ok <- validate_events(events),
         :ok <- validate_datasets(datasets),
         :ok <- validate_expressions(expressions) do
      {:ok,
       %__MODULE__{
         scenarios: scenarios,
         events: events,
         datasets: datasets,
         expressions: expressions,
         diagnostics: []
       }}
    end
  end

  @doc """
  Builds a validated fixture bundle from a `StatifierUI.Fixtures.Source`
  module.

  Calls `module.scenarios()` and `module.example_events()`, and - when the
  module implements the optional `datasets/0` and `expressions/0` callbacks -
  `module.datasets()` and `module.expressions()`, and routes all of them
  through `new/1`, so this path and the sidecar loader share exactly one
  validation implementation. Returns `{:error, {:not_a_source, module}}` when
  `module` does not implement the behaviour.
  """
  @spec from_source(module()) :: {:ok, t()} | {:error, term()}
  def from_source(module) do
    with :ok <- ensure_source(module) do
      new(
        scenarios: module.scenarios(),
        events: module.example_events(),
        datasets: optional_callback(module, :datasets),
        expressions: optional_callback(module, :expressions)
      )
    end
  end

  @spec optional_callback(module(), atom()) :: map()
  defp optional_callback(module, fun) do
    if function_exported?(module, fun, 0), do: apply(module, fun, []), else: %{}
  end

  @doc """
  Fetches a scenario's datamodel by name.
  """
  @spec scenario(t(), scenario_name()) :: {:ok, datamodel()} | :error
  def scenario(%__MODULE__{scenarios: scenarios}, name), do: Map.fetch(scenarios, name)

  @doc """
  Scenario names, sorted (ADR-0005's canonical-order rule).
  """
  @spec scenario_names(t()) :: [scenario_name()]
  def scenario_names(%__MODULE__{scenarios: scenarios}),
    do: scenarios |> Map.keys() |> Enum.sort()

  @doc """
  Fetches an event's sample payload by name. Returns `:error` when the event
  has no fixture, distinct from an event whose fixture value is `nil` or
  `:undefined`.
  """
  @spec event(t(), event_name()) :: {:ok, term()} | :error
  def event(%__MODULE__{events: events}, name), do: Map.fetch(events, name)

  @doc """
  Event names, sorted (ADR-0005's canonical-order rule).
  """
  @spec event_names(t()) :: [event_name()]
  def event_names(%__MODULE__{events: events}), do: events |> Map.keys() |> Enum.sort()

  @doc """
  Fetches a dataset by name.
  """
  @spec dataset(t(), dataset_name()) :: {:ok, datamodel()} | :error
  def dataset(%__MODULE__{datasets: datasets}, name), do: Map.fetch(datasets, name)

  @doc """
  Dataset names, sorted (ADR-0005's canonical-order rule).
  """
  @spec dataset_names(t()) :: [dataset_name()]
  def dataset_names(%__MODULE__{datasets: datasets}), do: datasets |> Map.keys() |> Enum.sort()

  @doc """
  Fetches an expression by name.
  """
  @spec expression(t(), expression_name()) :: {:ok, expression()} | :error
  def expression(%__MODULE__{expressions: expressions}, name), do: Map.fetch(expressions, name)

  @doc """
  Expression names, sorted (ADR-0005's canonical-order rule).
  """
  @spec expression_names(t()) :: [expression_name()]
  def expression_names(%__MODULE__{expressions: expressions}),
    do: expressions |> Map.keys() |> Enum.sort()

  @doc """
  Fetches the expected result stated for `expression_name` against
  `dataset_name`.

  Returns `:error` both when `expression_name` names no expression and when
  the expression exists but states no expectation for `dataset_name` - an
  absent `expect` key means no expectation is stated (ADR-0006), which is not
  an error condition, so the two cases are deliberately not distinguished.
  """
  @spec expect(t(), expression_name(), dataset_name()) :: {:ok, term()} | :error
  def expect(%__MODULE__{} = fixtures, expression_name, dataset_name) do
    with {:ok, expression} <- expression(fixtures, expression_name),
         {:ok, expect_map} <- Map.fetch(expression, "expect") do
      Map.fetch(expect_map, dataset_name)
    end
  end

  @spec ensure_source(module()) :: :ok | {:error, {:not_a_source, module()}}
  defp ensure_source(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :scenarios, 0) and
             function_exported?(module, :example_events, 0) do
          :ok
        else
          {:error, {:not_a_source, module}}
        end

      {:error, _reason} ->
        {:error, {:not_a_source, module}}
    end
  end

  @spec validate_scenarios(term()) :: :ok | {:error, term()}
  defp validate_scenarios(scenarios) when is_map(scenarios) do
    Enum.reduce_while(scenarios, :ok, fn {name, datamodel}, :ok ->
      case validate_scenario_entry(name, datamodel) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_scenarios(other), do: {:error, {:invalid_scenarios, other}}

  @spec validate_scenario_entry(term(), term()) :: :ok | {:error, term()}
  defp validate_scenario_entry(name, _datamodel) when not is_binary(name),
    do: {:error, {:invalid_scenario_name, name}}

  defp validate_scenario_entry(name, datamodel) when not is_map(datamodel),
    do: {:error, {:invalid_scenario, name}}

  # The path is seeded with the scenario name so a key error names the
  # scenario it came from; a bundle with several scenarios is otherwise
  # ambiguous about which one to go fix.
  defp validate_scenario_entry(name, datamodel), do: check_keys(datamodel, [name], :scenario)

  @spec validate_datasets(term()) :: :ok | {:error, term()}
  defp validate_datasets(datasets) when is_map(datasets) do
    Enum.reduce_while(datasets, :ok, fn {name, datamodel}, :ok ->
      case validate_dataset_entry(name, datamodel) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_datasets(other), do: {:error, {:invalid_datasets, other}}

  @spec validate_dataset_entry(term(), term()) :: :ok | {:error, term()}
  defp validate_dataset_entry(name, _datamodel) when not is_binary(name),
    do: {:error, {:invalid_dataset_name, name}}

  defp validate_dataset_entry(name, datamodel) when not is_map(datamodel),
    do: {:error, {:invalid_dataset, name}}

  # The path is seeded with the dataset name for the same reason as a
  # scenario's: a key error should name the dataset it came from.
  defp validate_dataset_entry(name, datamodel), do: check_keys(datamodel, [name], :dataset)

  # Unlike a scenario or dataset, an expression entry is not walked for
  # string keys at depth: its only structural requirements are the shape
  # ADR-0006 fixes (a "source" string, an optional "expect" map with binary
  # keys). "expect" values are predicator values in their own right - a
  # duration is a legal one there - so they are not key-walked either.
  @spec validate_expressions(term()) :: :ok | {:error, term()}
  defp validate_expressions(expressions) when is_map(expressions) do
    Enum.reduce_while(expressions, :ok, fn {name, entry}, :ok ->
      case validate_expression_entry(name, entry) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_expressions(other), do: {:error, {:invalid_expressions, other}}

  @spec validate_expression_entry(term(), term()) :: :ok | {:error, term()}
  defp validate_expression_entry(name, _entry) when not is_binary(name),
    do: {:error, {:invalid_expression_name, name}}

  defp validate_expression_entry(name, entry) when not is_map(entry),
    do: {:error, {:invalid_expression, name}}

  defp validate_expression_entry(name, entry) do
    with :ok <- validate_expression_source(name, entry),
         :ok <- validate_expression_expect(name, entry) do
      validate_expression_keys(name, entry)
    end
  end

  @spec validate_expression_source(String.t(), map()) :: :ok | {:error, term()}
  defp validate_expression_source(name, entry) do
    case Map.get(entry, "source") do
      source when is_binary(source) -> :ok
      _other -> {:error, {:invalid_expression_source, name}}
    end
  end

  @spec validate_expression_expect(String.t(), map()) :: :ok | {:error, term()}
  defp validate_expression_expect(name, entry) do
    case Map.fetch(entry, "expect") do
      :error -> :ok
      {:ok, expect} when is_map(expect) -> validate_expect_keys(name, expect)
      {:ok, _other} -> {:error, {:invalid_expect, name}}
    end
  end

  @spec validate_expect_keys(String.t(), map()) :: :ok | {:error, term()}
  defp validate_expect_keys(name, expect) do
    if Enum.all?(expect, fn {key, _value} -> is_binary(key) end) do
      :ok
    else
      {:error, {:invalid_expect, name}}
    end
  end

  @spec validate_expression_keys(String.t(), map()) :: :ok | {:error, term()}
  defp validate_expression_keys(name, entry) do
    Enum.reduce_while(entry, :ok, fn {key, _value}, :ok ->
      if is_binary(key) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_expression_key, name, key}}}
      end
    end)
  end

  @spec validate_events(term()) :: :ok | {:error, term()}
  defp validate_events(events) when is_map(events) do
    if Enum.all?(events, fn {name, _value} -> is_binary(name) end) do
      :ok
    else
      {:error, {:invalid_events, events}}
    end
  end

  defp validate_events(other), do: {:error, {:invalid_events, other}}

  # Shaped after Statifier.MachineState.check_keys!/2
  # (deps/statifier/lib/statifier/machine_state.ex:500-516) - descends maps
  # and lists, stops at structs - but stricter about what counts as an
  # offending key, for the convergence reason in this module's @moduledoc.
  #
  # `section` picks the duration-report atom (`:scenario` or `:dataset`) so a
  # single walk serves both callers without duplicating it; it is threaded
  # through every recursive call but never appears in the reported path.
  @spec check_keys(term(), [term()], :scenario | :dataset) :: :ok | {:error, term()}
  defp check_keys(list, path, section) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      case check_keys(element, [index | path], section) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_keys(%_struct{}, _path, _section), do: :ok

  # A duration is reported as itself rather than as the first offending unit
  # key: the author wrote `$duration` (or an atom-keyed map), never `:seconds`,
  # so naming the unit describes the decoding rather than the mistake.
  defp check_keys(map, path, section) when is_map(map) do
    if Shape.duration?(map) do
      {:error, {duration_error(section), Enum.reverse(path)}}
    else
      check_each_key(map, path, section)
    end
  end

  defp check_keys(_scalar, _path, _section), do: :ok

  @spec duration_error(:scenario | :dataset) :: :duration_in_scenario | :duration_in_dataset
  defp duration_error(:scenario), do: :duration_in_scenario
  defp duration_error(:dataset), do: :duration_in_dataset

  @spec check_each_key(map(), [term()], :scenario | :dataset) :: :ok | {:error, term()}
  defp check_each_key(map, path, section) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case check_key(key, value, path, section) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec check_key(term(), term(), [term()], :scenario | :dataset) :: :ok | {:error, term()}
  defp check_key(key, _value, path, _section) when not is_binary(key),
    do: {:error, {:invalid_key, key, Enum.reverse(path)}}

  defp check_key(key, value, path, section), do: check_keys(value, [key | path], section)
end
