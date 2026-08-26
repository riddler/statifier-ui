defmodule StatifierUI.Fixtures.ExpectationError do
  @moduledoc """
  Raised by `StatifierUI.Fixtures.Expectations.check!/2` when one or more
  stated `expect` entries did not hold.

  A plain exception, not `ExUnit.AssertionError` - nothing under `lib/` may
  depend on `ExUnit` being loaded, the same optional-dependency discipline
  applied to `Kino` and `Phoenix.LiveView`. A host wires `check!/2` into its
  own `ExUnit` test and lets this exception's message do the reporting.
  """

  defexception [:message, :results]

  alias StatifierUI.Fixtures.Expectations

  @type t :: %__MODULE__{message: String.t(), results: [Expectations.result()]}

  @doc """
  Builds the exception from the failing `results` (as returned by
  `StatifierUI.Fixtures.Expectations.check/2`), formatting one line per
  failure naming its expression, dataset, expected value, actual value, and
  error.
  """
  @spec exception([Expectations.result()]) :: t()
  def exception(results) do
    %__MODULE__{message: format(results), results: results}
  end

  @spec format([Expectations.result()]) :: String.t()
  defp format(results) do
    lines = Enum.map(results, &format_result/1)

    Enum.join(
      ["#{length(results)} fixture expectation(s) failed:" | lines],
      "\n"
    )
  end

  @spec format_result(Expectations.result()) :: String.t()
  defp format_result(%{status: :missing_dataset} = result) do
    "  - #{result.expression} / #{result.dataset}: expect names no such dataset"
  end

  defp format_result(%{status: :error} = result) do
    "  - #{result.expression} / #{result.dataset}: expected #{inspect(result.expected)}, " <>
      "evaluation errored: #{inspect(result.error)}"
  end

  defp format_result(%{status: :mismatch} = result) do
    "  - #{result.expression} / #{result.dataset}: expected #{inspect(result.expected)}, " <>
      "got #{inspect(result.actual)}"
  end
end
