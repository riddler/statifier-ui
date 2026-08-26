defmodule StatifierUI.TruthTable do
  @moduledoc """
  Evaluates a fixture bundle's expressions across its datasets and returns the
  result matrix ADR-0006 named: "one expression evaluated across all datasets,
  rendered as a result matrix".

  This module is the matrix; `StatifierUI.TruthTable.Markdown` renders it.
  Nothing here touches `Kino`, `Phoenix`, or a chart - a truth table is a fact
  about expressions and datasets, so it is buildable from a bundle alone.

  ## Three values, never two

  A cell's `verdict` is one of `:satisfied`, `:unsatisfied`, `:undefined`,
  `:value`, `:error`, or `:missing_dataset`. The first three are deliberately
  **not** `true` / `false` / `:undefined`: predicator's undefined sentinel is a
  third truth value, and an atom-vs-boolean encoding is what lets
  `if cell.verdict do` quietly sort `:undefined` onto one side of a
  two-valued fence. Sparse records make undefined the common case, so
  collapsing it is exactly the misreading this table exists to prevent, and
  the type is shaped so the collapse cannot happen by accident.

  `:value` is a non-boolean result - predicator expressions are not required
  to be predicates, and `"user.signup_date"` is a perfectly good row. `:error`
  is an evaluation that returned `{:error, e}`; the error is carried as data
  (CLAUDE.md's errors-are-values rule) rather than raised or flattened into a
  false.

  ## Relationship to `StatifierUI.Fixtures.Expectations`

  Distinct questions over the same bundle. `Expectations` asks whether every
  *stated* `expect` value still holds, and is a test helper. This asks what
  every expression actually evaluates to under every dataset, whether or not
  an expectation was stated - the executable-documentation surface a reader
  scans. A bundle with no `expect` keys at all still has a full truth table.

  Because of that, this module reads no `expect` value and takes no position
  on `expect`-related severity.

  ## Building

      {:ok, fixtures} = StatifierUI.Fixtures.from_source(MyApp.Fixtures)
      table = StatifierUI.TruthTable.build(fixtures)

  `:expressions` and `:datasets` narrow either axis to a named subset, in the
  order given, for a table too wide to read whole. A name on either list that
  the bundle does not carry is kept on the axis rather than dropped: a
  silently missing column is a worse read than a column that says so, and its
  cells carry `:missing_dataset` (or, for an unknown expression, an
  `:unknown_expression` error) instead.
  """

  alias StatifierUI.Fixtures

  @typedoc """
  What one expression evaluated to under one dataset.

  See the moduledoc for why the boolean verdicts are atoms rather than
  `true` / `false`.
  """
  @type verdict :: :satisfied | :unsatisfied | :undefined | :value | :error | :missing_dataset

  @typedoc """
  One cell of the matrix.

  `value` is the term `Predicator.evaluate/3` returned, `nil` when nothing was
  evaluated. `label` is the human-readable rendering of the verdict, always a
  spelled-out word rather than a symbol, so a renderer can add emphasis
  without the text ever depending on it.
  """
  @type cell :: %{
          expression: Fixtures.expression_name(),
          dataset: Fixtures.dataset_name(),
          source: String.t() | nil,
          verdict: verdict(),
          value: term() | nil,
          label: String.t(),
          error: term() | nil
        }

  @typedoc "One row of the expression axis: its name and the source it evaluates."
  @type expression :: %{name: Fixtures.expression_name(), source: String.t() | nil}

  @type t :: %__MODULE__{
          expressions: [expression()],
          datasets: [Fixtures.dataset_name()],
          cells: %{optional({Fixtures.expression_name(), Fixtures.dataset_name()}) => cell()}
        }

  @enforce_keys [:expressions, :datasets, :cells]
  defstruct expressions: [], datasets: [], cells: %{}

  @type opt ::
          {:expressions, [Fixtures.expression_name()]}
          | {:datasets, [Fixtures.dataset_name()]}
          | {:functions, map()}
          | {:providers, keyword()}

  @doc """
  Builds the matrix for `fixtures`.

  Options:

    * `:expressions` - the expression axis, in order. Defaults to every
      expression the bundle carries, sorted.
    * `:datasets` - the dataset axis, in order. Defaults to every dataset the
      bundle carries, sorted.
    * `:functions`, `:providers` - forwarded verbatim to
      `Predicator.evaluate/3`; nothing else is a truth-table concern.

  Never raises: an evaluation failure is an `:error` cell.
  """
  @spec build(Fixtures.t(), [opt()]) :: t()
  def build(%Fixtures{} = fixtures, opts \\ []) do
    predicator_opts = Keyword.take(opts, [:functions, :providers])
    expression_names = Keyword.get(opts, :expressions, Fixtures.expression_names(fixtures))
    dataset_names = Keyword.get(opts, :datasets, Fixtures.dataset_names(fixtures))

    expressions = Enum.map(expression_names, &expression_row(fixtures, &1))

    cells =
      for %{name: expression_name, source: source} <- expressions,
          dataset_name <- dataset_names,
          into: %{} do
        cell = evaluate(fixtures, expression_name, source, dataset_name, predicator_opts)
        {{expression_name, dataset_name}, cell}
      end

    %__MODULE__{expressions: expressions, datasets: dataset_names, cells: cells}
  end

  @doc """
  Fetches the cell at `(expression_name, dataset_name)`.

  Returns `:error` when either name is off the table's axes - which is not the
  same as a cell whose verdict is `:missing_dataset`, where the name is on the
  axis and the bundle has no such dataset.
  """
  @spec cell(t(), Fixtures.expression_name(), Fixtures.dataset_name()) :: {:ok, cell()} | :error
  def cell(%__MODULE__{cells: cells}, expression_name, dataset_name) do
    Map.fetch(cells, {expression_name, dataset_name})
  end

  @doc """
  The cells of one expression's row, in dataset-axis order.
  """
  @spec row(t(), Fixtures.expression_name()) :: [cell()]
  def row(%__MODULE__{datasets: datasets} = table, expression_name) do
    Enum.map(datasets, fn dataset_name ->
      fetch_cell(table, expression_name, dataset_name)
    end)
  end

  @doc """
  The cells of one dataset's column, in expression-axis order.
  """
  @spec column(t(), Fixtures.dataset_name()) :: [cell()]
  def column(%__MODULE__{expressions: expressions} = table, dataset_name) do
    Enum.map(expressions, fn %{name: expression_name} ->
      fetch_cell(table, expression_name, dataset_name)
    end)
  end

  @doc """
  Every cell, in expression-then-dataset axis order.

  Stable across runs, because both axes are ordered lists rather than map
  keys.
  """
  @spec cells(t()) :: [cell()]
  def cells(%__MODULE__{expressions: expressions} = table) do
    Enum.flat_map(expressions, fn %{name: name} -> row(table, name) end)
  end

  @doc """
  The spelled-out label for a verdict.

  Public because a renderer other than the bundled Markdown one should reuse
  the same words rather than invent a second vocabulary for the same six
  states.
  """
  @spec label(verdict()) :: String.t()
  def label(:satisfied), do: "true"
  def label(:unsatisfied), do: "false"
  def label(:undefined), do: "undefined"
  def label(:value), do: "value"
  def label(:error), do: "error"
  def label(:missing_dataset), do: "no dataset"

  # -- Building one cell ----------------------------------------------------

  @spec expression_row(Fixtures.t(), Fixtures.expression_name()) :: expression()
  defp expression_row(fixtures, name) do
    case Fixtures.expression(fixtures, name) do
      {:ok, expression} -> %{name: name, source: Map.get(expression, "source")}
      :error -> %{name: name, source: nil}
    end
  end

  @spec evaluate(
          Fixtures.t(),
          Fixtures.expression_name(),
          String.t() | nil,
          Fixtures.dataset_name(),
          keyword()
        ) :: cell()
  defp evaluate(fixtures, expression_name, source, dataset_name, predicator_opts) do
    base = %{
      expression: expression_name,
      dataset: dataset_name,
      source: source,
      verdict: :error,
      value: nil,
      label: label(:error),
      error: nil
    }

    case {source, Fixtures.dataset(fixtures, dataset_name)} do
      {nil, _dataset} ->
        %{base | error: {:unknown_expression, expression_name}}

      {_source, :error} ->
        %{base | verdict: :missing_dataset, label: label(:missing_dataset)}

      {source, {:ok, dataset}} ->
        run(base, source, dataset, predicator_opts)
    end
  end

  @spec run(cell(), String.t(), Fixtures.datamodel(), keyword()) :: cell()
  defp run(base, source, dataset, predicator_opts) do
    case Predicator.evaluate(source, dataset, predicator_opts) do
      {:ok, value} -> resolve(base, value)
      {:error, error} -> %{base | error: error}
    end
  end

  # The three-valued split. `:undefined` is matched ahead of the boolean
  # clauses on purpose, and a non-boolean value never reaches either of them.
  @spec resolve(cell(), term()) :: cell()
  defp resolve(base, :undefined), do: verdict(base, :undefined, :undefined)
  defp resolve(base, true), do: verdict(base, :satisfied, true)
  defp resolve(base, false), do: verdict(base, :unsatisfied, false)

  defp resolve(base, value),
    do: %{base | verdict: :value, value: value, label: value_label(value)}

  @spec verdict(cell(), verdict(), term()) :: cell()
  defp verdict(base, verdict, value) do
    %{base | verdict: verdict, value: value, label: label(verdict)}
  end

  # Dates and datetimes get their ISO-8601 text rather than their sigil, since
  # the audience for a truth table is the person reading the example, not the
  # person holding the term in IEx. Everything else in predicator's value
  # domain inspects readably as it stands.
  @spec value_label(term()) :: String.t()
  defp value_label(%Date{} = date), do: Date.to_iso8601(date)
  defp value_label(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp value_label(value) when is_binary(value), do: value
  defp value_label(value), do: inspect(value)

  @spec fetch_cell(t(), Fixtures.expression_name(), Fixtures.dataset_name()) :: cell()
  defp fetch_cell(%__MODULE__{} = table, expression_name, dataset_name) do
    case cell(table, expression_name, dataset_name) do
      {:ok, cell} -> cell
      :error -> off_axis(expression_name, dataset_name)
    end
  end

  @spec off_axis(Fixtures.expression_name(), Fixtures.dataset_name()) :: cell()
  defp off_axis(expression_name, dataset_name) do
    %{
      expression: expression_name,
      dataset: dataset_name,
      source: nil,
      verdict: :error,
      value: nil,
      label: label(:error),
      error: {:off_axis, expression_name, dataset_name}
    }
  end
end
