defmodule StatifierUI.Trace.DiagnosticTest do
  @moduledoc """
  Unit coverage for `StatifierUI.Trace.Diagnostic`'s `object/4` shape and its
  `anchor/3` dispatch table, plus the character-reference regression that is
  this module's whole reason for existing.

  Every chart below is an inline heredoc (matching `golden_trace_test.exs`'s
  `@two_state` convention) rather than a file under `test/support/fixtures/`
  - that directory holds `StatifierUI.Fixtures.Source` behaviour modules, and
  a sibling PR is moving files inside it.

  Every failing expression here is produced by a **real** evaluation
  (`Statifier.Evaluator.evaluate/2` against a real, compiled
  `%Statifier.Machine{}`) rather than a hand-built `%Evaluator.Error{}`
  literal - a literal could not catch a wrong assumption about what the
  engine actually hands back, which is exactly what the regression case
  below exists to catch.
  """

  use ExUnit.Case, async: true

  alias Statifier.Evaluator
  alias Statifier.Parser.Location
  alias StatifierUI.Trace.Diagnostic

  # A less-than guard written with a character reference, which is the case
  # naive span composition gets wrong: `&lt;` is four raw characters standing
  # for one expanded character, so every column after it is shifted by
  # three. `amount` is bound and `limit` is not, so the engine's own
  # UndefinedVariableError attributes to the subexpression *after* the
  # reference - the half where the divergence is observable.
  @entity_guard """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
      <datamodel><data id="amount" expr="100"/></datamodel>
      <state id="idle">
          <transition event="myapp:authorize" cond="amount &lt; limit" target="approved"/>
      </state>
      <state id="approved"/>
  </scxml>
  """

  @unconditional """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
      <state id="idle">
          <transition event="myapp:signup" target="done"/>
      </state>
      <state id="done"/>
  </scxml>
  """

  @data_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
      <datamodel>
          <data id="limit" expr="unknown"/>
          <data id="bare"/>
      </datamodel>
      <state id="idle"/>
  </scxml>
  """

  @content_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
      <datamodel><data id="amount" expr="100"/></datamodel>
      <state id="idle">
          <onentry>
              <log expr="amount &lt; limit"/>
              <raise event="myapp:capture"/>
              <if cond="amount &lt; limit">
                  <log label="a"/>
              <elseif cond="amount &lt; 1"/>
                  <log label="b"/>
              </if>
          </onentry>
      </state>
  </scxml>
  """

  @invoke_chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
      <state id="idle">
          <invoke type="myapp:capture" src="unused"/>
      </state>
      <final id="done">
          <donedata>
              <param name="p" expr="amount &lt; limit"/>
          </donedata>
      </final>
  </scxml>
  """

  # -- fixtures ---------------------------------------------------------------

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # A real `%Evaluator.Error{}`: evaluates `expr` with `amount` bound and
  # `on_unbound: :error`, so a `limit` reference fails exactly as the
  # engine's own datamodel evaluation would.
  defp evaluate!(expr) do
    context = Predicator.Context.new(%{"amount" => 100}, on_unbound: :error)
    {:error, %Evaluator.Error{} = error} = Evaluator.evaluate(context, expr)
    error
  end

  # The inverse of `location_object/1` in `Diagnostic` - rebuilds a
  # `%Location{}` from the wire object's six fields so `Location.slice/2`
  # can be reused on it directly.
  defp location_from_object(%{
         "start_line" => start_line,
         "start_column" => start_column,
         "start_offset" => start_offset,
         "end_line" => end_line,
         "end_column" => end_column,
         "end_offset" => end_offset
       }) do
    %Location{
      start_line: start_line,
      start_column: start_column,
      start_offset: start_offset,
      end_line: end_line,
      end_column: end_column,
      end_offset: end_offset
    }
  end

  defp naive_composition(value_location, {{start_line, start_column}, {end_line, end_column}}) do
    %{
      value_location
      | start_line: value_location.start_line + start_line - 1,
        start_column: value_location.start_column + start_column - 1,
        start_offset: value_location.start_offset + start_column - 1,
        end_line: value_location.end_line + end_line - 1,
        end_column: value_location.start_column + end_column - 1,
        end_offset: value_location.start_offset + end_column - 1
    }
  end

  # -- object/4: presence combinations -----------------------------------------

  describe "object/4" do
    test "always carries kind and expression" do
      error = %Evaluator.Error{
        source: "amount < limit",
        error: %Predicator.Errors.UndefinedVariableError{
          message: "Undefined variable: limit",
          variable: "limit"
        },
        span: nil
      }

      object = Diagnostic.object(error, nil, nil, nil)

      assert object["kind"] == "undefined_variable"
      assert object["expression"] == "amount < limit"
      refute Map.has_key?(object, "span")
      refute Map.has_key?(object, "location")
      refute Map.has_key?(object, "location_kind")
    end

    test "carries span when the error has one" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      object = Diagnostic.object(error, {:transition, 0}, nil, nil)

      assert object["span"] == %{
               "start_line" => 1,
               "start_column" => 10,
               "end_line" => 1,
               "end_column" => 15
             }
    end

    test "omits span when the error has none" do
      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "boom", reason: :boom},
        span: nil
      }

      object = Diagnostic.object(error, nil, nil, nil)

      refute Map.has_key?(object, "span")
    end

    test "omits location when machine is nil" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      object = Diagnostic.object(error, {:transition, 0}, nil, @entity_guard)

      refute Map.has_key?(object, "location")
      refute Map.has_key?(object, "location_kind")
    end

    test "omits location when source is nil" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      object = Diagnostic.object(error, {:transition, 0}, machine, nil)

      refute Map.has_key?(object, "location")
      refute Map.has_key?(object, "location_kind")
    end

    test "omits location when origin is nil, even with machine and source" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      object = Diagnostic.object(error, nil, machine, @entity_guard)

      refute Map.has_key?(object, "location")
      refute Map.has_key?(object, "location_kind")
    end

    test "carries a resolved location and location_kind when everything is supplied" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      object = Diagnostic.object(error, {:transition, 0}, machine, @entity_guard)

      assert object["location_kind"] == "resolved"

      assert %{
               "start_line" => _,
               "start_column" => _,
               "start_offset" => _,
               "end_line" => _,
               "end_column" => _,
               "end_offset" => _
             } = object["location"]
    end

    test "underscores every predicator error kind and drops the trailing _error" do
      assert Diagnostic.object(
               %Evaluator.Error{
                 source: "x",
                 error: %Predicator.Errors.ParseError{message: "m", position: {1, 1}}
               },
               nil,
               nil,
               nil
             )["kind"] == "parse"

      assert Diagnostic.object(
               %Evaluator.Error{
                 source: "x",
                 error: %Predicator.Errors.TypeMismatchError{
                   message: "m",
                   expected: :integer,
                   got: :string,
                   operation: :add
                 }
               },
               nil,
               nil,
               nil
             )["kind"] == "type_mismatch"

      assert Diagnostic.object(
               %Evaluator.Error{
                 source: "x",
                 error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom}
               },
               nil,
               nil,
               nil
             )["kind"] == "evaluation"

      assert Diagnostic.object(
               %Evaluator.Error{
                 source: "x",
                 error: %Predicator.Errors.LocationError{type: :bad, message: "m"}
               },
               nil,
               nil,
               nil
             )["kind"] == "location"
    end
  end

  # -- anchor/3: the required arms ---------------------------------------------

  describe "anchor/3" do
    test "transition with a guard anchors on cond_location" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      assert Diagnostic.anchor({:transition, 0}, machine, error) ==
               {:value, transition.cond_location}
    end

    test "transition without a guard falls back to the transition's own location" do
      machine = compile!(@unconditional)
      transition = Statifier.Machine.transition(machine, 0)

      assert transition.cond_location == nil

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:transition, 0}, machine, error) ==
               {:node, transition.location}
    end

    test "<data> with a distinct value span anchors on value_location" do
      machine = compile!(@data_chart)
      data = Enum.find(Tuple.to_list(machine.data_elements), &(&1.id == "limit"))
      assert data.value_location != data.location

      error = evaluate!(data.value)

      assert Diagnostic.anchor({:data, data.d_index}, machine, error) ==
               {:value, data.value_location}
    end

    test "<data> without a distinct value span falls back to the element's own location" do
      machine = compile!(@data_chart)
      data = Enum.find(Tuple.to_list(machine.data_elements), &(&1.id == "bare"))
      assert data.value_location == data.location

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:data, data.d_index}, machine, error) == {:node, data.location}
    end

    test "a matching content kind (<log expr>) anchors on expr_location" do
      machine = compile!(@content_chart)

      log =
        Enum.find(
          Tuple.to_list(machine.contents),
          &match?(%Statifier.Machine.Content.Log{expr: {:compiled, _, _}}, &1)
        )

      error = evaluate!(log.expr)

      assert Diagnostic.anchor({:content, log.c_index, {:onentry, 0, 0}}, machine, error) ==
               {:value, log.expr_location}
    end

    test "a non-matching content kind (<raise>, no expr table entry) falls back to its own location" do
      machine = compile!(@content_chart)

      raise_node =
        Enum.find(
          Tuple.to_list(machine.contents),
          &match?(%Statifier.Machine.Content.Raise{}, &1)
        )

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:content, raise_node.c_index, {:onentry, 0, 0}}, machine, error) ==
               {:node, raise_node.location}
    end

    test "an <if> branch is selected by matching compiled source, not position" do
      machine = compile!(@content_chart)

      if_node =
        Enum.find(Tuple.to_list(machine.contents), &match?(%Statifier.Machine.Content.If{}, &1))

      [first_branch, second_branch] = if_node.branches

      first_error = evaluate!(first_branch.cond)

      assert Diagnostic.anchor(
               {:content, if_node.c_index, {:onentry, 0, 0}},
               machine,
               first_error
             ) ==
               {:value, first_branch.cond_location}

      {:compiled, _compiled, second_source} = second_branch.cond

      second_error = %Evaluator.Error{
        source: second_source,
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor(
               {:content, if_node.c_index, {:onentry, 0, 0}},
               machine,
               second_error
             ) ==
               {:value, second_branch.cond_location}
    end

    test "an origin the table does not name (a top-level <script>) yields :none" do
      machine = compile!(@entity_guard)

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:global_script, 0}, machine, error) == :none
    end

    test "nil origin yields :none" do
      machine = compile!(@entity_guard)

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor(nil, machine, error) == :none
    end

    test "a <state> anchors on its own location" do
      machine = compile!(@entity_guard)
      state_index = machine.id_to_index["idle"]
      state = Statifier.Machine.at(machine, state_index)

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:state, state_index}, machine, error) == {:node, state.location}
    end

    test "a <donedata><param> anchors on its expr_location" do
      machine = compile!(@invoke_chart)
      state_index = machine.id_to_index["done"]
      state = Statifier.Machine.at(machine, state_index)
      [param] = state.donedata.params

      error = evaluate!(param.expr)

      assert Diagnostic.anchor({:donedata_param, state_index, 0}, machine, error) ==
               {:value, param.expr_location}
    end

    test "an <invoke> anchors on its own location" do
      machine = compile!(@invoke_chart)
      state_index = machine.id_to_index["idle"]
      state = Statifier.Machine.at(machine, state_index)
      [invoke] = state.invoke

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:invoke, state_index, 0}, machine, error) ==
               {:node, invoke.location}
    end

    test "an empty <finalize>'s auto-assign anchors on the owning <invoke>'s location" do
      machine = compile!(@invoke_chart)
      state_index = machine.id_to_index["idle"]
      state = Statifier.Machine.at(machine, state_index)
      [invoke] = state.invoke

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:finalize, state_index, 0}, machine, error) ==
               {:node, invoke.location}
    end

    test "an out-of-range invoke_index yields :none rather than raising" do
      machine = compile!(@entity_guard)
      state_index = machine.id_to_index["idle"]

      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: {{1, 1}, {1, 2}}
      }

      assert Diagnostic.anchor({:invoke, state_index, 0}, machine, error) == :none
    end

    test "a nil span never yields {:value, _}, even with a matching value location" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      assert transition.cond_location != nil
      {:compiled, _compiled, source} = transition.cond

      error = %Evaluator.Error{
        source: source,
        error: %Predicator.Errors.EvaluationError{message: "m", reason: :boom},
        span: nil
      }

      assert Diagnostic.anchor({:transition, 0}, machine, error) == {:node, transition.location}
    end
  end

  # -- the character-reference regression --------------------------------------

  describe "the character-reference regression" do
    test "resolve_span/4 slices the failing subexpression exactly, where naive arithmetic does not" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)
      error = evaluate!(transition.cond)

      # Driven through `Diagnostic.object/4` itself, not
      # `Location.resolve_span/4` directly - this is the sabotage test's
      # whole point (see "Implementation Note" in the plan): deleting or
      # replacing `object/4`'s internal `resolve_span/4` call with naive
      # arithmetic must turn this test red.
      object = Diagnostic.object(error, {:transition, 0}, machine, @entity_guard)
      resolved = location_from_object(object["location"])

      naive = naive_composition(transition.cond_location, error.span)

      # 1. The right answer: resolve_span/4 slices out exactly the failing
      #    subexpression.
      assert Location.slice(resolved, @entity_guard) == "limit"

      # 2. The wrong answer: naive `value_location.start_column + span_column
      #    - 1` composition, run over the identical inputs, slices something
      #    else entirely - demonstrating the divergence in the same run
      #    rather than asserting only the right answer.
      assert Location.slice(naive, @entity_guard) == "t; li"

      # 3. Why: `&lt;` is four raw characters standing for the one expanded
      #    `<` predicator counted its columns against, so every column past
      #    the reference is shifted by exactly `byte_size("&lt;") -
      #    byte_size("<")` = 3.
      assert resolved.end_column - naive.end_column == byte_size("&lt;") - byte_size("<")
    end

    # The trap this fixture exists to catch: a span over `amount` - the
    # subexpression *before* the character reference - resolves identically
    # under naive composition and the helper, because nothing between the
    # value's start and this span shifts raw-versus-expanded columns yet. A
    # test built on this subexpression alone would stay green even with
    # `resolve_span/4` deleted and naive arithmetic substituted in its
    # place, so it does not serve as the regression above and must not be
    # "simplified" down to it later.
    test "a span before the reference resolves identically under both compositions (not a regression)" do
      machine = compile!(@entity_guard)
      transition = Statifier.Machine.transition(machine, 0)

      # The `amount` subexpression's own predicator span, from the same
      # compiled program the failing `limit` span came from.
      amount_span = {{1, 1}, {1, 7}}

      resolved =
        Location.resolve_span(
          transition.cond_location,
          amount_span,
          "amount < limit",
          @entity_guard
        )

      naive = naive_composition(transition.cond_location, amount_span)

      assert Location.slice(resolved, @entity_guard) == "amount"
      assert Location.slice(naive, @entity_guard) == "amount"
      assert resolved == naive
    end
  end

  # ADR-0014's peeling rule at the unit level: the normalizer tests cover
  # the two arms end to end, and these cover the wrapper's own edges, which
  # no live chart reaches.
  describe "reason_object/4 - peeling {:nested_content, _, _}" do
    test "content_path keeps the wrappers in outermost-first order" do
      wrapped = {:nested_content, 7, {:nested_content, 2, {:nested_content, 9, :boom}}}

      assert Diagnostic.reason_object(wrapped, nil, nil, nil) == %{
               "class" => "reason",
               "kind" => "boom",
               "reason" => ":boom",
               "content_path" => [7, 2, 9]
             }
    end

    test "an unwrapped term carries no content_path at all" do
      object = Diagnostic.reason_object({:system_variable, "_event"}, nil, nil, nil)

      refute Map.has_key?(object, "content_path")
      assert object["kind"] == "system_variable"
    end

    test "a :nested_content tuple whose index is not a c_index is an ordinary tagged tuple" do
      # `content_path`'s integers are promised to be `session.start`
      # contents-table indexes, so a wrapper that cannot supply one is not
      # peeled into a path that would be lying about them.
      object = Diagnostic.reason_object({:nested_content, "two", :boom}, nil, nil, nil)

      refute Map.has_key?(object, "content_path")
      assert object["kind"] == "nested_content"
      assert object["reason"] == ~s({:nested_content, "two", :boom})
    end

    test "a wrapped %Evaluator.Error{} comes back as the expression arm" do
      error =
        evaluate!(compile!(@entity_guard) |> Statifier.Machine.transition(0) |> Map.fetch!(:cond))

      object = Diagnostic.reason_object({:nested_content, 1, error}, nil, nil, nil)

      assert object["class"] == "expression"
      assert object["expression"] == "amount < limit"
      assert object["content_path"] == [1]
      refute Map.has_key?(object, "reason")
    end
  end
end
