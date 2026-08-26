defmodule StatifierUI.Fixtures.Expectations do
  @moduledoc """
  Runs every `expect` entry a fixture bundle states, evaluates it against its
  named dataset, and reports whether the stated value held (ADR-0006). This
  is the executable side of the fixture contract: `StatifierUI.Fixtures.Lint`
  answers "is this bundle well-formed", this module answers "did every stated
  expectation come true".

  A test helper, not a mix task - see the implementation plan for the
  reasoning. A host wires `check!/2` into one `ExUnit` test over its own
  bundle, and the host's suite goes red the moment a dataset or an
  expectation drifts from what its expressions actually evaluate to.

  Comparison canonicalizes both the stated `expect` value and the evaluated
  result through `StatifierUI.Value.encode/1` before comparing with `===`.
  This is not cosmetic: `Predicator.evaluate/3` returns a duration as a
  seven-key map (the unit predicator's parser never emits,
  `:milliseconds`, is simply absent), while a `$duration` `expect` value
  decodes through `StatifierUI.Value.decode/1` to all eight units filled in.
  A bare `==` would report a spurious mismatch on every duration-valued
  expectation; encoding both sides first canonicalizes them to the same
  eight-key shape. Comparing on the encoded form also keeps `1` and `1.0`
  distinct, which matters because JSON does.

  `expect` values live in predicator's closed value domain, and so does
  every value `Predicator.evaluate/3` produces, so a genuine encode failure
  on either side means something reached this module from outside that
  domain - reported as `{:unsupported_value, term}` rather than raised.

  `run/2` never raises and never returns an error tuple: an evaluation
  failure is data, exactly as `Predicator.evaluate/3` itself treats it
  (CLAUDE.md's errors-are-values rule).
  """

  alias StatifierUI.Fixtures
  alias StatifierUI.Value

  @typedoc """
  One expectation's outcome.

  `:match` and `:mismatch` are comparisons that happened; `:error` is an
  evaluation that returned `{:error, e}` (or a value on either side outside
  predicator's value domain); `:missing_dataset` is an `expect` key naming no
  dataset in the bundle - a fact about the bundle, not an evaluation, so it
  carries no `actual` or `error`.
  """
  @type result :: %{
          expression: String.t(),
          dataset: String.t(),
          source: String.t(),
          expected: term(),
          actual: term() | nil,
          status: :match | :mismatch | :error | :missing_dataset,
          error: struct() | {:unsupported_value, term()} | nil
        }

  @doc """
  Evaluates every `(expression, dataset)` pair with a stated `expect`, in
  sorted expression-then-dataset order so output is stable across runs.

  `opts` forwards only `:functions` and `:providers` to
  `Predicator.evaluate/3` - nothing else is a fixture-runner concern. Never
  raises, never returns `{:error, _}`: a failure is a `:error` result.
  """
  @spec run(Fixtures.t(), keyword()) :: [result()]
  def run(%Fixtures{} = fixtures, opts \\ []) do
    predicator_opts = Keyword.take(opts, [:functions, :providers])

    for expression_name <- Fixtures.expression_names(fixtures),
        {:ok, expression} = Fixtures.expression(fixtures, expression_name),
        source = Map.get(expression, "source"),
        expect = Map.get(expression, "expect", %{}),
        dataset_name <- Enum.sort(Map.keys(expect)) do
      expected = Map.fetch!(expect, dataset_name)
      evaluate(fixtures, expression_name, source, dataset_name, expected, predicator_opts)
    end
  end

  @spec evaluate(Fixtures.t(), String.t(), String.t(), String.t(), term(), keyword()) ::
          result()
  defp evaluate(fixtures, expression_name, source, dataset_name, expected, predicator_opts) do
    base = %{
      expression: expression_name,
      dataset: dataset_name,
      source: source,
      expected: expected,
      actual: nil,
      status: :error,
      error: nil
    }

    case Fixtures.dataset(fixtures, dataset_name) do
      :error ->
        %{base | status: :missing_dataset}

      {:ok, dataset} ->
        case Predicator.evaluate(source, dataset, predicator_opts) do
          {:ok, actual} -> compare(base, actual)
          {:error, error} -> %{base | status: :error, error: error}
        end
    end
  end

  @spec compare(result(), term()) :: result()
  defp compare(%{expected: expected} = base, actual) do
    with {:ok, encoded_expected} <- Value.encode(expected),
         {:ok, encoded_actual} <- Value.encode(actual) do
      if encoded_expected === encoded_actual do
        %{base | actual: actual, status: :match}
      else
        %{base | actual: actual, status: :mismatch}
      end
    else
      {:error, reason} -> %{base | actual: actual, status: :error, error: reason}
    end
  end

  @doc """
  Partitions `run/2`'s results: anything that is not `:match` is a failure,
  including `:missing_dataset`.

  This intentionally differs from `StatifierUI.Fixtures.Lint`, which reports
  a dangling `expect` key as a warning per ADR-0006. Lint asks whether the
  bundle is well-formed enough to author against; this asks whether every
  stated expectation was actually checked, and one naming no dataset never
  was.
  """
  @spec check(Fixtures.t(), keyword()) :: :ok | {:error, [result()]}
  def check(%Fixtures{} = fixtures, opts \\ []) do
    case Enum.reject(run(fixtures, opts), &(&1.status == :match)) do
      [] -> :ok
      failures -> {:error, failures}
    end
  end

  @doc """
  Like `check/2`, but raises `StatifierUI.Fixtures.ExpectationError` on any
  failure instead of returning one, with a message naming every failure's
  expression, dataset, expected value, actual value, and error.
  """
  @spec check!(Fixtures.t(), keyword()) :: :ok
  def check!(%Fixtures{} = fixtures, opts \\ []) do
    case check(fixtures, opts) do
      :ok -> :ok
      {:error, failures} -> raise StatifierUI.Fixtures.ExpectationError, failures
    end
  end
end
