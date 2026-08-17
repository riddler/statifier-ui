defmodule StatifierUI.Fixtures do
  @moduledoc """
  Example data a host supplies for a chart: named scenario datamodels and
  example event payloads (ADR-0003).

  A fixture bundle is two maps:

    * `scenarios` - a scenario name (for example `"gold-tier-user"`) mapped to
      a complete example of the host-supplied datamodel for that situation.
    * `events` - an event name (for example `"payment.success"`) mapped to a
      sample `_event.data` payload for that event.

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
  """

  alias StatifierUI.Shape

  @typedoc "The name of a fixture scenario."
  @type scenario_name :: String.t()

  @typedoc "The name of a fixture event, matching an SCXML event name."
  @type event_name :: String.t()

  @typedoc "An example datamodel: string keys at every level."
  @type datamodel :: %{optional(String.t()) => term()}

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
          diagnostics: [diagnostic()]
        }

  defstruct scenarios: %{}, events: %{}, diagnostics: []

  @doc """
  Builds a validated fixture bundle from `:scenarios` and `:events` options.

  Both options default to `%{}`. Returns `{:error, reason}` rather than
  raising when a scenario or event key is not a string, when a scenario
  datamodel is not a map, or when a scenario datamodel contains a non-string
  key at any depth. A non-string key found inside a datamodel is reported as
  `{:invalid_key, key, path}`, where `path` starts with the scenario name -
  or, when the offending map is a predicator duration, as
  `{:duration_in_scenario, path}`, which says why rather than naming a unit
  key the author never wrote.

  ## Examples

      iex> StatifierUI.Fixtures.new(scenarios: %{"gold-tier-user" => %{"tier" => "gold"}})
      {:ok, %StatifierUI.Fixtures{scenarios: %{"gold-tier-user" => %{"tier" => "gold"}}}}

  """
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []) do
    scenarios = Keyword.get(opts, :scenarios, %{})
    events = Keyword.get(opts, :events, %{})

    with :ok <- validate_scenarios(scenarios),
         :ok <- validate_events(events) do
      {:ok, %__MODULE__{scenarios: scenarios, events: events, diagnostics: []}}
    end
  end

  @doc """
  Builds a validated fixture bundle from a `StatifierUI.Fixtures.Source`
  module.

  Calls `module.scenarios()` and `module.example_events()` and routes both
  through `new/1`, so this path and the sidecar loader share exactly one
  validation implementation. Returns `{:error, {:not_a_source, module}}` when
  `module` does not implement the behaviour.
  """
  @spec from_source(module()) :: {:ok, t()} | {:error, term()}
  def from_source(module) do
    with :ok <- ensure_source(module) do
      new(scenarios: module.scenarios(), events: module.example_events())
    end
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
  defp validate_scenario_entry(name, datamodel), do: check_keys(datamodel, [name])

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
  @spec check_keys(term(), [term()]) :: :ok | {:error, term()}
  defp check_keys(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {element, index}, :ok ->
      case check_keys(element, [index | path]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp check_keys(%_struct{}, _path), do: :ok

  # A duration is reported as itself rather than as the first offending unit
  # key: the author wrote `$duration` (or an atom-keyed map), never `:seconds`,
  # so naming the unit describes the decoding rather than the mistake.
  defp check_keys(map, path) when is_map(map) do
    if Shape.duration?(map) do
      {:error, {:duration_in_scenario, Enum.reverse(path)}}
    else
      check_each_key(map, path)
    end
  end

  defp check_keys(_scalar, _path), do: :ok

  @spec check_each_key(map(), [term()]) :: :ok | {:error, term()}
  defp check_each_key(map, path) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      case check_key(key, value, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec check_key(term(), term(), [term()]) :: :ok | {:error, term()}
  defp check_key(key, _value, path) when not is_binary(key),
    do: {:error, {:invalid_key, key, Enum.reverse(path)}}

  defp check_key(key, value, path), do: check_keys(value, [key | path])
end
