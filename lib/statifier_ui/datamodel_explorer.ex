defmodule StatifierUI.DatamodelExplorer do
  @moduledoc """
  The datamodel explorer pane (`sui-t36.7`): one component, two data
  sources. **Authoring mode** (`build_authoring/3`) merges the mode-
  independent tiers `StatifierUI.DatamodelExplorer.Scope` builds - document
  `<data id>` declarations (tier 1), the SCXML 5.10.1 system variables
  (tier 2a), the predicator provider functions in scope (tier 2b) - with
  one named fixture scenario (tier 3), the one tier that switches source
  between modes (ADR-0003:82-88). **Live mode**'s `build_live/2` is
  `sui-t36.7` Phase 3's addition to this same module.

  This pane is a **projection, not an editor**. There is no write path in
  either mode: authoring-mode tier-1 entries hold their declared source
  text for display but are never evaluated (predicator is non-evaluative,
  ADR-0004 upstream, adopted by ADR-0002), and live datamodel editing waits
  for a recordable-channel design (statifier ADR-0029). `sui-t36.8` owns
  the widget and the write affordance never arrives here.
  """

  alias Statifier.Evaluator.Functions
  alias StatifierUI.DatamodelExplorer.Entry
  alias StatifierUI.DatamodelExplorer.Scope
  alias StatifierUI.Fixtures
  alias StatifierUI.Trace.Message
  alias StatifierUI.Value

  @typedoc "Which data source fed this pane: the merged fixture scope, or a live session."
  @type mode :: :authoring | :live

  @type t :: %__MODULE__{
          mode: mode(),
          session: String.t() | nil,
          entries: [Entry.t()],
          scenario: String.t() | nil,
          scenario_names: [String.t()],
          macrostep: non_neg_integer() | nil,
          truncated?: boolean(),
          diagnostics: [Fixtures.diagnostic()]
        }

  defstruct mode: :authoring,
            session: nil,
            entries: [],
            scenario: nil,
            scenario_names: [],
            macrostep: nil,
            truncated?: false,
            diagnostics: []

  @typedoc "Options shared by both constructors; `Scope.opt()` is forwarded as-is."
  @type opt :: Scope.opt() | {:scenario, String.t()}

  # Live mode has no session to ask `SystemVariables.initial/2` for these -
  # the four names are spec 5.10's fixed set, unchanged by any machine, so
  # the name list is hardcoded rather than fabricating a placeholder
  # `%Statifier.Machine{}` just to call the function.
  @system_variable_names MapSet.new(~w(_sessionid _name _event _ioprocessors))

  # Tier 1 (`:data`, `:runtime`), tier 2a (`:system`), tier 2b (`:function`) -
  # live mode carries no tier 3, since a fixture scenario is an authoring-only
  # concept.
  @live_tier_order [:data, :runtime, :system, :function]

  @doc """
  Builds an authoring-mode pane from a compiled `machine` and an optional
  fixture bundle.

  1. Builds the mode-independent tiers with `Scope.build/2`, propagating
     its error.
  2. Selects a scenario: the `:scenario` option when given, else the first
     of `Fixtures.scenario_names/1` (sorted), else `nil` when `fixtures` is
     `nil` or holds no scenarios. A named `:scenario` the bundle does not
     hold is `{:error, {:unknown_scenario, name}}` - a typo in a host's
     switcher should say so rather than silently show the first scenario.
  3. Merges the selected scenario's datamodel onto the scope: a scenario
     value naming an existing tier-1 entry replaces that entry's `value`,
     `shape` and `label` and leaves its `tier` `:data` and its `d_index`
     intact; a scenario value naming nothing declared becomes a new
     `tier: :scenario` entry. Scenario values are already decoded Elixir
     terms (the sidecar decodes at load, `sidecar.ex:171-179`), so this
     path never calls `StatifierUI.Value.decode/1` - doing so would
     re-interpret an already-decoded `Date` as a `$`-tagged map.

  `entries/1` on the result concatenates `:data`, `:system`, `:function`,
  then `:scenario`, each group in the order its builder produced. Bundle
  diagnostics are carried onto the pane ahead of the scope's own, so a
  sidecar that already had complaints does not lose them here.
  `macrostep` is `nil`, `truncated?` is `false`, and `session` is `nil` -
  none of those are meaningful outside live mode.
  """
  @spec build_authoring(Statifier.Machine.t(), Fixtures.t() | nil, [opt()]) ::
          {:ok, t()} | {:error, term()}
  def build_authoring(machine, fixtures \\ nil, opts \\ []) do
    scope_opts = Keyword.take(opts, [:source, :session_id])

    with {:ok, scope} <- Scope.build(machine, scope_opts),
         {:ok, scenario_name, scenario_values} <- select_scenario(fixtures, opts) do
      entries = merge_scenario(scope, scenario_values)

      {:ok,
       %__MODULE__{
         mode: :authoring,
         entries: entries,
         scenario: scenario_name,
         scenario_names: scenario_names(fixtures),
         diagnostics: bundle_diagnostics(fixtures) ++ scope.diagnostics
       }}
    end
  end

  @doc """
  Builds a live-mode pane from `messages`, a session's captured effect
  stream (in any order - this is a pure fold, not a subscription).

  1. Refuses a `messages` list naming more than one session, the same
     `EventLog.build/1` rule and error shape
     (`docs/wire-format.md:96-102`). An empty list returns an empty `:live`
     pane with `session: nil`.
  2. `truncated?` is `true` when the lowest `seq` present is greater than
     `0` - the head of the stream was dropped, the `EventLog` precedent.
  3. Seeds the name set from `session.datamodel`'s `datamodel` payload map,
     decoding each value with `StatifierUI.Value.decode/1` **before**
     inferring its shape - the whole point, since every `<data>` element
     reads `{"$undefined": true}` there. A decode failure yields an entry
     holding `:undefined` plus one `:undecodable_datamodel_value`
     diagnostic, never a failed build.
  4. Classifies each seeded name against `session.start`'s `data` table
     (`:data`, carrying that element's `d_index`) and the fixed system
     variable names spec 5.10 declares (`:system`); anything else is
     `:runtime`.
  5. Applies every `effect.datamodel_change` in the producer's stamped
     `{macrostep, microstep, seq}` order (ADR-0011: never re-sorted by
     `location_path`, by `d_index`, or by name). `new_value`/`prior_value`
     absence reads as `:undefined`, matching `normalizer.ex:558-565`'s rule
     on the consumer side. `location_path`'s head names the root entry (a
     name the snapshot never carried is added as `tier: :runtime`); the
     remaining segments are applied into the root's decoded value,
     materializing a map for a string segment and a list for an integer
     segment when the container is missing or `:undefined`. A non-binary
     path head, an out-of-range index, or a segment that contradicts an
     existing container becomes an `:unresolvable_location_path` diagnostic
     and the write is skipped rather than crashing. `location_source` is
     kept from the most recent write applied to that entry.
  6. `macrostep` on the pane is the highest macrostep any *applied* write
     carried (`nil` when none did). An entry is `changed?: true` when at
     least one write stamped at that macrostep carried a decoded
     `prior_value` different from its decoded `new_value` - so a first
     binding, which has no `prior_value` at all, counts as a change from
     `:undefined`. This is macrostep granularity, not round: every
     `effect.*` type but `effect.budget_exhausted` carries a `nil` `round`
     (`normalizer.ex:271`), so finer marking would need an upstream wire
     change.
  7. `shape` and `label` are computed once, from each entry's final decoded
     value, so an entry written more than once in one macrostep is
     labelled from its end state.

  Tier 2b (provider functions) is appended unchanged from the same source
  `Scope` reads - `Statifier.Evaluator.Functions.base_context().functions` -
  since it is a compile-time constant that needs no session; both modes
  therefore show the same function list. `entries/1` on the result returns
  `:data`/`:runtime`, then `:system`, then `:function`, each group sorted
  by name; there is no tier 3 in live mode.
  """
  @spec build_live([Message.t()], [opt()]) ::
          {:ok, t()} | {:error, {:mixed_sessions, [String.t()]}}
  def build_live(messages, opts \\ [])

  def build_live([], _opts), do: {:ok, %__MODULE__{mode: :live}}

  def build_live(messages, _opts) do
    with {:ok, session} <- resolve_live_session(messages) do
      data_table = data_table(messages)
      {seeded, seed_diagnostics} = seed_live_entries(messages, data_table)

      fold =
        messages
        |> live_writes()
        |> Enum.reduce(%{entries: seeded, diagnostics: [], writes: []}, &apply_datamodel_write/2)

      macrostep = highest_macrostep(fold.writes)
      changed = changed_names(fold.writes, macrostep)

      entries =
        fold.entries
        |> finalize_live_entries(changed)
        |> Kernel.++(function_entries())
        |> order_live_entries()

      {:ok,
       %__MODULE__{
         mode: :live,
         session: session,
         entries: entries,
         macrostep: macrostep,
         truncated?: live_truncated?(messages),
         diagnostics: seed_diagnostics ++ Enum.reverse(fold.diagnostics)
       }}
    end
  end

  @doc """
  This pane's entries, in tier order (`:data`, `:system`, `:function`,
  `:scenario` in authoring mode).
  """
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc """
  This pane's entries belonging to one `tier`, in the same relative order
  `entries/1` returns them.
  """
  @spec entries(t(), Entry.tier()) :: [Entry.t()]
  def entries(%__MODULE__{entries: entries}, tier), do: Enum.filter(entries, &(&1.tier == tier))

  @doc """
  This pane's diagnostics, bundle diagnostics ahead of any the pane's own
  build produced.
  """
  @spec diagnostics(t()) :: [Fixtures.diagnostic()]
  def diagnostics(%__MODULE__{diagnostics: diagnostics}), do: diagnostics

  # -- Scenario selection --------------------------------------------------

  @spec select_scenario(Fixtures.t() | nil, [opt()]) ::
          {:ok, String.t() | nil, Fixtures.datamodel()} | {:error, {:unknown_scenario, term()}}
  defp select_scenario(fixtures, opts) do
    case Keyword.fetch(opts, :scenario) do
      {:ok, name} ->
        fetch_named_scenario(fixtures, name)

      :error ->
        {name, datamodel} = fixtures |> default_scenario() |> fetch_default_scenario(fixtures)
        {:ok, name, datamodel}
    end
  end

  @spec fetch_named_scenario(Fixtures.t() | nil, String.t()) ::
          {:ok, String.t(), Fixtures.datamodel()} | {:error, {:unknown_scenario, String.t()}}
  defp fetch_named_scenario(fixtures, name) do
    case fixtures && Fixtures.scenario(fixtures, name) do
      {:ok, datamodel} -> {:ok, name, datamodel}
      _not_found -> {:error, {:unknown_scenario, name}}
    end
  end

  @spec default_scenario(Fixtures.t() | nil) :: String.t() | nil
  defp default_scenario(nil), do: nil

  defp default_scenario(%Fixtures{} = fixtures) do
    case Fixtures.scenario_names(fixtures) do
      [] -> nil
      [first | _rest] -> first
    end
  end

  @spec fetch_default_scenario(String.t() | nil, Fixtures.t() | nil) ::
          {String.t() | nil, Fixtures.datamodel()}
  defp fetch_default_scenario(nil, _fixtures), do: {nil, %{}}

  defp fetch_default_scenario(name, fixtures) do
    {:ok, datamodel} = Fixtures.scenario(fixtures, name)
    {name, datamodel}
  end

  @spec scenario_names(Fixtures.t() | nil) :: [String.t()]
  defp scenario_names(nil), do: []
  defp scenario_names(%Fixtures{} = fixtures), do: Fixtures.scenario_names(fixtures)

  @spec bundle_diagnostics(Fixtures.t() | nil) :: [Fixtures.diagnostic()]
  defp bundle_diagnostics(nil), do: []
  defp bundle_diagnostics(%Fixtures{diagnostics: diagnostics}), do: diagnostics

  # -- Merging the scenario onto the scope ---------------------------------

  @spec merge_scenario(Scope.t(), Fixtures.datamodel()) :: [Entry.t()]
  defp merge_scenario(%Scope{} = scope, scenario_values) do
    names = MapSet.new(scope.data, & &1.name)

    data_entries = Enum.map(scope.data, &apply_scenario_value(&1, scenario_values))

    scenario_entries =
      scenario_values
      |> Enum.reject(fn {name, _value} -> MapSet.member?(names, name) end)
      |> Enum.sort_by(fn {name, _value} -> name end)
      |> Enum.map(&scenario_entry/1)

    data_entries ++ scope.system ++ scope.functions ++ scenario_entries
  end

  @spec apply_scenario_value(Entry.t(), Fixtures.datamodel()) :: Entry.t()
  defp apply_scenario_value(%Entry{name: name} = entry, scenario_values) do
    case Map.fetch(scenario_values, name) do
      {:ok, value} ->
        shape = StatifierUI.Shape.infer(value)
        %{entry | value: value, shape: shape, label: StatifierUI.Shape.label(shape)}

      :error ->
        entry
    end
  end

  @spec scenario_entry({String.t(), term()}) :: Entry.t()
  defp scenario_entry({name, value}) do
    shape = StatifierUI.Shape.infer(value)

    %Entry{
      name: name,
      tier: :scenario,
      value: value,
      shape: shape,
      label: StatifierUI.Shape.label(shape)
    }
  end

  # -- Live mode: session resolution and truncation ------------------------

  @spec resolve_live_session([Message.t()]) ::
          {:ok, String.t() | nil} | {:error, {:mixed_sessions, [String.t()]}}
  defp resolve_live_session(messages) do
    case messages |> Enum.map(& &1.session) |> Enum.uniq() |> Enum.sort() do
      [] -> {:ok, nil}
      [session] -> {:ok, session}
      ids -> {:error, {:mixed_sessions, ids}}
    end
  end

  @spec live_truncated?([Message.t()]) :: boolean()
  defp live_truncated?(messages) do
    messages
    |> Enum.map(& &1.seq)
    |> Enum.min()
    |> Kernel.>(0)
  end

  # -- Live mode: tier attribution from session.start's data table --------

  @spec data_table([Message.t()]) :: %{optional(String.t()) => non_neg_integer()}
  defp data_table(messages) do
    case Enum.find(messages, &(&1.type == "session.start")) do
      nil ->
        %{}

      %Message{payload: payload} ->
        payload
        |> Map.get("data", [])
        |> Map.new(fn %{"id" => id, "d_index" => d_index} -> {id, d_index} end)
    end
  end

  @spec classify_live_tier(String.t(), %{optional(String.t()) => non_neg_integer()}) ::
          Entry.tier()
  defp classify_live_tier(name, data_table) do
    cond do
      Map.has_key?(data_table, name) -> :data
      MapSet.member?(@system_variable_names, name) -> :system
      true -> :runtime
    end
  end

  # -- Live mode: seeding the name set from session.datamodel --------------

  @spec seed_live_entries([Message.t()], %{optional(String.t()) => non_neg_integer()}) ::
          {%{optional(String.t()) => map()}, [Fixtures.diagnostic()]}
  defp seed_live_entries(messages, data_table) do
    case Enum.find(messages, &(&1.type == "session.datamodel")) do
      nil ->
        {%{}, []}

      %Message{payload: payload} ->
        {entries, diagnostics} =
          payload
          |> Map.get("datamodel", %{})
          |> Enum.reduce({%{}, []}, &seed_live_entry(&1, &2, data_table))

        {entries, Enum.reverse(diagnostics)}
    end
  end

  @spec seed_live_entry(
          {String.t(), term()},
          {%{optional(String.t()) => map()}, [Fixtures.diagnostic()]},
          %{optional(String.t()) => non_neg_integer()}
        ) :: {%{optional(String.t()) => map()}, [Fixtures.diagnostic()]}
  defp seed_live_entry({name, raw}, {entries, diagnostics}, data_table) do
    case Value.decode(raw) do
      {:ok, value} ->
        {Map.put(entries, name, live_entry(name, value, data_table)), diagnostics}

      {:error, reason} ->
        entry = live_entry(name, :undefined, data_table)

        diagnostic =
          live_diagnostic(
            :undecodable_datamodel_value,
            "datamodel[#{inspect(name)}] could not be decoded: #{inspect(reason)}",
            ["datamodel", name]
          )

        {Map.put(entries, name, entry), [diagnostic | diagnostics]}
    end
  end

  @spec live_entry(String.t(), term(), %{optional(String.t()) => non_neg_integer()}) :: map()
  defp live_entry(name, value, data_table) do
    %{
      name: name,
      tier: classify_live_tier(name, data_table),
      value: value,
      d_index: Map.get(data_table, name),
      location_source: nil
    }
  end

  @spec runtime_entry(String.t()) :: map()
  defp runtime_entry(name) do
    %{name: name, tier: :runtime, value: :undefined, d_index: nil, location_source: nil}
  end

  # -- Live mode: applying effect.datamodel_change in stamped order --------

  @spec live_writes([Message.t()]) :: [Message.t()]
  defp live_writes(messages) do
    messages
    |> Enum.filter(&(&1.type == "effect.datamodel_change"))
    |> Enum.sort_by(&{&1.macrostep, &1.microstep, &1.seq})
  end

  @spec apply_datamodel_write(Message.t(), map()) :: map()
  defp apply_datamodel_write(%Message{payload: payload} = message, acc) do
    {new_value, acc} = decode_write_value(payload, "new_value", acc)
    {prior_value, acc} = decode_write_value(payload, "prior_value", acc)

    case payload["location_path"] do
      [root_name | segments] when is_binary(root_name) ->
        apply_resolved_write(acc, message, root_name, segments, new_value, prior_value)

      path ->
        diagnostic =
          live_diagnostic(
            :unresolvable_location_path,
            "location_path #{inspect(path)} has no binary root segment",
            stringify_path(List.wrap(path))
          )

        %{acc | diagnostics: [diagnostic | acc.diagnostics]}
    end
  end

  @spec decode_write_value(map(), String.t(), map()) :: {term(), map()}
  defp decode_write_value(payload, key, acc) do
    case Map.fetch(payload, key) do
      :error ->
        {:undefined, acc}

      {:ok, raw} ->
        case Value.decode(raw) do
          {:ok, value} ->
            {value, acc}

          {:error, reason} ->
            diagnostic =
              live_diagnostic(
                :undecodable_datamodel_value,
                "#{key} at #{inspect(payload["location_path"])} could not be decoded: " <>
                  inspect(reason),
                stringify_path(List.wrap(payload["location_path"])) ++ [key]
              )

            {:undefined, %{acc | diagnostics: [diagnostic | acc.diagnostics]}}
        end
    end
  end

  @spec apply_resolved_write(
          map(),
          Message.t(),
          String.t(),
          [String.t() | integer()],
          term(),
          term()
        ) :: map()
  defp apply_resolved_write(acc, message, root_name, segments, new_value, prior_value) do
    root_entry = Map.get(acc.entries, root_name, runtime_entry(root_name))

    case apply_path(root_entry.value, segments, new_value) do
      {:ok, updated_value} ->
        updated_entry = %{
          root_entry
          | value: updated_value,
            location_source: message.payload["location_source"]
        }

        write = %{
          name: root_name,
          macrostep: message.macrostep,
          prior: prior_value,
          new: new_value
        }

        %{
          acc
          | entries: Map.put(acc.entries, root_name, updated_entry),
            writes: [write | acc.writes]
        }

      {:error, reason} ->
        diagnostic =
          live_diagnostic(
            :unresolvable_location_path,
            "write to #{inspect([root_name | segments])} could not be applied: " <>
              inspect(reason),
            stringify_path([root_name | segments])
          )

        %{acc | diagnostics: [diagnostic | acc.diagnostics]}
    end
  end

  # Materializes intermediate containers along a resolved `location_path`:
  # a missing or `:undefined` container becomes a map for a string segment,
  # a list for an integer segment. An integer segment equal to the
  # container's current length appends; beyond it, or a segment kind that
  # contradicts an existing container, is `{:error, reason}` rather than a
  # crash.
  @spec apply_path(term(), [String.t() | integer()], term()) :: {:ok, term()} | {:error, term()}
  defp apply_path(_current, [], new_value), do: {:ok, new_value}

  defp apply_path(current, [key | rest], new_value) when is_binary(key) do
    with {:ok, map} <- as_map(current) do
      case apply_path(Map.get(map, key, :undefined), rest, new_value) do
        {:ok, updated} -> {:ok, Map.put(map, key, updated)}
        error -> error
      end
    end
  end

  defp apply_path(current, [index | rest], new_value) when is_integer(index) and index >= 0 do
    with {:ok, list} <- as_list(current) do
      apply_list_index(list, index, rest, new_value)
    end
  end

  defp apply_path(_current, [segment | _rest], _new_value) do
    {:error, {:invalid_segment, segment}}
  end

  @spec apply_list_index(list(), non_neg_integer(), [String.t() | integer()], term()) ::
          {:ok, list()} | {:error, term()}
  defp apply_list_index(list, index, rest, new_value) when index < length(list) do
    case apply_path(Enum.at(list, index), rest, new_value) do
      {:ok, updated} -> {:ok, List.replace_at(list, index, updated)}
      error -> error
    end
  end

  defp apply_list_index(list, index, rest, new_value) when index == length(list) do
    case apply_path(:undefined, rest, new_value) do
      {:ok, updated} -> {:ok, list ++ [updated]}
      error -> error
    end
  end

  defp apply_list_index(_list, index, _rest, _new_value) do
    {:error, {:index_out_of_bounds, index}}
  end

  @spec as_map(term()) :: {:ok, map()} | {:error, term()}
  defp as_map(:undefined), do: {:ok, %{}}
  defp as_map(map) when is_map(map), do: {:ok, map}
  defp as_map(other), do: {:error, {:not_a_map, other}}

  @spec as_list(term()) :: {:ok, list()} | {:error, term()}
  defp as_list(:undefined), do: {:ok, []}
  defp as_list(list) when is_list(list), do: {:ok, list}
  defp as_list(other), do: {:error, {:not_a_list, other}}

  # -- Live mode: marking changes at the pane's macrostep -------------------

  @spec highest_macrostep([map()]) :: non_neg_integer() | nil
  defp highest_macrostep(writes) do
    case writes |> Enum.map(& &1.macrostep) |> Enum.reject(&is_nil/1) do
      [] -> nil
      macrosteps -> Enum.max(macrosteps)
    end
  end

  @spec changed_names([map()], non_neg_integer() | nil) :: MapSet.t(String.t())
  defp changed_names(_writes, nil), do: MapSet.new()

  defp changed_names(writes, macrostep) do
    writes
    |> Enum.filter(&(&1.macrostep == macrostep and &1.prior != &1.new))
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  # -- Live mode: finishing entries and tier 2b --------------------------

  @spec finalize_live_entries(%{optional(String.t()) => map()}, MapSet.t(String.t())) :: [
          Entry.t()
        ]
  defp finalize_live_entries(entries_map, changed) do
    Enum.map(entries_map, fn {name, entry} ->
      shape = StatifierUI.Shape.infer(entry.value)

      %Entry{
        name: name,
        tier: entry.tier,
        value: entry.value,
        shape: shape,
        label: StatifierUI.Shape.label(shape),
        changed?: MapSet.member?(changed, name),
        d_index: entry.d_index,
        location_source: entry.location_source
      }
    end)
  end

  # Tier 2b, read from the same resolved context `Scope` reads - a
  # compile-time constant that needs no session, so both modes show the
  # same function list (`Scope`'s `build_functions/0`, duplicated here
  # rather than exposed publicly since it takes no machine-dependent
  # input).
  @spec function_entries() :: [Entry.t()]
  defp function_entries do
    Functions.base_context().functions
    |> Enum.sort_by(fn {name, _entry} -> name end)
    |> Enum.map(&live_function_entry/1)
  end

  @spec live_function_entry({String.t(), {non_neg_integer() | [non_neg_integer()], atom()}}) ::
          Entry.t()
  defp live_function_entry({name, {arity, _impl}}) do
    %Entry{
      name: name,
      tier: :function,
      value: :undefined,
      shape: :unknown,
      label: live_function_label(name, arity),
      arity: arity
    }
  end

  @spec live_function_label(String.t(), non_neg_integer() | [non_neg_integer()]) :: String.t()
  defp live_function_label(name, arity) when is_integer(arity), do: "#{name}/#{arity}"

  defp live_function_label(name, arities) when is_list(arities) do
    "#{name}/#{Enum.map_join(arities, "|", &to_string/1)}"
  end

  @spec order_live_entries([Entry.t()]) :: [Entry.t()]
  defp order_live_entries(entries) do
    Enum.flat_map(@live_tier_order, fn tier ->
      entries
      |> Enum.filter(&(&1.tier == tier))
      |> Enum.sort_by(& &1.name)
    end)
  end

  # -- Live mode: diagnostics -----------------------------------------------

  @spec live_diagnostic(atom(), String.t(), [String.t()]) :: Fixtures.diagnostic()
  defp live_diagnostic(kind, message, path) do
    %{kind: kind, message: message, path: path, source: nil}
  end

  @spec stringify_path([String.t() | integer()]) :: [String.t()]
  defp stringify_path(path), do: Enum.map(path, &to_string/1)
end
