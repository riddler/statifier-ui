defmodule StatifierUI.DatamodelExplorer.Scope do
  @moduledoc """
  The three ADR-0003 tiers that do not switch source between authoring and
  live mode: document `<data id>` declarations (tier 1), the SCXML 5.10.1
  system variables (tier 2a), and the predicator provider functions in
  scope (tier 2b). All three come from a compiled `%Statifier.Machine{}`
  and two engine constants - no session, no fixtures, no wire messages.

  ## Tier 1 - `<data>` declarations

  Enumerated with `machine.data_elements |> Tuple.to_list()`, the idiom
  `StatifierUI.Trace.Manifest` already uses for the same field
  (`trace/manifest.ex:193-201`), in `d_index` order - never re-sorted by
  id (ADR-0011's rule applied to an engine-ordered sequence). A tier-1
  entry has no runtime value here: predicator is non-evaluative
  (ADR-0004 upstream, adopted by ADR-0002), so `value` is always
  `:undefined` and `declared_source` carries the declared expression
  *text*, sliced from the `:source` option, only when one was given and
  `value_location` differs from `location`
  (`docs/wire-format.md:420-432`'s guard: when the two are equal there is
  no value span and the slice would be the whole element).

  ## Tier 2a - system variables

  `Statifier.Evaluator.SystemVariables.initial/2` is the single source of
  the name list: exactly `_sessionid`, `_name`, `_event`, `_ioprocessors`.
  **`_x` is deliberately absent** - the evaluator seeds it nowhere
  (`deps/statifier/lib/statifier/evaluator.ex:359-361`) - and `In(stateId)`
  is a tier-2b *function*, not a tier-2a datamodel key, even though both
  are things a reader of spec 5.10/5.9.1 will look for here. `_event`
  additionally gets `children`: one entry per key of
  `SystemVariables.event/1`'s schema (spec 5.10.1's six fields plus
  `data`), so the key list cannot drift from the engine's own. The
  session id comes from the `:session_id` option, defaulting to the
  documented placeholder `"(authoring)"` - there is no session in
  authoring mode, and the placeholder says so honestly rather than
  hiding it.

  ## Tier 2b - provider functions

  Read from `Statifier.Evaluator.Functions.base_context().functions`, the
  fully *resolved* `%{name => {arity, {module, atom}}}` map, rather than a
  walk over `Predicator.FunctionProvider.builtin_providers/0`. The
  resolved context is the only source that reflects predicator's
  builtins-then-providers-then-`:functions` shadowing order
  (`deps/predicator/lib/predicator/context.ex:216-237`); a provider-module
  walk can report a shadowed function as live. ADR-0003's `functions/0`
  phrasing is satisfied transitively, since that callback is what the
  resolution already consumed. Provider metadata is name and arity only -
  no return type, no parameter names - so a function entry's `label` is
  `"name/arity"` (or `"name/2|3"` for the multi-arity form) and nothing
  richer; ADR-0003:110-116 names richer metadata as upstream `px-`/`st-`
  work, not something to synthesize here.

  ## Diagnostics, not failures

  A tier-1 element whose `value_location` offsets fall outside the given
  `:source` string yields an entry with `declared_source: nil` plus one
  `StatifierUI.Fixtures.diagnostic()` (`kind: :unsliceable_declared_source`)
  - one bad span takes down one label, not the pane, following
  `StatifierUI.EventInjection.Palette`'s precedent
  (`event_injection/palette.ex:97-126`).
  """

  alias Statifier.Evaluator.Functions
  alias Statifier.Evaluator.SystemVariables
  alias Statifier.Machine
  alias Statifier.Machine.Data
  alias Statifier.Parser.Location
  alias StatifierUI.DatamodelExplorer.Entry
  alias StatifierUI.Fixtures
  alias StatifierUI.Shape

  @type opt :: {:source, String.t() | nil} | {:session_id, String.t()}

  @type t :: %__MODULE__{
          data: [Entry.t()],
          system: [Entry.t()],
          functions: [Entry.t()],
          diagnostics: [Fixtures.diagnostic()]
        }

  defstruct data: [], system: [], functions: [], diagnostics: []

  @doc """
  Builds the mode-independent tiers from a compiled `machine`.

  `:source` (default `nil`) is the chart's raw SCXML text, used only to
  slice tier-1 declared-value spans for display; `:session_id` (default
  `"(authoring)"`) seeds tier 2a's `_sessionid` and `_ioprocessors`.
  Returns `{:error, {:invalid_machine, other}}` for anything that is not
  a `%Statifier.Machine{}`.
  """
  @spec build(Statifier.Machine.t(), [opt()]) :: {:ok, t()} | {:error, term()}
  def build(machine, opts \\ []) do
    case machine do
      %Machine{} ->
        source = Keyword.get(opts, :source)
        session_id = Keyword.get(opts, :session_id, "(authoring)")
        {data_entries, diagnostics} = build_data(machine, source)

        {:ok,
         %__MODULE__{
           data: data_entries,
           system: build_system(machine, session_id),
           functions: build_functions(),
           diagnostics: diagnostics
         }}

      other ->
        {:error, {:invalid_machine, other}}
    end
  end

  # -- Tier 1: <data> declarations ---------------------------------------

  defp build_data(%Machine{data_elements: data_elements}, source) do
    {entries, diagnostics} =
      data_elements
      |> Tuple.to_list()
      |> Enum.map_reduce([], fn element, diagnostics ->
        case build_data_entry(element, source) do
          {:ok, entry} -> {entry, diagnostics}
          {:ok, entry, diagnostic} -> {entry, [diagnostic | diagnostics]}
        end
      end)

    {entries, Enum.reverse(diagnostics)}
  end

  defp build_data_entry(%Data{} = element, source) do
    case declared_source(element, source) do
      {:ok, declared} -> {:ok, data_entry(element, declared)}
      :error -> {:ok, data_entry(element, nil), unsliceable_diagnostic(element)}
    end
  end

  defp data_entry(%Data{} = element, declared_source) do
    %Entry{
      name: element.id,
      tier: :data,
      value: :undefined,
      shape: :undefined,
      label: Shape.label(:undefined),
      d_index: element.d_index,
      declared_source: declared_source
    }
  end

  defp declared_source(_element, nil), do: {:ok, nil}

  defp declared_source(%Data{value_location: same, location: same}, _source), do: {:ok, nil}

  defp declared_source(%Data{value_location: value_location}, source) do
    if within_source?(value_location, source) do
      {:ok, Location.slice(value_location, source)}
    else
      :error
    end
  end

  defp within_source?(%Location{start_offset: start_offset, end_offset: end_offset}, source) do
    start_offset >= 0 and end_offset >= start_offset and end_offset <= byte_size(source)
  end

  defp unsliceable_diagnostic(%Data{id: id}) do
    %{
      kind: :unsliceable_declared_source,
      message:
        "data #{inspect(id)}'s declared-value span falls outside the given source; " <>
          "declared_source is nil for this entry",
      path: ["data", id],
      source: nil
    }
  end

  # -- Tier 2a: system variables ------------------------------------------

  defp build_system(%Machine{} = machine, session_id) do
    machine
    |> SystemVariables.initial(session_id)
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.map(&build_system_entry/1)
  end

  defp build_system_entry({"_event" = name, value}) do
    system_entry(name, value, children: build_event_children())
  end

  defp build_system_entry({name, value}) do
    system_entry(name, value, [])
  end

  defp system_entry(name, value, extra) do
    shape = Shape.infer(value)

    struct!(
      Entry,
      [name: name, tier: :system, value: value, shape: shape, label: Shape.label(shape)] ++ extra
    )
  end

  defp build_event_children do
    "(none)"
    |> Statifier.Event.external()
    |> SystemVariables.event()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn key ->
      %Entry{
        name: key,
        tier: :system,
        value: :undefined,
        shape: :undefined,
        label: Shape.label(:undefined)
      }
    end)
  end

  # -- Tier 2b: provider functions -----------------------------------------

  defp build_functions do
    Functions.base_context().functions
    |> Enum.sort_by(fn {name, _entry} -> name end)
    |> Enum.map(&build_function_entry/1)
  end

  defp build_function_entry({name, {arity, _impl}}) do
    %Entry{
      name: name,
      tier: :function,
      value: :undefined,
      shape: :unknown,
      label: function_label(name, arity),
      arity: arity
    }
  end

  defp function_label(name, arity) when is_integer(arity), do: "#{name}/#{arity}"

  defp function_label(name, arities) when is_list(arities) do
    "#{name}/#{Enum.map_join(arities, "|", &to_string/1)}"
  end
end
