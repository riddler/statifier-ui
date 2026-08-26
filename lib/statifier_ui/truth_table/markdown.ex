defmodule StatifierUI.TruthTable.Markdown do
  @moduledoc """
  Renders a `StatifierUI.TruthTable.t()` as Markdown a host hands to
  `Kino.Markdown.new/1`.

  A pure function over the table, in the shape of
  `StatifierUI.EventLog.Markdown`: it names `Kino` only in this moduledoc and
  calls nothing under `Kino.*`, so the same string serves a Livebook cell, a
  generated docs page, or a test assertion.

  ## Structure

  An optional `# <title>`, the legend, the matrix, and - when any cell failed
  to evaluate - an error list naming each failure's expression, dataset, and
  reason. The matrix is a Markdown table: by default one row per dataset and
  one column per expression, which is the orientation the sui-t0a bead
  states; `orientation: :expressions_as_rows` transposes it to the
  orientation ADR-0006's prose uses. Both describe the same matrix, and
  neither is derived from the other by the reader, so the axis is an option
  rather than a decision made here.

  ## The three values stay three

  Every cell's text is a spelled-out word - `true`, `false`, `undefined` -
  and the emphasis around it is added on top, never in place of it. Undefined
  is italic and false is plain, so the two never look alike at a glance, but
  a reader who sees no styling at all (a plain-text diff, a terminal, a
  screen reader) still reads three distinct words. Symbol-only cells were
  rejected for exactly that reason: a glyph that fails to render is a cell
  that means whatever the reader assumes, and the assumption is always
  "false".
  """

  alias StatifierUI.TruthTable

  @typedoc "Which axis runs down the table's rows."
  @type orientation :: :datasets_as_rows | :expressions_as_rows

  @type opt ::
          {:title, String.t() | nil}
          | {:orientation, orientation()}
          | {:legend, boolean()}
          | {:sources, boolean()}

  @doc """
  Renders `table` as a Markdown string.

  Options:

    * `:title` - the `#` heading, or `nil` for none. Defaults to
      `"Truth table"`.
    * `:orientation` - `:datasets_as_rows` (the default) or
      `:expressions_as_rows`. See the moduledoc.
    * `:legend` - include the three-values legend under the heading. Defaults
      to `true`; a page rendering several tables wants it once, not each
      time.
    * `:sources` - list each expression's predicator source under the matrix.
      Defaults to `true`, because a column header is a name and the name is
      not the expression.
  """
  @spec render(TruthTable.t(), [opt()]) :: String.t()
  def render(%TruthTable{} = table, opts \\ []) do
    title = Keyword.get(opts, :title, "Truth table")
    orientation = Keyword.get(opts, :orientation, :datasets_as_rows)

    blocks =
      [title_block(title)] ++
        legend_block(Keyword.get(opts, :legend, true)) ++
        [matrix_block(table, orientation)] ++
        sources_block(table, Keyword.get(opts, :sources, true)) ++
        errors_block(table)

    blocks
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # -- Heading, legend ------------------------------------------------------

  @spec title_block(String.t() | nil) :: String.t()
  defp title_block(nil), do: ""
  defp title_block(title), do: "# #{title}"

  @spec legend_block(boolean()) :: [String.t()]
  defp legend_block(false), do: []

  defp legend_block(true) do
    [
      Enum.join(
        [
          "**true**, false, and _undefined_ are three separate results.",
          "_undefined_ means the expression's inputs were absent, not that it",
          "evaluated to false."
        ],
        " "
      )
    ]
  end

  # -- The matrix -----------------------------------------------------------

  @spec matrix_block(TruthTable.t(), orientation()) :: String.t()
  defp matrix_block(%TruthTable{expressions: [], datasets: _datasets}, _orientation) do
    "No expressions in this bundle."
  end

  defp matrix_block(%TruthTable{datasets: []}, _orientation) do
    "No datasets in this bundle."
  end

  defp matrix_block(%TruthTable{} = table, :datasets_as_rows) do
    headers = ["dataset" | Enum.map(table.expressions, & &1.name)]

    rows =
      Enum.map(table.datasets, fn dataset_name ->
        [dataset_name | Enum.map(TruthTable.column(table, dataset_name), &cell_text/1)]
      end)

    table_lines(headers, rows)
  end

  defp matrix_block(%TruthTable{} = table, :expressions_as_rows) do
    headers = ["expression" | table.datasets]

    rows =
      Enum.map(table.expressions, fn %{name: name} ->
        [name | Enum.map(TruthTable.row(table, name), &cell_text/1)]
      end)

    table_lines(headers, rows)
  end

  @spec table_lines([String.t()], [[String.t()]]) :: String.t()
  defp table_lines(headers, rows) do
    separator = Enum.map(headers, fn _header -> "---" end)

    ([headers, separator] ++ rows)
    |> Enum.map_join("\n", &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  # The emphasis is additive: strip every `*` and `_` and the cell still says
  # which of the three values it is.
  @spec cell_text(TruthTable.cell()) :: String.t()
  defp cell_text(%{verdict: :satisfied}), do: "**true**"
  defp cell_text(%{verdict: :unsatisfied}), do: "false"
  defp cell_text(%{verdict: :undefined}), do: "_undefined_"
  defp cell_text(%{verdict: :value, label: label}), do: "`#{label}`"
  defp cell_text(%{verdict: :error}), do: "**error**"
  defp cell_text(%{verdict: :missing_dataset}), do: "_no dataset_"

  # -- Sources and errors ---------------------------------------------------

  @spec sources_block(TruthTable.t(), boolean()) :: [String.t()]
  defp sources_block(_table, false), do: []
  defp sources_block(%TruthTable{expressions: []}, true), do: []

  defp sources_block(%TruthTable{expressions: expressions}, true) do
    lines = Enum.map(expressions, &source_line/1)
    ["Expressions:\n" <> Enum.join(lines, "\n")]
  end

  @spec source_line(TruthTable.expression()) :: String.t()
  defp source_line(%{name: name, source: nil}), do: "- **#{name}**: not in this bundle"
  defp source_line(%{name: name, source: source}), do: "- **#{name}**: `#{source}`"

  @spec errors_block(TruthTable.t()) :: [String.t()]
  defp errors_block(%TruthTable{} = table) do
    table
    |> TruthTable.cells()
    |> Enum.filter(&(&1.verdict == :error))
    |> case do
      [] -> []
      errors -> ["Errors:\n" <> Enum.map_join(errors, "\n", &error_line/1)]
    end
  end

  @spec error_line(TruthTable.cell()) :: String.t()
  defp error_line(%{expression: expression, dataset: dataset, error: error}) do
    "- **#{expression}** / **#{dataset}**: #{error_reason(error)}"
  end

  @spec error_reason(term()) :: String.t()
  defp error_reason(%{message: message}) when is_binary(message), do: message
  defp error_reason(error), do: inspect(error)
end
