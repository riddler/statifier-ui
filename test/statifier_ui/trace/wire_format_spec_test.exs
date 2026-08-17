defmodule StatifierUI.Trace.WireFormatSpecTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Normalizer

  @wire_format_path Path.join([__DIR__, "..", "..", "..", "docs", "wire-format.md"])

  describe "docs/wire-format.md drift" do
    test "the type index table's type strings equal Normalizer.types/0" do
      documented =
        @wire_format_path
        |> File.read!()
        |> extract_type_index_types()

      code = MapSet.new(Normalizer.types())

      missing_from_docs = MapSet.difference(code, documented)
      missing_from_code = MapSet.difference(documented, code)

      assert MapSet.size(missing_from_docs) == 0,
             "Normalizer.types/0 emits types docs/wire-format.md does not document: #{inspect(missing_from_docs)}"

      assert MapSet.size(missing_from_code) == 0,
             "docs/wire-format.md documents types Normalizer.types/0 does not emit: #{inspect(missing_from_code)}"

      assert documented == code
    end
  end

  # Parses the "## Type index" table's rows - the first column, a
  # backtick-quoted type string, e.g. "| `trace.event_dequeued` | trace | ... |".
  @spec extract_type_index_types(String.t()) :: MapSet.t(String.t())
  defp extract_type_index_types(document) do
    [_before, table_and_after] = String.split(document, "## Type index", parts: 2)

    ~r/^\|\s*`([a-z._]+)`\s*\|/m
    |> Regex.scan(table_and_after, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end
end
