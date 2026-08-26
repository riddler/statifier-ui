defmodule StatifierUI.Fixtures.Bundle.Markdown do
  @moduledoc """
  Renders one `StatifierUI.Fixtures.Bundle` as the per-fragment "test this
  step" panel: what the fragment's expressions evaluate to under each of its
  datasets, and whether each expectation it states still holds.

  A pure function over the bundle, in the shape of
  `StatifierUI.TruthTable.Markdown` and `StatifierUI.EventLog.Markdown`: it
  names `Kino` only in this moduledoc and calls nothing under `Kino.*`, so
  the same string serves a Livebook cell, a generated docs page, or a test
  assertion. `StatifierUI.Kino.test_panel/2` is the widget wrapper.

  ## Two questions, both shown

  The panel is deliberately both halves of the fixture contract at once:

    * the **truth table** (`StatifierUI.TruthTable`) - what every expression
      actually evaluates to under every dataset, whether or not an
      expectation was stated. This is the reading surface.
    * the **expectations** (`StatifierUI.Fixtures.Expectations`) - whether
      every stated `expect` value held. This is the checking surface.

  A fragment's panel is useless with only one: the table without the
  expectations says what happens but not what was meant, and the expectations
  without the table say a stated belief held while staying silent about every
  expression that stated none.

  ## The summary counts rather than passes

  The expectations summary reports four counts - matched, mismatched,
  errored, and stated against a dataset the bundle does not carry - and never
  collapses them into a pass or a fail. That is not indecision: this
  package's two consumers of the same fact already disagree about it.
  `StatifierUI.Fixtures.Expectations.check/2` counts a `:missing_dataset` as
  a failure, because an expectation naming no dataset was never actually
  checked; `StatifierUI.Fixtures.Lint` reports the same dangling key as a
  warning, per ADR-0006's severity reasoning. Both are right about their own
  question, the reconciliation is not this renderer's to make, and a panel
  that printed one verdict would silently pick a side. Four counts let the
  reader see exactly which of the two situations they are in.

  ## Orientation is passed through, not chosen here

  `:orientation` is forwarded verbatim to
  `StatifierUI.TruthTable.Markdown.render/2`, whose own default stands. This
  renderer states no preference between the two axes.
  """

  alias StatifierUI.Fixtures.Bundle
  alias StatifierUI.Fixtures.Expectations
  alias StatifierUI.TruthTable

  @typedoc """
  Options. `:heading` is this panel's own `#` heading; the truth table below
  it is always rendered untitled, since the panel is already named. Every
  other option is forwarded to the layer that owns it.
  """
  @type opt ::
          {:heading, String.t() | nil}
          | {:origin, boolean()}
          | {:expectations, boolean()}
          | {:diagnostics, boolean()}
          | {:orientation, TruthTable.Markdown.orientation()}
          | {:legend, boolean()}
          | {:sources, boolean()}
          | {:functions, map()}
          | {:providers, keyword()}

  @build_opts [:expressions, :datasets, :functions, :providers]
  @render_opts [:orientation, :legend, :sources]

  @doc """
  Renders `bundle` as a Markdown string.

  Options:

    * `:heading` - the `#` heading. Defaults to the bundle's name; `nil` for
      none.
    * `:origin` - include a line naming the module or file the bundle came
      from. Defaults to `true`, because a panel that shows wrong examples is
      most often showing the wrong bundle.
    * `:expectations` - include the expectations section. Defaults to `true`.
    * `:diagnostics` - include the bundle's load diagnostics (an unknown
      sidecar key, a future version). Defaults to `true`.
    * `:orientation`, `:legend`, `:sources` - forwarded to
      `StatifierUI.TruthTable.Markdown.render/2`.
    * `:functions`, `:providers` - forwarded to `Predicator.evaluate/3`
      through both the table and the expectation run, so the panel's two
      halves evaluate under identical conditions.

  Never raises: an expression that fails to evaluate is a cell and a row,
  not an exception.
  """
  @spec render(Bundle.t(), [opt()]) :: String.t()
  def render(%Bundle{} = bundle, opts \\ []) do
    predicator_opts = Keyword.take(opts, [:functions, :providers])

    blocks =
      heading_block(bundle, Keyword.get(opts, :heading, bundle.name)) ++
        origin_block(bundle, Keyword.get(opts, :origin, true)) ++
        [table_block(bundle, opts)] ++
        expectations_block(bundle, predicator_opts, Keyword.get(opts, :expectations, true)) ++
        diagnostics_block(bundle, Keyword.get(opts, :diagnostics, true))

    blocks
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Renders every bundle in a `t:StatifierUI.Fixtures.Bundle.discovery/0`, one
  panel after another, followed by a section naming the entries that failed
  to load.

  Entries that ship no bundle are not listed. A palette where most fragments
  carry no examples is the normal case, and a page reciting them says nothing
  a reader can act on; a bundle that was *meant* to load and did not is the
  opposite, and is always named.

  `:legend` defaults to `false` here rather than `true`: the three-values
  legend is worth one appearance on a page, not one per fragment.
  """
  @spec render_discovery(Bundle.discovery(), [opt()]) :: String.t()
  def render_discovery(%{bundles: bundles, errors: errors}, opts \\ []) do
    panel_opts = Keyword.put_new(opts, :legend, false)

    panels = Enum.map(bundles, &render(&1, panel_opts))

    (panels ++ errors_block(errors))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # -- Heading and provenance -----------------------------------------------

  @spec heading_block(Bundle.t(), String.t() | nil) :: [String.t()]
  defp heading_block(_bundle, nil), do: []
  defp heading_block(_bundle, heading), do: ["# #{heading}"]

  @spec origin_block(Bundle.t(), boolean()) :: [String.t()]
  defp origin_block(_bundle, false), do: []
  defp origin_block(%Bundle{origin: origin}, true), do: ["From #{origin_text(origin)}."]

  @spec origin_text(Bundle.origin()) :: String.t()
  defp origin_text({:module, module}), do: "`#{inspect(module)}`"
  defp origin_text({:sidecar, path}), do: "`#{path}`"
  defp origin_text(:inline), do: "an inline bundle"

  # -- The truth table ------------------------------------------------------

  @spec table_block(Bundle.t(), keyword()) :: String.t()
  defp table_block(%Bundle{} = bundle, opts) do
    if Bundle.empty?(bundle) do
      "This fragment ships no datasets and no expressions."
    else
      render_opts =
        opts
        |> Keyword.take(@render_opts)
        |> Keyword.put(:title, nil)

      bundle.fixtures
      |> TruthTable.build(Keyword.take(opts, @build_opts))
      |> TruthTable.Markdown.render(render_opts)
    end
  end

  # -- Expectations ---------------------------------------------------------

  @spec expectations_block(Bundle.t(), keyword(), boolean()) :: [String.t()]
  defp expectations_block(_bundle, _predicator_opts, false), do: []

  defp expectations_block(%Bundle{fixtures: fixtures}, predicator_opts, true) do
    case Expectations.run(fixtures, predicator_opts) do
      [] -> ["Expectations: none stated."]
      results -> ["## Expectations\n\n" <> results_table(results) <> "\n\n" <> summary(results)]
    end
  end

  @spec results_table([Expectations.result()]) :: String.t()
  defp results_table(results) do
    headers = ["expression", "dataset", "expected", "actual", "result"]
    rows = Enum.map(results, &result_row/1)
    separator = Enum.map(headers, fn _header -> "---" end)

    ([headers, separator] ++ rows)
    |> Enum.map_join("\n", &("| " <> Enum.join(&1, " | ") <> " |"))
  end

  @spec result_row(Expectations.result()) :: [String.t()]
  defp result_row(%{status: :missing_dataset} = result) do
    [result.expression, result.dataset, term_text(result.expected), "-", status_text(result)]
  end

  defp result_row(result) do
    [
      result.expression,
      result.dataset,
      term_text(result.expected),
      term_text(result.actual),
      status_text(result)
    ]
  end

  # Spelled-out words with emphasis added on top, for the same reason
  # `StatifierUI.TruthTable.Markdown` does it: a cell that loses its styling
  # must still say which of the four outcomes it is.
  @spec status_text(Expectations.result()) :: String.t()
  defp status_text(%{status: :match}), do: "matched"
  defp status_text(%{status: :mismatch}), do: "**mismatched**"
  defp status_text(%{status: :error, error: error}), do: "**errored** - #{error_reason(error)}"
  defp status_text(%{status: :missing_dataset}), do: "_no such dataset_"

  @spec summary([Expectations.result()]) :: String.t()
  defp summary(results) do
    counts = Enum.frequencies_by(results, & &1.status)

    parts = [
      "#{count(counts, :match)} matched",
      "#{count(counts, :mismatch)} mismatched",
      "#{count(counts, :error)} errored",
      "#{count(counts, :missing_dataset)} stated against a dataset this bundle does not carry"
    ]

    Enum.join(parts, ", ") <> "."
  end

  @spec count(map(), atom()) :: non_neg_integer()
  defp count(counts, status), do: Map.get(counts, status, 0)

  # -- Diagnostics and load errors ------------------------------------------

  @spec diagnostics_block(Bundle.t(), boolean()) :: [String.t()]
  defp diagnostics_block(_bundle, false), do: []
  defp diagnostics_block(%Bundle{diagnostics: []}, true), do: []

  defp diagnostics_block(%Bundle{diagnostics: diagnostics}, true) do
    lines = Enum.map_join(diagnostics, "\n", &"- #{&1.message}")
    ["Notes:\n" <> lines]
  end

  @spec errors_block([{Bundle.name(), term()}]) :: [String.t()]
  defp errors_block([]), do: []

  defp errors_block(errors) do
    lines =
      Enum.map_join(errors, "\n", fn {name, reason} -> "- **#{name}**: #{inspect(reason)}" end)

    ["## Bundles that failed to load\n\n" <> lines]
  end

  # -- Value rendering ------------------------------------------------------

  # Matches `StatifierUI.TruthTable`'s value labels: the audience is the
  # person reading the example, not the person holding the term in IEx.
  @spec term_text(term()) :: String.t()
  defp term_text(nil), do: "`null`"
  defp term_text(true), do: "**true**"
  defp term_text(false), do: "false"
  defp term_text(:undefined), do: "_undefined_"
  defp term_text(%Date{} = date), do: "`#{Date.to_iso8601(date)}`"
  defp term_text(%DateTime{} = datetime), do: "`#{DateTime.to_iso8601(datetime)}`"
  defp term_text(value) when is_binary(value), do: "`#{value}`"
  defp term_text(value), do: "`#{inspect(value)}`"

  @spec error_reason(term()) :: String.t()
  defp error_reason(%{message: message}) when is_binary(message), do: message
  defp error_reason(error), do: inspect(error)
end
