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

  alias StatifierUI.DatamodelExplorer.Entry
  alias StatifierUI.DatamodelExplorer.Scope
  alias StatifierUI.Fixtures

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
end
