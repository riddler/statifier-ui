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
    value: "authorization.amount_cents > 10",
    candidates: ["authorization.amount_cents", "card.brand"]
  }

  defp seam_html(overrides \\ %{}) do
    @seam |> Map.merge(overrides) |> ExpressionInput.expression_input() |> rendered_to_string()
  end

  describe "the sb seam's calling convention" do
    test "renders from a bare five-key map, where no attr default has run" do
      html = seam_html()

      assert html =~ ~s(id="sb-field-node1-cond")
      assert html =~ ~s(name="config[cond]")
      assert html =~ ~s(value="authorization.amount_cents &gt; 10")
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

      assert %{"insert" => "authorization.amount_cents", "kind" => "path"} =
               Enum.find(completions, &(&1["insert"] == "authorization.amount_cents"))

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
      assert html =~ ~s(<option value="authorization.amount_cents">)
      assert html =~ ~s(<option value="contains">)
    end

    test "a host that registers no hook still gets the datalist field" do
      html = seam_html(%{hook: nil})

      refute html =~ "phx-hook"
      assert html =~ ~s(<option value="authorization.amount_cents">)
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

    test "the modes container separates the switches on a page with no stylesheet" do
      html = picklist_html("plan == 'pro'", ["plan"])

      [_, modes] = String.split(html, ~s(class="statifier-ui-expression-modes"), parts: 2)
      [attributes, buttons] = String.split(modes, ">", parts: 2)

      # HEEx drops the whitespace between two adjacent elements, so without a
      # rule on the container the two buttons abut (sui-aln). The default is
      # layout only - nothing a host's palette has to reconcile.
      assert attributes =~ "display: inline-flex"
      assert attributes =~ "gap: 0.5rem"

      # Both switches are siblings inside that one container, so the rule
      # reaches both.
      [switches, _] = String.split(buttons, "</div>", parts: 2)

      assert [_, _] = Regex.scan(~r/class="statifier-ui-expression-switch"/, switches)
      assert switches =~ ~s(data-action="switch-text")
      assert switches =~ ~s(data-action="switch-picklist")
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

      # Backslash first, then quote: predicator 9.4.0's writer escapes both,
      # and the order here is the order a consumer applies them in. The
      # literal is what the writer actually produced when it was last
      # measured, not a rule about what it ought to do - a writer change
      # moves this line, which is the point of the test's name.
      assert json |> unescape() |> JSON.decode!() == [["\\", "\\\\"], ["'", "\\'"]]
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

    test "no operator option is re-cased: every one is the grammar's phrase verbatim" do
      html = picklist_html("amount >= 500", ["amount"])

      # Operator options are the only ones carrying the grammar's one-line
      # description as a title, which is what separates them from the path and
      # value selects in the same rendered form.
      rendered =
        ~r{<option[^>]*\btitle="[^"]*"[^>]*>\s*([^<]*?)\s*</option>}
        |> Regex.scan(html)
        |> Enum.map(fn [_all, label] -> label end)

      grammar = Enum.map(StatifierUI.Expression.operators(:integer), & &1.label)

      assert grammar != []
      assert Enum.sort(rendered) == Enum.sort(grammar)
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

  describe "declared path kinds" do
    test "no path_types renders exactly what the assign-less call renders" do
      paths = ["plan", "status", "amount", "step"]

      for source <- [
            "plan == 'pro'",
            "status == 'active' AND amount >= 500",
            "step IN ['payment']",
            "len(plan) > 0",
            "amount >= >="
          ] do
        without = picklist_html(source, paths)

        assert without == typed_html(source, paths, %{}, %{}),
               "path_types: %{} differed from no assign for #{inspect(source)}"

        assert without == typed_html(source, paths, %{}, %{"unrelated" => :integer}),
               "an unrelated declaration differed from no assign for #{inspect(source)}"
      end
    end

    test "a boolean path renders the two-option control the component already has" do
      html = typed_html("plan == 'pro'", ["plan"], %{}, %{"plan" => :boolean})

      assert html =~ ~s(data-value-kind="select")
      assert html =~ ~s(value="plan == true")
      assert html =~ ~s(value="plan == false")
      assert html =~ ~s(value="plan == &#39;pro&#39;" selected)
    end

    test "a one_of path renders a select" do
      html =
        typed_html("status == 'active'", ["status"], %{}, %{
          "status" => {:one_of, ["active", "pending"]}
        })

      assert html =~ ~s(data-value-kind="select")
      assert html =~ ~s(value="status == &#39;pending&#39;")
    end

    test "an integer path offers the integer operators" do
      html = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => :integer})

      labels = op_labels(html)
      assert labels != []
      assert Enum.sort(labels) == Enum.sort(Enum.map(Expression.operators(:integer), & &1.label))
    end

    test "a boolean path offers no ordered comparison" do
      html = typed_html("plan == 'pro'", ["plan"], %{}, %{"plan" => :boolean})

      labels = op_labels(html)
      grammar = Enum.map(Expression.operators(:boolean), & &1.label)

      assert Enum.sort(labels) == Enum.sort(grammar)
      refute ">" in labels
      gt_label = Expression.operators(:integer) |> Enum.find(&(&1.op == :gt)) |> Map.get(:label)
      refute gt_label in labels
    end

    test "the operator in the source is never dropped from the dropdown" do
      html =
        typed_html("plan CONTAINS 'pro'", ["plan"], %{}, %{"plan" => {:list, :string}})

      assert html =~ ~s(value="plan CONTAINS &#39;pro&#39;" selected)
      assert html =~ "is one of"
    end

    test "the declared kind is stamped on the clause row" do
      integer_html = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => :integer})
      assert integer_html =~ ~s(data-declared-kind="integer")

      list_html = typed_html("plan CONTAINS 'pro'", ["plan"], %{}, %{"plan" => {:list, :string}})
      assert list_html =~ ~s(data-declared-kind="list:string")

      one_of_html =
        typed_html("status == 'active'", ["status"], %{}, %{
          "status" => {:one_of, ["active", "pending"]}
        })

      assert one_of_html =~ ~s(data-declared-kind="one-of")

      refute typed_html("plan == 'pro'", ["plan"], %{}, %{}) =~ "data-declared-kind"
    end

    test "a date path offers the relative-date set" do
      html = typed_html("created_at >= 500", ["created_at"], %{}, %{"created_at" => :date})

      assert html =~ ~s(value="created_at &gt;= 7d ago")
    end

    test "a list declaration on a list value reaches the multiselect" do
      with_candidates =
        typed_html("step IN ['payment']", ["step"], %{"step" => ["payment", "review"]}, %{
          "step" => {:list, :string}
        })

      assert with_candidates =~ ~s(data-value-kind="multiselect")

      without_candidates =
        typed_html("step IN ['payment']", ["step"], %{}, %{"step" => {:list, :string}})

      assert without_candidates =~ ~s(data-value-kind="readonly")
    end

    test "a list declaration on a scalar value does not" do
      html = typed_html("plan == 'pro'", ["plan"], %{}, %{"plan" => {:list, :string}})

      assert html =~ ~s(data-value-kind="text")
      refute html =~ ~s(data-value-kind="multiselect")
    end

    test "a disagreement is advisory and nothing else" do
      html = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => :string})

      assert html =~ ~s(data-advisory="value-kind")
      assert html =~ ~s(data-severity="info")
      assert html =~ ~s(data-subset="inside")
      assert html =~ ~s(data-mode="picklist")
      assert html =~ ~s(value="amount &gt;= 500")
    end

    test "an advisory never appears for an agreeing declaration" do
      html = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => :integer})

      refute html =~ "data-advisory"
    end

    test "value_candidates still win over a one_of for the same path" do
      html =
        typed_html("status == 'active'", ["status"], %{"status" => ["active", "settled"]}, %{
          "status" => {:one_of, ["active", "pending"]}
        })

      assert html =~ ~s(value="status == &#39;settled&#39;")
      refute html =~ ~s(value="status == &#39;pending&#39;")
    end

    test "the sui-ivh recoverability property survives a declaration" do
      path_types = %{
        "plan" => :string,
        "status" => :string,
        "amount" => :integer,
        "risk" => :integer,
        "verdict" => :string
      }

      for source <- [
            "plan == 'pro'",
            "status == 'active' AND amount >= 500",
            "risk >= 70 OR verdict == 'review'"
          ] do
        controls =
          source
          |> typed_html(["plan", "status", "amount", "risk", "verdict"], %{}, path_types)
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
  end

  describe "seeding a new clause from the declaration (sui-loj)" do
    test "a numeric path seeds a number and the new row carries no advisory" do
      html = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => :integer})

      assert html =~ ~s(data-source="amount &gt;= 500 AND amount == 0")

      assert add_clause_advisories(html, %{"amount" => :integer}) == []
    end

    test "every declared kind the writer can spell seeds a literal of that kind" do
      today = Date.utc_today()

      for {kind, expected} <- [
            {:integer, "amount == 0"},
            {:number, "amount == 0"},
            {:float, "amount == 0.0"},
            {:boolean, "amount == true"},
            {:date, "amount == " <> hash() <> "#{today}" <> hash()},
            {:duration, "amount == 1d"},
            {:relative_date, "amount == 1d ago"},
            {{:list, :string}, "amount CONTAINS ''"},
            {{:list, :integer}, "amount CONTAINS 0"},
            {{:one_of, ["active", "pending"]}, "amount == 'active'"},
            {{:one_of, [1, 2]}, "amount == 1"}
          ] do
        path_types = %{"amount" => kind}
        html = typed_html("amount >= 500", ["amount"], %{}, path_types)

        assert add_clause_source(html) == "amount >= 500 AND " <> expected,
               "#{inspect(kind)} seeded #{inspect(add_clause_source(html))}"

        assert add_clause_advisories(html, path_types) == [],
               "#{inspect(kind)} seeded a row that immediately advises about itself"
      end
    end

    test "a datetime path seeds midnight today, which is a value and not a moment" do
      path_types = %{"amount" => :datetime}
      html = typed_html("amount >= 500", ["amount"], %{}, path_types)

      assert add_clause_source(html) ==
               "amount >= 500 AND amount == " <>
                 hash() <> "#{Date.utc_today()}T00:00:00Z" <> hash()

      assert add_clause_advisories(html, path_types) == []
    end

    test "an undeclared path still seeds the empty string" do
      html = picklist_html("amount >= 500", ["amount"])

      assert add_clause_source(html) == "amount >= 500 AND amount == ''"
    end

    test "a list declaring no member kind falls back to the undeclared seed" do
      declared = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => {:list, nil}})

      assert add_clause_source(declared) == "amount >= 500 AND amount == ''"
    end

    test "a one_of whose first value has no literal spelling falls back too" do
      html = typed_html("amount >= 500", ["amount"], %{}, %{"amount" => {:one_of, [-1, -2]}})

      assert add_clause_source(html) == "amount >= 500 AND amount == ''"
    end

    test "a one_of of candidate maps seeds the value, not the map" do
      html =
        typed_html("amount >= 500", ["amount"], %{}, %{
          "amount" => {:one_of, [%{label: "Active", value: "active"}]}
        })

      assert add_clause_source(html) == "amount >= 500 AND amount == 'active'"
    end
  end

  describe "a datamodel document declares the kinds" do
    @document %{
      "version" => 1,
      "scopes" => [
        %{
          "scope" => "local",
          "entries" => [
            %{"name" => "amount_cents", "path" => "amount_cents", "type" => "integer"},
            %{"path" => "risk_reasons", "type" => "list", "item_type" => "string"},
            %{
              "path" => "card",
              "type" => "object",
              "fields" => [
                %{
                  "path" => "card.brand",
                  "type" => "string",
                  "one_of" => ["visa", "mastercard", "amex"]
                }
              ]
            }
          ]
        }
      ]
    }

    @paths ["amount_cents", "risk_reasons", "card.brand"]

    test "a document renders exactly what its own projection renders as a map" do
      projected = StatifierDatamodel.Index.path_types(StatifierDatamodel.Index.index(@document))

      # The map is not restated here: the point of the golden is that the two
      # inputs meet, so the map half is asked of sd exactly as the component
      # asks for it.
      for source <- [
            "amount_cents >= 500",
            "card.brand == 'visa'",
            "risk_reasons CONTAINS 'velocity' AND amount_cents >= 500"
          ] do
        assert document_html(source, @paths) == typed_html(source, @paths, %{}, projected),
               "the document and its projection differed for #{inspect(source)}"
      end
    end

    test "a document-declared number seeds a number" do
      html = document_html("amount_cents >= 500", @paths)

      assert add_clause_source(html) == "amount_cents >= 500 AND amount_cents == 0"
    end

    test "a document-declared one_of draws its select" do
      html = document_html("card.brand == 'visa'", @paths)

      assert html =~ ~s(data-declared-kind="one-of")
      assert html =~ ~s(value="card.brand == &#39;mastercard&#39;")
    end

    test "a non-empty path_types wins over the document" do
      html =
        seam_html(%{
          value: "amount_cents >= 500",
          candidates: @paths,
          document: @document,
          path_types: %{"amount_cents" => :boolean}
        })

      assert html =~ ~s(data-declared-kind="boolean")
      assert add_clause_source(html) == "amount_cents >= 500 AND amount_cents == true"
    end

    test "an empty path_types is not a statement, so the document still speaks" do
      assert seam_html(%{
               value: "amount_cents >= 500",
               candidates: @paths,
               document: @document,
               path_types: %{}
             }) == document_html("amount_cents >= 500", @paths)
    end

    test "no document and no map is exactly the undeclared render" do
      assert seam_html(%{value: "amount_cents >= 500", candidates: @paths, document: nil}) ==
               picklist_html("amount_cents >= 500", @paths)
    end

    test "something that is not a document declares nothing rather than raising" do
      assert seam_html(%{value: "amount_cents >= 500", candidates: @paths, document: %{"a" => 1}}) ==
               picklist_html("amount_cents >= 500", @paths)
    end
  end

  # The date-literal delimiter, as a function so no line of this file has to
  # carry a bare `#` inside an interpolating string.
  defp hash, do: "#"

  defp document_html(value, candidates) do
    seam_html(%{value: value, candidates: candidates, document: @document})
  end

  # The source the add-clause button carries, unescaped the way a browser
  # would read it back off the attribute.
  defp add_clause_source(html) do
    ~r/data-action="add-clause"[^>]*data-source="(?<source>[^"]*)"/
    |> Regex.run(html, capture: :all_names)
    |> case do
      [source] -> unescape(source)
      nil -> nil
    end
  end

  # The advisories the *new* row would carry the moment it is drawn. This is
  # sui-loj's whole question: a seed is wrong when the declaration that chose
  # it then complains about it.
  defp add_clause_advisories(html, path_types) do
    {:ok, rows, _connective} =
      html |> add_clause_source() |> Expression.simple(path_types: path_types)

    rows |> List.last() |> Map.get(:advisories)
  end

  defp op_labels(html) do
    ~r{<option[^>]*\btitle="[^"]*"[^>]*>\s*([^<]*?)\s*</option>}
    |> Regex.scan(html)
    |> Enum.map(fn [_all, label] -> label end)
  end

  defp typed_html(value, candidates, value_candidates, path_types) do
    seam_html(%{
      value: value,
      candidates: candidates,
      value_candidates: value_candidates,
      path_types: path_types
    })
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
