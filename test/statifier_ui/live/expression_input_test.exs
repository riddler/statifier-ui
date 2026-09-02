defmodule StatifierUI.Live.ExpressionInputTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias StatifierUI.Expression
  alias StatifierUI.Live.ExpressionInput

  # Exactly the map StatifierBlocks.Editor.Field builds for the
  # `expression_component` seam (statifier_blocks
  # lib/statifier_blocks/editor/field.ex:284-306). The point of holding a
  # literal copy here is that a change to that call shape shows up as a failing
  # test in this repo rather than as a KeyError in a host's page.
  @seam %{
    field: :a_view_model_field_this_component_never_reads,
    id: "sb-field-node1-cond",
    name: "config[cond]",
    value: "order.total > 10",
    candidates: ["order.total", "customer.tier"]
  }

  defp seam_html(overrides \\ %{}) do
    @seam |> Map.merge(overrides) |> ExpressionInput.expression_input() |> rendered_to_string()
  end

  describe "the sb seam's calling convention" do
    test "renders from a bare five-key map, where no attr default has run" do
      html = seam_html()

      assert html =~ ~s(id="sb-field-node1-cond")
      assert html =~ ~s(name="config[cond]")
      assert html =~ ~s(value="order.total &gt; 10")
    end

    test "ignores :field entirely - reading it would mean depending on sb" do
      assert seam_html() == seam_html(%{field: %{something: "else"}})
    end

    test "a nil value renders as an empty field rather than raising" do
      assert seam_html(%{value: nil}) =~ ~s(value="")
    end
  end

  describe "the round trip back to the host" do
    test "the input carries the seam's name, so the host's form change event carries it" do
      html = seam_html()

      assert html =~ ~s(name="config[cond]")
    end

    test "it declares no event of its own - the enclosing form owns the change" do
      html = seam_html()

      refute html =~ "phx-change"
      refute html =~ "phx-target"
      refute html =~ "phx-submit"
    end

    test "the hook is named on the element, which is what makes it insertable" do
      assert seam_html() =~ ~s(phx-hook="StatifierUIExpressionInput")
      assert ExpressionInput.hook_name() == "StatifierUIExpressionInput"
    end
  end

  describe "the stamped contract (ADR-0007)" do
    test "the completion set is on the element, as the hook's whole input" do
      html = seam_html()

      [_all, json] = Regex.run(~r/data-completions="([^"]*)"/, html)
      completions = json |> unescape() |> JSON.decode!()

      assert %{"insert" => "order.total", "kind" => "path"} =
               Enum.find(completions, &(&1["insert"] == "order.total"))

      assert Enum.any?(completions, &(&1["kind"] == "comparison"))
      assert length(completions) == length(Expression.completions(@seam.candidates))
    end

    test "the counts and the vocabulary state are stamped, not inferred" do
      html = seam_html()

      assert html =~ ~s(data-candidates="2")
      assert html =~ ~s(data-vocabulary="true")

      assert html =~
               ~s(data-completion-count="#{length(Expression.completions(@seam.candidates))}")
    end
  end

  describe "the no-JavaScript affordance" do
    test "the field is bound to a datalist of the word-shaped completions" do
      html = seam_html()

      assert html =~ ~s(list="sb-field-node1-cond-completions")
      assert html =~ ~s(<datalist id="sb-field-node1-cond-completions">)
      assert html =~ ~s(<option value="order.total">)
      assert html =~ ~s(<option value="contains">)
    end

    test "a host that registers no hook still gets the datalist field" do
      html = seam_html(%{hook: nil})

      refute html =~ "phx-hook"
      assert html =~ ~s(<option value="order.total">)
    end
  end

  describe "as a component tag" do
    test "the same function works through HEEx, where attr defaults do apply" do
      html =
        render_component(&ExpressionInput.expression_input/1,
          id: "cond",
          name: "cond",
          candidates: ["a.b"]
        )

      assert html =~ ~s(value="")
      assert html =~ ~s(data-candidates="1")
      assert html =~ ~s(placeholder="an expression")
    end

    test "vocabulary_opts reach Predicator.Vocabulary.functions/1" do
      html =
        render_component(&ExpressionInput.expression_input/1,
          id: "cond",
          name: "cond",
          vocabulary_opts: [builtins: false]
        )

      [_all, json] = Regex.run(~r/data-completions="([^"]*)"/, html)

      refute json |> unescape() |> JSON.decode!() |> Enum.any?(&(&1["kind"] == "function"))
    end
  end

  # HEEx escapes attribute values; the completion JSON is read back through the
  # same escaping a browser would undo.
  defp unescape(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end
end
