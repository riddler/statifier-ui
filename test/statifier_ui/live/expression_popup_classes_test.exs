defmodule StatifierUI.Live.ExpressionPopupClassesTest do
  use ExUnit.Case, async: true

  # The completion popup's DOM is built at runtime by the expression hook, so
  # its class names appear in no HEEx template and no rendering test sees
  # them. `docs/ops-embedding.md`'s "Styling and theming" section documents
  # them in their own table, and a host's stylesheet is written against that
  # table. This test holds the table and the hook to the same names, in both
  # directions: a class the table documents that the hook no longer builds,
  # or a class the hook builds that the table does not document, fails here
  # rather than in a host's page.

  @root Path.expand("../../..", __DIR__)
  @doc_path Path.join(@root, "docs/ops-embedding.md")
  @hook_path Path.join(@root, "assets/js/expression_input.js")

  @external_resource @doc_path
  @external_resource @hook_path

  # The sentence that opens the popup's table in the styling section.
  @table_lead "Two of the surfaces a host styles are built by the hook at runtime"

  describe "the hook-built popup's class names" do
    # Sabotage: renamed `statifier-ui-expression-option-kind` in the hook,
    # and separately renamed the `-option-detail` row in the doc's table -
    # this test went red on its assert each time, the other two stayed
    # green.
    test "the styling table documents exactly the classes the hook builds" do
      assert documented_classes() == built_classes()
    end

    # Sabotage: set the option's kind through `dataset` instead of
    # `setAttribute("data-kind", ...)` in the hook - this test went red on
    # the subset assert, the other two stayed green.
    test "every attribute the table names in a selector is one the hook sets" do
      documented = documented_attributes()

      assert documented != MapSet.new()
      assert MapSet.subset?(documented, set_attributes())
    end

    test "the table reads the popup's six selectors" do
      assert length(documented_selectors()) == 6
      assert ".statifier-ui-expression-popup" in documented_selectors()
    end
  end

  # The first column of the table that follows the lead sentence: every
  # backticked selector up to the first line that is not a table row.
  defp documented_selectors do
    [_before, after_lead] = @doc_path |> File.read!() |> String.split(@table_lead, parts: 2)

    after_lead
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "|")))
    |> Enum.take_while(&String.starts_with?(&1, "|"))
    |> Enum.flat_map(fn row ->
      Regex.run(~r/^\| `([^`]+)` \|/, row, capture: :all_but_first) || []
    end)
  end

  defp documented_classes do
    documented_selectors()
    |> Enum.flat_map(&Regex.scan(~r/\.([a-z][a-z0-9-]*)/, &1, capture: :all_but_first))
    |> List.flatten()
    |> MapSet.new()
  end

  defp documented_attributes do
    documented_selectors()
    |> Enum.flat_map(&Regex.scan(~r/\[([a-z][a-z0-9-]*)\]/, &1, capture: :all_but_first))
    |> List.flatten()
    |> MapSet.new()
  end

  # Every class the hook assigns, through `className =` or `classList.add`.
  defp built_classes do
    source = File.read!(@hook_path)

    [~r/className = "([^"]+)"/, ~r/classList\.add\("([^"]+)"\)/]
    |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
    |> List.flatten()
    |> Enum.flat_map(&String.split/1)
    |> MapSet.new()
  end

  defp set_attributes do
    ~r/setAttribute\("([^"]+)"/
    |> Regex.scan(File.read!(@hook_path), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end
end
