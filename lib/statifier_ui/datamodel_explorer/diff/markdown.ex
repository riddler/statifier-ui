defmodule StatifierUI.DatamodelExplorer.Diff.Markdown do
  @moduledoc """
  Renders a `StatifierUI.DatamodelExplorer.Diff` change list as Markdown a
  host hands to `Kino.Markdown.new/1` (`sui-2uz`).

  Pure, like every other `*.Markdown` in this package: `Kino` is named in
  this moduledoc and nowhere else, so the same string serves a Livebook
  cell, a generated page, or a test assertion.
  `StatifierUI.Inspector.datamodel_diff/2` is the caller that pairs it with
  the fold.

  Values render with `inspect/1`, the same choice
  `StatifierUI.DatamodelExplorer.Markdown` makes and for the same reason:
  this is a debugging view of decoded Elixir terms, and
  `StatifierUI.Trace.Json` is for the wire. `Diff.absent/0` renders as a
  dash rather than as `:absent`, because "there was no such slot" is not a
  value the run ever held.

  An empty change list renders as a sentence saying so, never as an empty
  table. A step that changed nothing is a fact about the run worth stating -
  a blank pane reads as a broken one.
  """

  alias StatifierUI.DatamodelExplorer.Diff

  @type opt :: {:title, String.t() | nil} | {:empty_note, String.t()}

  @absent_cell "-"

  @doc """
  Renders `changes` as a Markdown table.

  Options:

    * `:title` - the heading above the table. Defaults to
      `"#### Datamodel changes"`; `nil` omits the heading entirely, for a
      host supplying its own.
    * `:empty_note` - the line rendered instead of the table when `changes`
      is empty. Defaults to `"_No datamodel slot changed._"`.

  ## Examples

      iex> changes = [
      ...>   %{name: "attempts", tier: :data, kind: :changed, from: 1, to: 2}
      ...> ]
      iex> StatifierUI.DatamodelExplorer.Diff.Markdown.render(changes, title: nil)
      "| slot | tier | change | before | after |\\n| --- | --- | --- | --- | --- |\\n| `attempts` | data | changed | `1` | `2` |"

      iex> StatifierUI.DatamodelExplorer.Diff.Markdown.render([], title: nil)
      "_No datamodel slot changed._"
  """
  @spec render([Diff.change()], [opt()]) :: String.t()
  def render(changes, opts \\ []) when is_list(changes) do
    title = Keyword.get(opts, :title, "#### Datamodel changes")

    body =
      case changes do
        [] -> Keyword.get(opts, :empty_note, "_No datamodel slot changed._")
        _any -> table(changes)
      end

    case title do
      nil -> body
      heading -> heading <> "\n\n" <> body
    end
  end

  @spec table([Diff.change()]) :: String.t()
  defp table(changes) do
    rows = Enum.map(changes, &row/1)

    Enum.join(
      [
        "| slot | tier | change | before | after |",
        "| --- | --- | --- | --- | --- |" | rows
      ],
      "\n"
    )
  end

  @spec row(Diff.change()) :: String.t()
  defp row(change) do
    "| `#{change.name}` | #{change.tier} | #{change.kind} | " <>
      "#{cell(change.from)} | #{cell(change.to)} |"
  end

  @spec cell(term()) :: String.t()
  defp cell(:absent), do: @absent_cell
  defp cell(value), do: "`#{inspect(value)}`"
end
