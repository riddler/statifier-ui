defmodule StatifierUI.DatamodelExplorer.Diff do
  @moduledoc """
  What the datamodel gained, lost, or changed between two points in one run
  (`sui-2uz`) - the reading that makes stepping through a persisted trace
  worth doing, rather than watching a table of current values redraw.

  A pure comparison of two `t:StatifierUI.DatamodelExplorer.t/0` panes.
  Nothing here folds a stream, reads a message, or decides what a macrostep
  is: `StatifierUI.Inspector.datamodel_diff/2` cuts the stream at two
  adjacent points, builds a pane for each with
  `StatifierUI.DatamodelExplorer.build_live/2`, and hands both here. Both
  halves are therefore reads of what the engine already stamped, and a
  stream reconstructed by catch-up got there through statifier ADR-0034
  replay - which re-drives the core rather than rewinding anything
  (ADR-0002's inherited clause).

  ## What a slot is

  One comparable slot per entry, plus one per `Entry.children` element
  qualified as `"parent.child"` - the same flattening
  `StatifierUI.DatamodelExplorer.Markdown` renders rows with, so a slot
  named in a diff is a row a reader can find in the pane beside it.

  Only value-bearing tiers are compared: `:data` and `:runtime` (tier 1),
  `:scenario` (tier 3), and `:system` (tier 2a). **`:function` entries are
  excluded** - a tier 2b entry is a predicator provider function in scope,
  whose "value" is its own description, and a provider set that changed
  between two macrosteps of one run would be a fact about the host's
  configuration rather than about the run.

  ## Absence is `:absent`, not `nil`

  `nil` is a value the datamodel can genuinely hold (a JSON `null`), and
  `:undefined` is the one `StatifierUI.Value` decodes `$undefined` to, so
  neither can stand for "this slot did not exist". The `:absent` atom does.
  A decoded wire value is never a bare atom other than `nil`, `:undefined`,
  `:redacted`, `true`, or `false` (`StatifierUI.Value`), so `:absent`
  cannot collide with one.

  ## Ordering

  `:added` and `:changed` in the later pane's own entry order, then
  `:removed` in the earlier pane's - so the list reads down the table the
  reader is looking at, with anything that vanished gathered at the end.
  """

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.DatamodelExplorer.Entry

  @typedoc """
  How one slot differs: it appeared, it holds a different value, or it is
  gone.
  """
  @type kind :: :added | :changed | :removed

  @typedoc """
  One difference. `from` is `:absent` on an `:added` change and `to` is
  `:absent` on a `:removed` one; `tier` is the tier the slot has in
  whichever pane still holds it.
  """
  @type change :: %{
          name: String.t(),
          tier: Entry.tier(),
          kind: kind(),
          from: term(),
          to: term()
        }

  @absent :absent

  # Tier 2b is deliberately absent - see the moduledoc.
  @compared_tiers [:data, :runtime, :scenario, :system]

  @doc """
  The differences between `earlier` and `later`, oldest pane first.

  Values compare with `===`, not `==`: `1` and `1.0` are a change in a
  datamodel, and a diff that called them equal would hide an assignment
  that happened.

  ## Examples

      iex> alias StatifierUI.DatamodelExplorer
      iex> {:ok, earlier} = DatamodelExplorer.build_live([])
      iex> {:ok, later} = DatamodelExplorer.build_live([])
      iex> StatifierUI.DatamodelExplorer.Diff.between(earlier, later)
      []
  """
  @spec between(DatamodelExplorer.t(), DatamodelExplorer.t()) :: [change()]
  def between(%DatamodelExplorer{} = earlier, %DatamodelExplorer{} = later) do
    earlier_by_name = slots(earlier)
    later_list = slot_list(later)

    forward =
      Enum.flat_map(later_list, fn {name, tier, value} ->
        case Map.fetch(earlier_by_name, name) do
          :error -> [change(name, tier, :added, @absent, value)]
          {:ok, {_tier, ^value}} -> []
          {:ok, {_tier, was}} -> [change(name, tier, :changed, was, value)]
        end
      end)

    later_names = MapSet.new(later_list, fn {name, _tier, _value} -> name end)

    removed =
      earlier
      |> slot_list()
      |> Enum.reject(fn {name, _tier, _value} -> MapSet.member?(later_names, name) end)
      |> Enum.map(fn {name, tier, value} -> change(name, tier, :removed, value, @absent) end)

    forward ++ removed
  end

  @doc """
  The atom standing in for a slot that does not exist on one side.

  Exposed so a renderer or a host can pattern match on it without hardcoding
  the atom, and so the choice is documented in exactly one place.

  ## Examples

      iex> StatifierUI.DatamodelExplorer.Diff.absent()
      :absent
  """
  @spec absent() :: :absent
  def absent, do: @absent

  # A map for the lookups the forward pass makes, and the ordered list for
  # the removal pass - built from the same flattening so the two halves can
  # never disagree about what a slot is.
  @spec slots(DatamodelExplorer.t()) :: %{String.t() => {Entry.tier(), term()}}
  defp slots(pane) do
    pane
    |> slot_list()
    |> Map.new(fn {name, tier, value} -> {name, {tier, value}} end)
  end

  @spec slot_list(DatamodelExplorer.t()) :: [{String.t(), Entry.tier(), term()}]
  defp slot_list(pane) do
    pane
    |> DatamodelExplorer.entries()
    |> Enum.filter(&(&1.tier in @compared_tiers))
    |> Enum.flat_map(&entry_slots(&1, nil))
  end

  @spec entry_slots(Entry.t(), String.t() | nil) :: [{String.t(), Entry.tier(), term()}]
  defp entry_slots(%Entry{} = entry, prefix) do
    name = if prefix, do: "#{prefix}.#{entry.name}", else: entry.name

    [{name, entry.tier, entry.value} | Enum.flat_map(entry.children, &entry_slots(&1, name))]
  end

  @spec change(String.t(), Entry.tier(), kind(), term(), term()) :: change()
  defp change(name, tier, kind, from, to) do
    %{name: name, tier: tier, kind: kind, from: from, to: to}
  end
end
