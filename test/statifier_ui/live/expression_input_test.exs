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

  describe "picklist mode" do
    test "a single clause is the base case, and it renders as one row" do
      html = picklist_html("plan == 'pro'", ["plan"])

      assert html =~ ~s(data-subset="inside")
      assert html =~ ~s(data-mode="picklist")
      assert html =~ ~s(data-clause-count="1")
      assert html =~ ~s(data-clause-index="0")
      assert html =~ ~s(data-role="path")
      assert html =~ ~s(data-role="operator")
      assert html =~ ~s(data-role="value")
    end

    test "two clauses get a row each and a connective toggle" do
      html = picklist_html("status == 'active' AND amount >= 500", ["status", "amount"])

      assert html =~ ~s(data-clause-count="2")
      assert html =~ ~s(data-clause-index="1")
      assert html =~ ~s(data-role="connective")
    end

    test "one clause has no connective toggle - there is nothing to join" do
      refute picklist_html("plan == 'pro'", ["plan"]) =~ ~s(data-role="connective")
    end

    test "a valid expression outside the subset falls back to the text input" do
      html = picklist_html("status == 'active' AND (amount >= 500 OR plan == 'pro')", ["status"])

      assert html =~ ~s(data-subset="outside")
      assert html =~ ~s(data-mode="text")
      assert html =~ ~s(data-clause-count="0")
      assert html =~ ~s(class="statifier-ui-expression-input")
      refute html =~ ~s(data-role="path")
    end

    test "source that does not parse is a third answer, and also falls back" do
      html = picklist_html("amount >= >=", ["amount"])

      assert html =~ ~s(data-subset="error")
      assert html =~ ~s(data-mode="text")
    end

    test "a parse failure carries its position, per ADR-0007's amendment" do
      html = picklist_html("amount >= >=", ["amount"])

      assert html =~ ~s(data-error-position="1:11")
      assert html =~ ~s(role="alert")
      assert html =~ "line 1, column 11"
    end

    test "a valid expression outside the subset is not a diagnostic" do
      html = picklist_html("status == 'active' AND (amount >= 500 OR plan == 'pro')", [])

      refute html =~ "data-error-position"
      refute html =~ ~s(role="alert")
    end

    test "switch to text is always offered; switch to picklists only inside the subset" do
      inside = picklist_html("plan == 'pro'", ["plan"])
      outside = picklist_html("status == 'active' AND (amount >= 500 OR plan == 'pro')", [])

      assert inside =~ ~s(data-action="switch-text")
      assert inside =~ ~s(data-action="switch-picklist")

      assert outside =~ ~s(data-action="switch-text")
      refute outside =~ ~s(data-action="switch-picklist")
    end

    test "the author's text is never rewritten - the input still carries it verbatim" do
      html = picklist_html("plan=='pro'", ["plan"])

      assert html =~ ~s(value="plan==&#39;pro&#39;")
    end

    test "a host that registers no hook gets no picklist, only the text field" do
      html = seam_html(%{value: "plan == 'pro'", hook: nil})

      refute html =~ "phx-hook"
      refute html =~ ~s(data-role="path")
      assert html =~ ~s(data-mode="text")
    end
  end

  describe "every control writes source text" do
    test "an option's value is the whole expression choosing it produces" do
      html = picklist_html("status == 'active' AND amount >= 500", ["status", "amount"])

      # the operator row for clause two, swapped to `>` - the rest untouched
      assert html =~ ~s(value="status == &#39;active&#39; AND amount &gt; 500")
      # and the connective toggle carries the whole expression joined the other way
      assert html =~ ~s(value="status == &#39;active&#39; OR amount &gt;= 500")
    end

    test "a path option carries the same expression over a different field" do
      html = picklist_html("plan == 'pro'", ["plan", "card.brand"])

      assert html =~ ~s(value="card.brand == &#39;pro&#39;")
    end

    test "add clause is one more source string, not a row pushed onto a model" do
      html = picklist_html("plan == 'pro'", ["plan"])

      assert html =~ ~s(data-action="add-clause")
      assert html =~ ~s(data-source="plan == &#39;pro&#39; AND plan == &#39;&#39;")
    end

    test "remove clause carries the expression without that clause, and drops the connective" do
      html = picklist_html("status == 'active' AND amount >= 500", ["status", "amount"])

      assert html =~ ~s(data-action="remove-clause")
      assert html =~ ~s(data-source="amount &gt;= 500")
    end

    test "a single clause offers no remove - the subset has no empty expression" do
      refute picklist_html("plan == 'pro'", ["plan"]) =~ ~s(data-action="remove-clause")
    end
  end

  describe "value controls" do
    test "declared values become a select, whose options are whole expressions" do
      html =
        picklist_html("status == 'active'", ["status"], %{"status" => ["active", "pending"]})

      assert html =~ ~s(data-value-kind="select")
      assert html =~ ~s(value="status == &#39;pending&#39;")
    end

    test "a value the host did not declare is kept, never dropped from the list" do
      html = picklist_html("status == 'settled'", ["status"], %{"status" => ["active"]})

      assert html =~ ~s(value="status == &#39;settled&#39;" selected)
    end

    test "a list value becomes a multi-select over the declared candidates" do
      html =
        picklist_html("step in ['payment', 'review']", ["step"], %{
          "step" => ["payment", "review", "confirmation"]
        })

      assert html =~ ~s(data-value-kind="multiselect")
      assert html =~ ~s(<option value="&#39;confirmation&#39;">)
      assert html =~ ~s(<option value="&#39;payment&#39;" selected>)
    end

    test "the list control is handed the writer's own punctuation, not JavaScript's" do
      html =
        picklist_html("step in ['payment']", ["step"], %{"step" => ["payment", "review"]})

      assert html =~ ~s(data-list-open="[")
      assert html =~ ~s(data-list-separator=", ")
      assert html =~ ~s(data-list-close="]")
      assert html =~ ~s(data-sentinel="[&#39;SUIVALUESENTINEL&#39;]")
    end

    test "a free-text value gets a source template with the value's own spelling in it" do
      html = picklist_html("plan == 'pro'", ["plan"])

      assert html =~ ~s(data-value-kind="text")
      assert html =~ ~s(data-source-template="plan == &#39;SUIVALUESENTINEL&#39;")
      assert html =~ ~s(data-sentinel="&#39;SUIVALUESENTINEL&#39;")
      assert html =~ ~s(data-wrap-prefix="&#39;")
      assert html =~ ~s(data-wrap-suffix="&#39;")
      assert html =~ ~s(value="pro")
    end

    test "the escaping handed over is the writer's, measured rather than assumed" do
      html = picklist_html("plan == 'pro'", ["plan"])

      [_all, json] = Regex.run(~r/data-escapes="([^"]*)"/, html)

      assert json |> unescape() |> JSON.decode!() == [["'", "\\'"]]
    end

    test "a number is spelled bare, so its template wraps in nothing" do
      html = picklist_html("amount >= 500", ["amount"])

      assert html =~ ~s(data-source-template="amount &gt;= 4294967291")
      assert html =~ ~s(data-wrap-prefix="")
      assert html =~ ~s(data-escapes="[]")
      assert html =~ ~s(value="500")
    end

    test "a list with nothing declared for it renders read-only rather than wrongly" do
      html = picklist_html("step in ['payment']", ["step"])

      assert html =~ ~s(data-value-kind="readonly")
    end
  end

  describe "labels are display, source is not" do
    test "an operator reads as the grammar's phrase and stores the writer's spelling" do
      html =
        picklist_html("step in ['payment']", ["step"], %{"step" => ["payment"]})

      assert html =~ ">\n          is one of\n        <"
      assert html =~ ~s(value="step IN [&#39;payment&#39;]")
    end

    test "display_label/1 is the only place a label is cased" do
      assert ExpressionInput.display_label("IN") == "in"
      assert ExpressionInput.display_label("CONTAINS") == "contains"
      assert ExpressionInput.display_label(">=") == ">="
      assert ExpressionInput.display_label("!==") == "!=="
    end
  end

  describe "mode selection" do
    test "the host can ask for text even when the source is inside the subset" do
      html = seam_html(%{value: "plan == 'pro'", candidates: ["plan"], mode: :text})

      assert html =~ ~s(data-mode="text")
      # the rows are still rendered, so the switch has something to reveal
      assert html =~ ~s(data-role="path")
    end

    test "asking for picklists outside the subset still renders text" do
      html = seam_html(%{value: "len(plan) > 0", candidates: ["plan"], mode: :picklist})

      assert html =~ ~s(data-mode="text")
    end
  end

  describe "accessibility" do
    test "every picklist control is labelled, and the group says what it is" do
      html = picklist_html("status == 'active' AND amount >= 500", ["status", "amount"])

      assert html =~ ~s(aria-label="expression clauses")
      assert html =~ ~s(aria-label="field, clause 1")
      assert html =~ ~s(aria-label="operator, clause 2")
      assert html =~ ~s(aria-label="value, clause 1")
      assert html =~ ~s(aria-label="how the clauses join")
      assert html =~ ~s(aria-label="remove clause 2")
    end

    test "the switches say which mode is current" do
      html = picklist_html("plan == 'pro'", ["plan"])

      assert html =~ ~s(data-action="switch-picklist" aria-pressed="true")
      assert html =~ ~s(data-action="switch-text" aria-pressed="false")
    end

    test "the buttons are buttons, so a host form is not submitted by one" do
      html = picklist_html("status == 'active' AND amount >= 500", ["status", "amount"])

      refute html =~ ~s(<button type="submit")
      assert html =~ ~s(<button type="button")
    end
  end

  # LiveView will not patch a `<select>` that has focus unless it can see the
  # option list change, and picking a different operator leaves the set of
  # option values identical - so the control the author just used is exactly
  # the one whose `selected` attributes go stale (sui-ivh). The hook repairs it
  # from the source rather than from those attributes, which is only possible
  # while the property below holds.
  describe "the selection is recoverable from the source alone (sui-ivh)" do
    test "every single-choice control offers the current source, and marks it" do
      for source <- [
            "plan == 'pro'",
            "status == 'active' AND amount >= 500",
            "risk >= 70 OR verdict == 'review'"
          ] do
        controls =
          source
          |> picklist_html(["plan", "status", "amount", "risk", "verdict"])
          |> picklist_controls()
          |> Enum.reject(& &1.multiple?)

        assert controls != []

        for control <- controls do
          values = Enum.map(control.options, & &1.value)
          marked = Enum.filter(control.options, & &1.selected?)

          assert source in values,
                 "the #{control.role} control offers no option spelling #{inspect(source)}"

          assert [%{value: ^source}] = marked,
                 "the #{control.role} control marks #{inspect(Enum.map(marked, & &1.value))}"
        end
      end
    end

    test "a multi-select is the exception the hook leaves alone" do
      controls =
        "step IN ['payment']"
        |> picklist_html(["step"], %{"step" => ["payment", "review"]})
        |> picklist_controls()

      assert [multi] = Enum.filter(controls, & &1.multiple?)

      # Its options are list fragments, not whole sources, so the source-match
      # the other controls are repaired by does not apply to this one.
      refute Enum.any?(multi.options, &(&1.value == "step IN ['payment']"))
      assert Enum.any?(multi.options, &(&1.value == "'payment'" and &1.selected?))
    end
  end

  # The rendered controls, read back the way a browser would see them. Parsing
  # is regex rather than a DOM library because the toolchain here deliberately
  # carries neither Node nor an HTML parser (see CLAUDE.md).
  defp picklist_controls(html) do
    ~r/<select(?<attrs>[^>]*)>(?<body>.*?)<\/select>/s
    |> Regex.scan(html, capture: :all_names)
    |> Enum.map(fn [attrs, body] ->
      %{
        role: attribute(attrs, "data-role"),
        multiple?: attrs =~ "multiple",
        options: options(body)
      }
    end)
  end

  defp options(body) do
    ~r/<option(?<attrs>[^>]*)>/
    |> Regex.scan(body, capture: :all_names)
    |> Enum.map(fn [attrs] ->
      %{value: unescape(attribute(attrs, "value")), selected?: attrs =~ " selected"}
    end)
  end

  defp attribute(attrs, name) do
    case Regex.run(~r/#{name}="(?<value>[^"]*)"/, attrs, capture: :all_names) do
      [value] -> value
      nil -> nil
    end
  end

  defp picklist_html(value, candidates, value_candidates \\ %{}) do
    seam_html(%{value: value, candidates: candidates, value_candidates: value_candidates})
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
