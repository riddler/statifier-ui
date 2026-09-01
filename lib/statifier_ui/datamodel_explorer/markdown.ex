defmodule StatifierUI.DatamodelExplorer.Markdown do
  @moduledoc """
  Renders a `StatifierUI.DatamodelExplorer.t()` as Markdown a host hands to
  `Kino.Markdown.new/1`, per the `sui-t36.7` plan's Phase 4.

  `render/2` is a pure function over the pane - it names `Kino` only in this
  moduledoc and calls nothing under `Kino.*`. `sui-t36.8` owns wrapping the
  returned string in an actual `Kino.Markdown` widget.

  ## Structure

  A header line naming the mode and either the scenario (authoring) or the
  session and macrostep (live), the ADR-0012 line naming the projection
  profile and saying editing is off when the pane is projected
  (`DatamodelExplorer.edit_disabled_reason/1`), a drop warning when
  `truncated?`, then one
  section per tier **in the pane's tier order** - `entries/1` already
  produces its entries grouped contiguously by tier, so this module chunks
  on that grouping rather than re-deriving or re-sorting it (ADR-0011). Each
  section is a Markdown table of name, type label, and value; a `changed?`
  entry's name carries the `:changed_marker` suffix (default `"*"`), and
  each `Entry.children` element renders as its own row, qualified as
  `"parent.child"`. A diagnostics section renders last, only when the pane
  carries any.

  Values render with `inspect/1` rather than re-encoded to JSON: this is a
  debugging view of decoded Elixir terms, and `StatifierUI.Trace.Json` is
  for the wire.
  """

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.DatamodelExplorer.Entry
  alias StatifierUI.Fixtures
  alias StatifierUI.Shape

  @type opt ::
          {:tiers, [Entry.tier()]}
          | {:collapsible, boolean()}
          | {:changed_marker, String.t()}
          | {:max_keys, pos_integer()}
          | {:max_depth, pos_integer()}

  @doc """
  Renders `pane` as a Markdown string.

  Options:

    * `:tiers` - when given, only entries whose tier is in this list get a
      section; the other tiers' sections are omitted entirely rather than
      rendered empty.
    * `:collapsible` - wraps each tier section in `<details>`/`<summary>`
      when `true`. Defaults to `false` - a plain `### <tier>` heading.
    * `:changed_marker` - the suffix appended to a `changed?` entry's name.
      Defaults to `"*"`.
    * `:max_keys`, `:max_depth` - passed straight through to
      `StatifierUI.Shape.label/2` for every entry's type label, so a value's
      inferred shape can be rendered at a coarser grain than the entry was
      built with.
  """
  @spec render(DatamodelExplorer.t(), [opt()]) :: String.t()
  def render(%DatamodelExplorer{} = pane, opts \\ []) do
    changed_marker = Keyword.get(opts, :changed_marker, "*")
    collapsible? = Keyword.get(opts, :collapsible, false)
    shape_opts = Keyword.take(opts, [:max_keys, :max_depth])

    entries = filtered_entries(pane, Keyword.get(opts, :tiers))

    ([header_block(pane)] ++
       tier_blocks(entries, changed_marker, shape_opts, collapsible?) ++
       diagnostics_block(pane))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # -- Entry selection ------------------------------------------------------

  @spec filtered_entries(DatamodelExplorer.t(), [Entry.tier()] | nil) :: [Entry.t()]
  defp filtered_entries(pane, nil), do: DatamodelExplorer.entries(pane)

  defp filtered_entries(pane, tiers) do
    Enum.filter(DatamodelExplorer.entries(pane), &(&1.tier in tiers))
  end

  # -- Header and truncation warning ----------------------------------------

  @spec header_block(DatamodelExplorer.t()) :: String.t()
  defp header_block(%DatamodelExplorer{mode: :authoring} = pane) do
    lines = ["# Datamodel: authoring (scenario: #{pane.scenario || "(none)"})"]
    Enum.join(lines ++ truncation_lines(pane), "\n")
  end

  defp header_block(%DatamodelExplorer{mode: :live} = pane) do
    lines = [
      "# Datamodel: live (session: #{pane.session || "(no session)"}, " <>
        "macrostep: #{macrostep_text(pane.macrostep)})"
    ]

    Enum.join(lines ++ projection_lines(pane) ++ truncation_lines(pane), "\n")
  end

  # ADR-0012 asks that the profile name be surfaced where the mode is, so a
  # reader asking "why can't I see this" has something to quote, and that the
  # editing guard say why rather than going quiet (`sui-8hg`).
  @spec projection_lines(DatamodelExplorer.t()) :: [String.t()]
  defp projection_lines(pane) do
    case DatamodelExplorer.edit_disabled_reason(pane) do
      nil -> []
      reason -> [reason]
    end
  end

  @spec macrostep_text(non_neg_integer() | nil) :: String.t()
  defp macrostep_text(nil), do: "(none)"
  defp macrostep_text(macrostep), do: to_string(macrostep)

  @spec truncation_lines(DatamodelExplorer.t()) :: [String.t()]
  defp truncation_lines(%DatamodelExplorer{truncated?: true}) do
    ["Earliest entries dropped; this fold does not start at the session's beginning."]
  end

  defp truncation_lines(%DatamodelExplorer{truncated?: false}), do: []

  # -- Tier sections ---------------------------------------------------------

  @spec tier_blocks([Entry.t()], String.t(), keyword(), boolean()) :: [String.t()]
  defp tier_blocks(entries, changed_marker, shape_opts, collapsible?) do
    entries
    |> Enum.chunk_by(& &1.tier)
    |> Enum.map(&tier_block(&1, changed_marker, shape_opts, collapsible?))
  end

  @spec tier_block([Entry.t()], String.t(), keyword(), boolean()) :: String.t()
  defp tier_block([%Entry{tier: tier} | _] = entries, changed_marker, shape_opts, true) do
    body = tier_table_lines(entries, changed_marker, shape_opts)

    Enum.join(
      ["<details>", "<summary>#{tier}</summary>", ""] ++ body ++ ["</details>"],
      "\n"
    )
  end

  defp tier_block([%Entry{tier: tier} | _] = entries, changed_marker, shape_opts, false) do
    body = tier_table_lines(entries, changed_marker, shape_opts)
    Enum.join(["### #{tier}", ""] ++ body, "\n")
  end

  @spec tier_table_lines([Entry.t()], String.t(), keyword()) :: [String.t()]
  defp tier_table_lines(entries, changed_marker, shape_opts) do
    header = ["| name | type | value |", "| --- | --- | --- |"]
    header ++ Enum.flat_map(entries, &entry_rows(&1, nil, changed_marker, shape_opts))
  end

  @spec entry_rows(Entry.t(), String.t() | nil, String.t(), keyword()) :: [String.t()]
  defp entry_rows(%Entry{} = entry, prefix, changed_marker, shape_opts) do
    name = qualified_name(prefix, entry.name)
    marked_name = if entry.changed?, do: name <> changed_marker, else: name
    type_label = Shape.label(entry.shape, shape_opts)
    row = "| #{marked_name} | #{type_label} | #{value_cell(entry.value)} |"

    [row | Enum.flat_map(entry.children, &entry_rows(&1, name, changed_marker, shape_opts))]
  end

  # A redacted slot renders as an explicit affordance rather than as
  # `inspect(:redacted)`, and never as unbound (ADR-0012): a datamodel pane
  # that shows "undefined" for a withheld value tells the reader the chart is
  # broken.
  @spec value_cell(term()) :: String.t()
  defp value_cell(:redacted), do: "(redacted)"
  defp value_cell(value), do: inspect(value)

  @spec qualified_name(String.t() | nil, String.t()) :: String.t()
  defp qualified_name(nil, name), do: name
  defp qualified_name(prefix, name), do: "#{prefix}.#{name}"

  # -- Diagnostics -----------------------------------------------------------

  @spec diagnostics_block(DatamodelExplorer.t()) :: [String.t()]
  defp diagnostics_block(%DatamodelExplorer{diagnostics: []}), do: []

  defp diagnostics_block(%DatamodelExplorer{diagnostics: diagnostics}) do
    lines = ["### Diagnostics" | Enum.map(diagnostics, &diagnostic_line/1)]
    [Enum.join(lines, "\n")]
  end

  @spec diagnostic_line(Fixtures.diagnostic()) :: String.t()
  defp diagnostic_line(%{kind: kind, message: message}), do: "- #{kind}: #{message}"
end
