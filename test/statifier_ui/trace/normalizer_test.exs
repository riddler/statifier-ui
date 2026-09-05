defmodule StatifierUI.Trace.NormalizerTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.DatamodelChange
  alias Statifier.Effect.DatamodelInit
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Normalizer

  @ctx %{session: "sess_1", seq: 7}

  # The twenty {tag, payload_module} pairs the engine can emit today
  # (ten trace payloads, ten core effects; DatamodelInit is exercised in
  # its own "session.datamodel" describe instead, since its maximal shape
  # is the probe fixture there) - the table Success Criteria names, so a
  # payload module added upstream and not handled here fails the first
  # assertion below, and a field dropped from a payload fails the second.
  #
  # DatamodelChange's maximal literal populates d_index and c_index
  # together, a shape the engine never emits (they are mutually exclusive
  # identities) - deliberate here, because the convention below is "every
  # optional field populated" so the produced key set covers the full
  # documented schema; the mutually-exclusive real shapes get their own
  # tests in the effect.datamodel_change describe.
  @coverage [
    {:trace, Trace.EventDequeued},
    {:trace, Trace.TransitionsSelected},
    {:trace, Trace.CondsEvaluated},
    {:trace, Trace.ExitSet},
    {:trace, Trace.ContentExecuted},
    {:trace, Trace.EntrySet},
    {:trace, Trace.MacrostepStable},
    {:trace, Trace.Done},
    {:trace, Trace.InvokePass},
    {:trace, Trace.FinalizeAutoforward},
    {:log, Log},
    {:datamodel_change, DatamodelChange},
    {:done, Done},
    {:budget_exhausted, BudgetExhausted},
    {:invoke, Invoke},
    {:cancel_invoke, CancelInvoke},
    {:autoforward, Autoforward},
    {:send, Send},
    {:send_delayed, SendDelayed},
    {:cancel, Cancel}
  ]

  describe "normalize/2 - the ten trace.* effects" do
    test "trace.event_dequeued" do
      event = %Event{name: "go", type: :external, data: %{"x" => 1}}

      payload = %Trace.EventDequeued{
        event: event,
        from: :external,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok,
              %Message{type: "trace.event_dequeued", macrostep: 1, microstep: 0, round: 0} =
                message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert message.payload["from"] == "external"
      assert message.payload["event"]["name"] == "go"
      assert message.payload["event"]["data"] == %{"x" => 1}
    end

    test "trace.transitions_selected" do
      payload = %Trace.TransitionsSelected{
        t_indexes: [0, 2],
        event: nil,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "trace.transitions_selected"} = message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert message.payload == %{"t_indexes" => [0, 2]}
    end

    test "trace.exit_set" do
      payload = %Trace.ExitSet{
        indexes: [3, 1],
        configuration: MapSet.new([0]),
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{type: "trace.exit_set", payload: %{"indexes" => [3, 1]}}} =
               Normalizer.normalize({:trace, payload}, @ctx)
    end

    test "trace.content_executed" do
      payload = %Trace.ContentExecuted{
        owner: {:onentry, 2, 0},
        c_indexes: [4, 5],
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{type: "trace.content_executed"} = message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert message.payload["c_indexes"] == [4, 5]

      assert message.payload["owner"] == %{
               "kind" => "onentry",
               "state_index" => 2,
               "ordinal" => 0
             }
    end

    test "trace.entry_set" do
      payload = %Trace.EntrySet{
        indexes: [2],
        configuration: MapSet.new([0, 2]),
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{type: "trace.entry_set", payload: %{"indexes" => [2]}}} =
               Normalizer.normalize({:trace, payload}, @ctx)
    end

    test "trace.macrostep_stable" do
      payload = %Trace.MacrostepStable{
        configuration: MapSet.new([2]),
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{type: "trace.macrostep_stable", payload: %{"configuration" => [2]}}} =
               Normalizer.normalize({:trace, payload}, @ctx)
    end

    test "trace.done" do
      payload = %Trace.Done{
        donedata: %{"result" => "ok"},
        configuration: MapSet.new([0]),
        macrostep: 3,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "trace.done"} = message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert message.payload == %{"donedata" => %{"result" => "ok"}, "configuration" => [0]}
    end

    test "trace.invoke_pass" do
      payload = %Trace.InvokePass{
        state_indexes: [1],
        invoke_ids: ["inv1"],
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{type: "trace.invoke_pass"} = message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert message.payload == %{"state_indexes" => [1], "invoke_ids" => ["inv1"]}
    end

    test "trace.finalize_autoforward" do
      event = %Event{name: "go", type: :external}

      payload = %Trace.FinalizeAutoforward{
        event: event,
        finalized: ["inv1"],
        forwarded: ["inv2"],
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{type: "trace.finalize_autoforward"} = message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert message.payload["finalized"] == ["inv1"]
      assert message.payload["forwarded"] == ["inv2"]
      assert message.payload["event"]["name"] == "go"
    end
  end

  describe "normalize/2 - the nine effect.* (core) effects" do
    test "effect.log" do
      payload = %Log{
        label: "hi",
        value: 1,
        c_index: 0,
        owner: {:transition, 0},
        macrostep: 1,
        microstep: 0,
        round: 2
      }

      assert {:ok, %Message{type: "effect.log", macrostep: 1, microstep: 0, round: 2} = message} =
               Normalizer.normalize({:log, payload}, @ctx)

      assert message.payload == %{
               "label" => "hi",
               "value" => 1,
               "c_index" => 0,
               "owner" => %{"kind" => "transition", "t_index" => 0}
             }
    end

    test "effect.done" do
      payload = %Done{
        donedata: nil,
        configuration: MapSet.new([0]),
        macrostep: 2,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "effect.done", round: 0} = message} =
               Normalizer.normalize({:done, payload}, @ctx)

      assert message.payload == %{"configuration" => [0]}
      refute Map.has_key?(message.payload, "donedata")
    end

    test "effect.budget_exhausted carries round, like every core effect since sui-67d" do
      pending = [%Event{name: "go", type: :internal}]

      payload = %BudgetExhausted{
        configuration: MapSet.new([1]),
        budget: 100,
        pending_internal_events: pending,
        macrostep: 1,
        microstep: 0,
        round: 3
      }

      assert {:ok, %Message{type: "effect.budget_exhausted", round: 3} = message} =
               Normalizer.normalize({:budget_exhausted, payload}, @ctx)

      assert message.payload["budget"] == 100
      assert message.payload["configuration"] == [1]
      assert [%{"name" => "go"}] = message.payload["pending_internal_events"]
    end

    test "effect.budget_exhausted renders an :infinity budget as the string \"infinity\"" do
      payload = %BudgetExhausted{
        configuration: MapSet.new([]),
        budget: :infinity,
        pending_internal_events: [],
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} =
               Normalizer.normalize({:budget_exhausted, payload}, @ctx)

      assert message.payload["budget"] == "infinity"
    end

    test "effect.invoke" do
      payload = %Invoke{
        invoke_id: "inv1",
        type: "scxml",
        src: "child.scxml",
        params: %{"a" => 1},
        content: nil,
        autoforward: true,
        state_index: 1,
        invoke_index: 0,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "effect.invoke", round: 0} = message} =
               Normalizer.normalize({:invoke, payload}, @ctx)

      assert message.payload["invoke_id"] == "inv1"
      assert message.payload["params"] == %{"a" => 1}
      refute Map.has_key?(message.payload, "content")
    end

    test "effect.cancel_invoke" do
      payload = %CancelInvoke{
        invoke_id: "inv1",
        state_index: 1,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "effect.cancel_invoke"} = message} =
               Normalizer.normalize({:cancel_invoke, payload}, @ctx)

      assert message.payload == %{"invoke_id" => "inv1", "state_index" => 1}
    end

    test "effect.autoforward" do
      event = %Event{name: "go", type: :external}

      payload = %Autoforward{
        invoke_id: "inv1",
        state_index: 1,
        event: event,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "effect.autoforward"} = message} =
               Normalizer.normalize({:autoforward, payload}, @ctx)

      assert message.payload["invoke_id"] == "inv1"
      assert message.payload["event"]["name"] == "go"
    end

    test "effect.send" do
      payload = %Send{
        event: "go",
        target: "#_internal",
        type: "scxml",
        data: %{"x" => 1},
        send_id: "send1",
        c_index: 0,
        owner: {:transition, 0},
        macrostep: 1,
        microstep: 0,
        id_from_author?: true,
        round: 0
      }

      assert {:ok, %Message{type: "effect.send", round: 0} = message} =
               Normalizer.normalize({:send, payload}, @ctx)

      assert message.payload["id_from_author"] == true
      assert message.payload["send_id"] == "send1"
      refute Map.has_key?(message.payload, "round")
    end

    test "effect.send_delayed carries every effect.send field plus delay_ms" do
      payload = %SendDelayed{
        event: "go",
        target: nil,
        type: nil,
        data: :undefined,
        send_id: "send1",
        delay_ms: 500,
        c_index: nil,
        owner: nil,
        macrostep: 1,
        microstep: 0,
        id_from_author?: false,
        round: 0,
        ordinal: 1
      }

      assert {:ok, %Message{type: "effect.send_delayed"} = message} =
               Normalizer.normalize({:send_delayed, payload}, @ctx)

      assert message.payload == %{
               "event" => "go",
               "send_id" => "send1",
               "id_from_author" => false,
               "delay_ms" => 500
             }
    end

    test "effect.cancel" do
      payload = %Cancel{
        send_id: "send1",
        c_index: 0,
        owner: {:transition, 0},
        macrostep: 1,
        microstep: 0,
        round: 0,
        ordinal: 1
      }

      assert {:ok, %Message{type: "effect.cancel"} = message} =
               Normalizer.normalize({:cancel, payload}, @ctx)

      assert message.payload["send_id"] == "send1"
      assert message.payload["owner"] == %{"kind" => "transition", "t_index" => 0}
    end
  end

  describe "normalize/2 - lifecycle messages" do
    test "{:halted, reason} produces session.halted with no counters" do
      for reason <- [:done, :cancelled, :budget_exhausted] do
        assert {:ok,
                %Message{type: "session.halted", macrostep: nil, microstep: nil, round: nil} =
                  message} =
                 Normalizer.normalize({:halted, reason}, @ctx)

        assert message.payload == %{"reason" => Atom.to_string(reason)}
      end
    end

    test "{:unroutable, effect} produces session.unroutable wrapping the effect under kind" do
      payload = %CancelInvoke{
        invoke_id: "inv1",
        state_index: 1,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "session.unroutable"} = message} =
               Normalizer.normalize({:unroutable, {:cancel_invoke, payload}}, @ctx)

      assert message.payload["effect"]["kind"] == "effect.cancel_invoke"
      assert message.payload["effect"]["invoke_id"] == "inv1"
    end

    test "{:effect, effect} unwraps to the same result as the bare effect" do
      payload = %CancelInvoke{
        invoke_id: "inv1",
        state_index: 1,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert Normalizer.normalize({:effect, {:cancel_invoke, payload}}, @ctx) ==
               Normalizer.normalize({:cancel_invoke, payload}, @ctx)
    end
  end

  describe "normalize/2 - trace.conds_evaluated" do
    # Built through new/2, never a struct literal: the payload module's
    # moduledoc makes that the contract, and it is what stamps the counters.
    defp conds_evaluated(evaluations) do
      Trace.CondsEvaluated.new(
        %Statifier.MachineState{
          configuration: MapSet.new(),
          machine: nil,
          macrostep: 1,
          microstep: 0,
          round: 0
        },
        evaluations: evaluations
      )
    end

    test "the three outcomes map to their lowercased names, reason only on error" do
      payload =
        conds_evaluated([
          %{t_index: 0, outcome: :disabled, reason: nil},
          %{t_index: 1, outcome: :enabled, reason: nil},
          %{t_index: 2, outcome: :error, reason: {:non_boolean_cond, "b"}}
        ])

      assert {:ok, %Message{type: "trace.conds_evaluated", macrostep: 1, round: 0} = message} =
               Normalizer.normalize({:trace, payload}, @ctx)

      assert [disabled, enabled, errored] = message.payload["evaluations"]

      # Absence, not a null: `reason` is omitted on both non-error outcomes.
      assert disabled == %{"t_index" => 0, "outcome" => "disabled"}
      assert enabled == %{"t_index" => 1, "outcome" => "enabled"}
      refute Map.has_key?(disabled, "reason")

      assert errored["t_index"] == 2
      assert errored["outcome"] == "error"
      assert errored["reason"]["class"] == "reason"
    end

    test "walk order is preserved, so the nth error entry stays the nth" do
      payload =
        conds_evaluated([
          %{t_index: 5, outcome: :error, reason: {:non_boolean_cond, "first"}},
          %{t_index: 3, outcome: :disabled, reason: nil},
          %{t_index: 9, outcome: :error, reason: {:non_boolean_cond, "second"}}
        ])

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)

      assert Enum.map(message.payload["evaluations"], & &1["t_index"]) == [5, 3, 9]

      assert message.payload["evaluations"]
             |> Enum.filter(&(&1["outcome"] == "error"))
             |> Enum.map(& &1["reason"]["reason"]) == [
               ~s({:non_boolean_cond, "first"}),
               ~s({:non_boolean_cond, "second"})
             ]
    end

    test "a non-boolean cond renders as ADR-0014's reason class" do
      payload = conds_evaluated([%{t_index: 0, outcome: :error, reason: {:non_boolean_cond, 42}}])

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      assert [%{"reason" => reason}] = message.payload["evaluations"]

      # `kind` is derived from the term's shape (ADR-0014 decision 2), not
      # from a table of engine tags this producer maintains.
      assert reason["class"] == "reason"
      assert reason["kind"] == "non_boolean_cond"
      assert reason["reason"] == "{:non_boolean_cond, 42}"
      refute Map.has_key?(reason, "expression")
    end

    test "an evaluator error renders as the expression class, not the reason class" do
      # The second shape `Selection.condition_match/2` produces for `reason`.
      # `StatifierUI.Trace.DiagnosticTest` covers this object's own arms
      # against real evaluator errors; what is under test here is that this
      # clause routes to it at all rather than rendering every reason term as
      # `class: "reason"`.
      error = %Statifier.Evaluator.Error{
        source: "amount < limit",
        error: %Predicator.Errors.UndefinedVariableError{
          message: "Undefined variable: limit",
          variable: "limit"
        },
        span: nil
      }

      payload = conds_evaluated([%{t_index: 0, outcome: :error, reason: error}])

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      assert [%{"reason" => reason}] = message.payload["evaluations"]

      assert reason["class"] == "expression"
      assert reason["kind"] == "undefined_variable"
      assert reason["expression"] == "amount < limit"

      # `reason` belongs to the other class and is never a sibling here.
      refute Map.has_key?(reason, "reason")
    end

    test "an unconsidered trace payload still refuses" do
      assert {:error, {:unknown_effect, {:trace, Statifier.Event}}} =
               Normalizer.normalize(
                 {:trace, %Statifier.Event{name: "not-a-trace-payload", type: :external}},
                 @ctx
               )
    end
  end

  describe "normalize/2 - unknown effects" do
    test "an unknown tag returns {:error, {:unknown_effect, tag}}" do
      assert Normalizer.normalize({:not_a_real_effect, %{}}, @ctx) ==
               {:error, {:unknown_effect, :not_a_real_effect}}
    end

    test "a trace payload of an unrecognized struct returns {:error, {:unknown_effect, _}}" do
      assert {:error, {:unknown_effect, {:trace, _struct}}} =
               Normalizer.normalize(
                 {:trace, %Statifier.Event{name: "not-a-trace-payload", type: :external}},
                 @ctx
               )
    end
  end

  describe "normalize/2 - origins (Event.Cause.origin/0's eight variants)" do
    origins = [
      {{:content, 3, {:transition, 0}},
       %{
         "kind" => "content",
         "c_index" => 3,
         "owner" => %{"kind" => "transition", "t_index" => 0}
       }},
      {{:state, 2}, %{"kind" => "state", "state_index" => 2}},
      {{:transition, 1}, %{"kind" => "transition", "t_index" => 1}},
      {{:data, 0}, %{"kind" => "data", "d_index" => 0}},
      {{:donedata_param, 1, 0},
       %{"kind" => "donedata_param", "state_index" => 1, "param_index" => 0}},
      {{:global_script, 0}, %{"kind" => "global_script", "index" => 0}},
      {{:invoke, 1, 0}, %{"kind" => "invoke", "state_index" => 1, "invoke_index" => 0}},
      {{:finalize, 1, 0}, %{"kind" => "finalize", "state_index" => 1, "invoke_index" => 0}}
    ]

    for {{origin, expected}, index} <- Enum.with_index(origins) do
      test "variant #{index}: #{inspect(origin)}" do
        origin = unquote(Macro.escape(origin))
        expected = unquote(Macro.escape(expected))

        cause = Cause.new(origin, 1, 0, 0)
        event = %Event{name: "internal.event", type: :internal, cause: cause}

        payload = %Trace.EventDequeued{
          event: event,
          from: :internal,
          macrostep: 1,
          microstep: 0,
          round: 0
        }

        assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
        assert message.payload["event"]["cause"]["origin"] == expected
      end
    end
  end

  describe "normalize/2 - owners (the five owner variants)" do
    owners = [
      {{:onentry, 2, 0}, %{"kind" => "onentry", "state_index" => 2, "ordinal" => 0}},
      {{:onexit, 2, 1}, %{"kind" => "onexit", "state_index" => 2, "ordinal" => 1}},
      {{:transition, 4}, %{"kind" => "transition", "t_index" => 4}},
      {{:finalize, 1, 0}, %{"kind" => "finalize", "state_index" => 1, "invoke_index" => 0}},
      {{:global_script, 0}, %{"kind" => "global_script", "index" => 0}}
    ]

    for {{owner, expected}, index} <- Enum.with_index(owners) do
      test "variant #{index}: #{inspect(owner)}" do
        owner = unquote(Macro.escape(owner))
        expected = unquote(Macro.escape(expected))

        payload = %Trace.ContentExecuted{
          owner: owner,
          c_indexes: [0],
          macrostep: 1,
          microstep: 0,
          round: 0
        }

        assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
        assert message.payload["owner"] == expected
      end
    end
  end

  describe "normalize/2 - the _event.data three-way" do
    test ":undefined omits the data key" do
      event = %Event{name: "go", type: :external, data: :undefined}

      payload = %Trace.EventDequeued{
        event: event,
        from: :external,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      refute Map.has_key?(message.payload["event"], "data")
    end

    test "nil is present as JSON null" do
      event = %Event{name: "go", type: :external, data: nil}

      payload = %Trace.EventDequeued{
        event: event,
        from: :external,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      assert Map.has_key?(message.payload["event"], "data")
      assert message.payload["event"]["data"] == nil
    end

    test "an empty map is present as {}" do
      event = %Event{name: "go", type: :external, data: %{}}

      payload = %Trace.EventDequeued{
        event: event,
        from: :external,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      assert message.payload["event"]["data"] == %{}
    end
  end

  describe "normalize/2 - trace.transitions_selected event presence marks eventless rounds" do
    test "event: nil omits the event key" do
      payload = %Trace.TransitionsSelected{
        t_indexes: [],
        event: nil,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      refute Map.has_key?(message.payload, "event")
    end

    test "an event includes the event key" do
      event = %Event{name: "go", type: :external}

      payload = %Trace.TransitionsSelected{
        t_indexes: [0],
        event: event,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      assert message.payload["event"]["name"] == "go"
    end
  end

  describe "normalize/2 - configuration and exit/entry ordering (decision 4)" do
    test "a MapSet configuration is emitted sorted ascending" do
      payload = %Trace.MacrostepStable{
        configuration: MapSet.new([5, 1, 3]),
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{payload: %{"configuration" => [1, 3, 5]}}} =
               Normalizer.normalize({:trace, payload}, @ctx)
    end

    test "exit_set indexes are emitted unsorted, in the engine's own emission order" do
      payload = %Trace.ExitSet{
        indexes: [4, 2, 9],
        configuration: MapSet.new([0]),
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{payload: %{"indexes" => [4, 2, 9]}}} =
               Normalizer.normalize({:trace, payload}, @ctx)
    end
  end

  describe "normalize/2 - Value.encode/1 is on the path" do
    test "a Date inside _event.data is encoded as {\"$date\": ...}" do
      event = %Event{name: "go", type: :external, data: %{"expires" => ~D[2026-08-16]}}

      payload = %Trace.EventDequeued{
        event: event,
        from: :external,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)
      assert message.payload["event"]["data"] == %{"expires" => %{"$date" => "2026-08-16"}}
    end
  end

  describe "normalize/2 - session.datamodel" do
    test "a datamodel map with :undefined and a nested host map encodes through Value.encode/1" do
      payload = %DatamodelInit{
        datamodel: %{
          "_sessionid" => "sess_probe",
          "_name" => :undefined,
          "x" => :undefined,
          "config" => %{"nested" => "value"}
        },
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok,
              %Message{
                type: "session.datamodel",
                macrostep: nil,
                microstep: nil,
                round: nil
              } = message} =
               Normalizer.normalize({:datamodel_init, payload}, @ctx)

      assert message.payload == %{
               "datamodel" => %{
                 "_sessionid" => "sess_probe",
                 "_name" => %{"$undefined" => true},
                 "x" => %{"$undefined" => true},
                 "config" => %{"nested" => "value"}
               }
             }
    end
  end

  describe "types/0" do
    test "returns exactly 25 sorted, unique type strings" do
      types = Normalizer.types()

      assert length(types) == 25
      assert Enum.uniq(types) == types
      assert Enum.sort(types) == types
      assert "session.datamodel" in types
      assert "effect.datamodel_change" in types
      assert "trace.conds_evaluated" in types
    end
  end

  describe "normalize/2 - effect.datamodel_change" do
    test "an <assign> write: c_index and owner, prior_value :undefined omits the key" do
      payload = %DatamodelChange{
        location_path: ["user", "items", 0, "name"],
        location_source: "user.items[i].name",
        new_value: "renamed",
        prior_value: :undefined,
        c_index: 3,
        owner: {:onentry, 1, 0},
        macrostep: 2,
        microstep: 1,
        round: 0
      }

      assert {:ok,
              %Message{
                type: "effect.datamodel_change",
                macrostep: 2,
                microstep: 1,
                round: 0
              } = message} = Normalizer.normalize({:datamodel_change, payload}, @ctx)

      assert message.payload == %{
               "location_path" => ["user", "items", 0, "name"],
               "location_source" => "user.items[i].name",
               "new_value" => "renamed",
               "c_index" => 3,
               "owner" => %{"kind" => "onentry", "state_index" => 1, "ordinal" => 0}
             }

      refute Map.has_key?(message.payload, "prior_value")
      refute Map.has_key?(message.payload, "d_index")
    end

    test "a <data> binding: d_index only, no c_index, no owner" do
      payload = %DatamodelChange{
        location_path: ["count"],
        location_source: "count",
        new_value: 42,
        prior_value: :undefined,
        d_index: 0,
        c_index: nil,
        owner: nil,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{type: "effect.datamodel_change"} = message} =
               Normalizer.normalize({:datamodel_change, payload}, @ctx)

      assert message.payload == %{
               "location_path" => ["count"],
               "location_source" => "count",
               "new_value" => 42,
               "d_index" => 0
             }
    end

    test "an <invoke idlocation> write: the widened invoke owner, no d_index/c_index" do
      payload = %DatamodelChange{
        location_path: ["inv_id"],
        location_source: "inv_id",
        new_value: "inv_1",
        prior_value: nil,
        c_index: nil,
        owner: {:invoke, 2, 0},
        macrostep: 1,
        microstep: 1,
        round: 0
      }

      assert {:ok, %Message{} = message} =
               Normalizer.normalize({:datamodel_change, payload}, @ctx)

      assert message.payload["owner"] == %{
               "kind" => "invoke",
               "state_index" => 2,
               "invoke_index" => 0
             }

      # A previously stored null is present as JSON null, distinct from the
      # omitted key an :undefined prior produces - the three-way rule.
      assert Map.fetch(message.payload, "prior_value") == {:ok, nil}
    end

    test "values go through the $-tagged codec" do
      payload = %DatamodelChange{
        location_path: ["when"],
        location_source: "when",
        new_value: ~D[2026-08-22],
        prior_value: [1, :undefined],
        c_index: 0,
        owner: {:transition, 0},
        macrostep: 2,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} =
               Normalizer.normalize({:datamodel_change, payload}, @ctx)

      assert message.payload["new_value"] == %{"$date" => "2026-08-22"}
      assert message.payload["prior_value"] == [1, %{"$undefined" => true}]
    end
  end

  describe "coverage - every {tag, payload_module} pair the engine can emit" do
    test "each pair normalizes to {:ok, _}" do
      for {tag, module} <- @coverage do
        struct_literal = maximal(tag, module)

        assert {:ok, %Message{}} = Normalizer.normalize({tag, struct_literal}, @ctx),
               "expected #{inspect({tag, module})} to normalize"
      end
    end

    test "each pair's produced payload keys equal the spec-documented key set for its type" do
      for {tag, module} <- @coverage do
        struct_literal = maximal(tag, module)

        assert {:ok, %Message{} = message} = Normalizer.normalize({tag, struct_literal}, @ctx)

        produced = message.payload |> Map.keys() |> MapSet.new()
        expected = expected_keys(tag, module)

        assert produced == expected,
               "#{inspect({tag, module})}: produced #{inspect(produced)}, expected #{inspect(expected)}"
      end
    end
  end

  # -- Coverage table fixtures ------------------------------------------------

  # Every optional field populated with a non-nil, non-:undefined value, so
  # normalizing it produces the type's full documented key set.
  defp maximal(:trace, Trace.EventDequeued) do
    %Trace.EventDequeued{
      event: %Event{name: "go", type: :external, data: 1},
      from: :external,
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:trace, Trace.TransitionsSelected) do
    %Trace.TransitionsSelected{
      t_indexes: [0],
      event: %Event{name: "go", type: :external},
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:trace, Trace.CondsEvaluated) do
    %Trace.CondsEvaluated{
      evaluations: [%{t_index: 0, outcome: :error, reason: {:non_boolean_cond, "b"}}],
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:trace, Trace.ExitSet) do
    %Trace.ExitSet{
      indexes: [1],
      configuration: MapSet.new([0]),
      macrostep: 1,
      microstep: 1,
      round: 0
    }
  end

  defp maximal(:trace, Trace.ContentExecuted) do
    %Trace.ContentExecuted{
      owner: {:transition, 0},
      c_indexes: [0],
      macrostep: 1,
      microstep: 1,
      round: 0
    }
  end

  defp maximal(:trace, Trace.EntrySet) do
    %Trace.EntrySet{
      indexes: [1],
      configuration: MapSet.new([0, 1]),
      macrostep: 1,
      microstep: 1,
      round: 0
    }
  end

  defp maximal(:trace, Trace.MacrostepStable) do
    %Trace.MacrostepStable{configuration: MapSet.new([1]), macrostep: 1, microstep: 1, round: 0}
  end

  defp maximal(:trace, Trace.Done) do
    %Trace.Done{donedata: 1, configuration: MapSet.new([0]), macrostep: 1, microstep: 0, round: 0}
  end

  defp maximal(:trace, Trace.InvokePass) do
    %Trace.InvokePass{
      state_indexes: [1],
      invoke_ids: ["inv1"],
      macrostep: 1,
      microstep: 1,
      round: 0
    }
  end

  defp maximal(:trace, Trace.FinalizeAutoforward) do
    %Trace.FinalizeAutoforward{
      event: %Event{name: "go", type: :external},
      finalized: ["inv1"],
      forwarded: ["inv2"],
      macrostep: 1,
      microstep: 1,
      round: 0
    }
  end

  defp maximal(:log, Log) do
    %Log{
      label: "hi",
      value: 1,
      c_index: 0,
      owner: {:transition, 0},
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:datamodel_change, DatamodelChange) do
    %DatamodelChange{
      location_path: ["items", 0, "name"],
      location_source: "items[0].name",
      new_value: "new",
      prior_value: "old",
      d_index: 0,
      c_index: 1,
      owner: {:transition, 0},
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:done, Done) do
    %Done{donedata: 1, configuration: MapSet.new([0]), macrostep: 1, microstep: 0, round: 0}
  end

  defp maximal(:budget_exhausted, BudgetExhausted) do
    %BudgetExhausted{
      configuration: MapSet.new([1]),
      budget: 10,
      pending_internal_events: [],
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:invoke, Invoke) do
    %Invoke{
      invoke_id: "inv1",
      type: "scxml",
      src: "child.scxml",
      params: %{"a" => 1},
      content: %{"b" => 2},
      autoforward: true,
      state_index: 1,
      invoke_index: 0,
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:cancel_invoke, CancelInvoke) do
    %CancelInvoke{invoke_id: "inv1", state_index: 1, macrostep: 1, microstep: 0, round: 0}
  end

  defp maximal(:autoforward, Autoforward) do
    %Autoforward{
      invoke_id: "inv1",
      state_index: 1,
      event: %Event{name: "go", type: :external},
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp maximal(:send, Send) do
    %Send{
      event: "go",
      target: "#_internal",
      type: "scxml",
      data: 1,
      send_id: "send1",
      c_index: 0,
      owner: {:transition, 0},
      macrostep: 1,
      microstep: 0,
      id_from_author?: true,
      round: 0
    }
  end

  defp maximal(:send_delayed, SendDelayed) do
    %SendDelayed{
      event: "go",
      target: "#_internal",
      type: "scxml",
      data: 1,
      send_id: "send1",
      delay_ms: 500,
      c_index: 0,
      owner: {:transition, 0},
      macrostep: 1,
      microstep: 0,
      id_from_author?: true,
      round: 0,
      ordinal: 1
    }
  end

  defp maximal(:cancel, Cancel) do
    %Cancel{
      send_id: "send1",
      c_index: 0,
      owner: {:transition, 0},
      macrostep: 1,
      microstep: 0,
      round: 0,
      ordinal: 1
    }
  end

  defp expected_keys(:trace, Trace.EventDequeued), do: MapSet.new(~w(event from))
  defp expected_keys(:trace, Trace.TransitionsSelected), do: MapSet.new(~w(t_indexes event))
  defp expected_keys(:trace, Trace.CondsEvaluated), do: MapSet.new(~w(evaluations))
  defp expected_keys(:trace, Trace.ExitSet), do: MapSet.new(~w(indexes))
  defp expected_keys(:trace, Trace.ContentExecuted), do: MapSet.new(~w(owner c_indexes))
  defp expected_keys(:trace, Trace.EntrySet), do: MapSet.new(~w(indexes))
  defp expected_keys(:trace, Trace.MacrostepStable), do: MapSet.new(~w(configuration))
  defp expected_keys(:trace, Trace.Done), do: MapSet.new(~w(donedata configuration))
  defp expected_keys(:trace, Trace.InvokePass), do: MapSet.new(~w(state_indexes invoke_ids))

  defp expected_keys(:trace, Trace.FinalizeAutoforward),
    do: MapSet.new(~w(event finalized forwarded))

  defp expected_keys(:log, Log), do: MapSet.new(~w(label value c_index owner))

  defp expected_keys(:datamodel_change, DatamodelChange),
    do: MapSet.new(~w(location_path location_source new_value prior_value d_index c_index owner))

  defp expected_keys(:done, Done), do: MapSet.new(~w(donedata configuration))

  defp expected_keys(:budget_exhausted, BudgetExhausted),
    do: MapSet.new(~w(configuration budget pending_internal_events))

  defp expected_keys(:invoke, Invoke),
    do:
      MapSet.new(
        ~w(invoke_id invoke_type src params content autoforward state_index invoke_index)
      )

  defp expected_keys(:cancel_invoke, CancelInvoke), do: MapSet.new(~w(invoke_id state_index))
  defp expected_keys(:autoforward, Autoforward), do: MapSet.new(~w(invoke_id state_index event))

  defp expected_keys(:send, Send),
    do: MapSet.new(~w(event target send_type data send_id id_from_author c_index owner))

  defp expected_keys(:send_delayed, SendDelayed),
    do: MapSet.new(~w(event target send_type data send_id id_from_author c_index owner delay_ms))

  defp expected_keys(:cancel, Cancel), do: MapSet.new(~w(send_id c_index owner))

  # -- Phase 2: %Evaluator.Error{} in Event.data --------------------------

  describe "normalize/2 - %Evaluator.Error{} in Event.data" do
    alias Statifier.Evaluator

    @evaluator_error %Evaluator.Error{
      source: "amount < limit",
      error: %Predicator.Errors.UndefinedVariableError{
        message: "Undefined variable: limit",
        variable: "limit"
      },
      span: {{1, 10}, {1, 15}}
    }

    test "produces an error key and no data key, with ctx carrying no machine/source" do
      event = %Event{name: "myapp:authorize", type: :internal, data: @evaluator_error}

      payload = %Trace.EventDequeued{
        event: event,
        from: :internal,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, @ctx)

      event_obj = message.payload["event"]
      assert event_obj["error"]["class"] == "expression"
      assert event_obj["error"]["kind"] == "undefined_variable"
      assert event_obj["error"]["expression"] == "amount < limit"

      assert event_obj["error"]["span"] == %{
               "start_line" => 1,
               "start_column" => 10,
               "end_line" => 1,
               "end_column" => 15
             }

      refute Map.has_key?(event_obj, "data")
      refute Map.has_key?(event_obj["error"], "location")
      refute Map.has_key?(event_obj["error"], "location_kind")
    end

    test "resolves an absolute location when ctx carries machine and source" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
          <datamodel><data id="amount" expr="100"/></datamodel>
          <state id="idle">
              <transition event="myapp:authorize" cond="amount &lt; limit" target="approved"/>
          </state>
          <state id="approved"/>
      </scxml>
      """

      {:ok, machine} = Statifier.compile(source)
      transition = Statifier.Machine.transition(machine, 0)

      context = Predicator.Context.new(%{"amount" => 100}, on_unbound: :error)
      {:error, %Evaluator.Error{} = error} = Evaluator.evaluate(context, transition.cond)

      cause = %Cause{origin: {:transition, 0}, macrostep: 1, microstep: 0, round: 0}
      event = %Event{name: "myapp:authorize", type: :internal, data: error, cause: cause}

      payload = %Trace.EventDequeued{
        event: event,
        from: :internal,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      ctx = Map.merge(@ctx, %{machine: machine, source: source})

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, ctx)

      event_obj = message.payload["event"]
      assert event_obj["error"]["location_kind"] == "resolved"

      assert %{"start_offset" => start_offset, "end_offset" => end_offset} =
               event_obj["error"]["location"]

      assert String.slice(source, start_offset, end_offset - start_offset) == "limit"
    end

    test "a nil span omits span and yields location_kind: node" do
      error = %Evaluator.Error{
        source: "boom",
        error: %Predicator.Errors.EvaluationError{message: "boom", reason: :boom},
        span: nil
      }

      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
          <state id="idle">
              <transition event="myapp:authorize" cond="true" target="approved"/>
          </state>
          <state id="approved"/>
      </scxml>
      """

      {:ok, machine} = Statifier.compile(source)
      cause = %Cause{origin: {:transition, 0}, macrostep: 1, microstep: 0, round: 0}
      event = %Event{name: "myapp:authorize", type: :internal, data: error, cause: cause}

      payload = %Trace.EventDequeued{
        event: event,
        from: :internal,
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      ctx = Map.merge(@ctx, %{machine: machine, source: source})

      assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, ctx)

      event_obj = message.payload["event"]
      refute Map.has_key?(event_obj["error"], "span")
      assert event_obj["error"]["location_kind"] == "node"
    end
  end

  # -- ADR-0014: a non-value reason term in an error.* event's data -------

  defp error_event(name, data, cause \\ nil) do
    %Trace.EventDequeued{
      event: %Event{name: name, type: :platform, data: data, cause: cause},
      from: :internal,
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp error_object(payload, ctx \\ @ctx) do
    assert {:ok, %Message{} = message} = Normalizer.normalize({:trace, payload}, ctx)
    message.payload["event"]
  end

  describe "normalize/2 - a reason term in an error.* event's data" do
    test "a tagged tuple renders as class reason, with the tag as kind" do
      event_obj = error_object(error_event("error.execution", {:not_iterable, 42}))

      assert event_obj["error"] == %{
               "class" => "reason",
               "kind" => "not_iterable",
               "reason" => "{:not_iterable, 42}"
             }

      refute Map.has_key?(event_obj, "data")
    end

    test "error.communication takes the identical shape - only the name differs" do
      execution = error_object(error_event("error.execution", {:unreachable_target, "#_bad"}))

      communication =
        error_object(error_event("error.communication", {:unreachable_target, "#_bad"}))

      assert execution["error"] == communication["error"]
      assert communication["error"]["kind"] == "unreachable_target"
    end

    test "a bare atom renders as itself" do
      event_obj = error_object(error_event("error.execution", :no_route))

      assert event_obj["error"]["kind"] == "no_route"
      assert event_obj["error"]["reason"] == ":no_route"
    end

    test "anything else renders as kind unknown, with the term inspected" do
      for term <- ["boom", 42, [1, 2], {"untagged", 1}, {}] do
        event_obj = error_object(error_event("error.execution", term))

        assert event_obj["error"]["kind"] == "unknown",
               "#{inspect(term)} should not have produced a tag"

        assert event_obj["error"]["reason"] == inspect(term)
      end
    end

    test "an :undefined data keeps the format's absence rule and produces no error object" do
      event_obj = error_object(error_event("error.execution", :undefined))

      refute Map.has_key?(event_obj, "error")
      refute Map.has_key?(event_obj, "data")
    end

    test "a term on any other event name is still a value, not a reason" do
      event_obj = error_object(error_event("myapp:authorize", "boom"))

      assert event_obj["data"] == "boom"
      refute Map.has_key?(event_obj, "error")
    end

    test "a wrapped %Evaluator.Error{} keeps its expression arm and gains content_path" do
      wrapped = {:nested_content, 2, {:nested_content, 5, @evaluator_error}}
      event_obj = error_object(error_event("error.execution", wrapped))

      assert event_obj["error"]["class"] == "expression"
      assert event_obj["error"]["kind"] == "undefined_variable"
      assert event_obj["error"]["expression"] == "amount < limit"
      assert event_obj["error"]["content_path"] == [2, 5]
    end

    test "a wrapped reason term keeps the reason arm and gains content_path" do
      wrapped = {:nested_content, 0, {:invalid_delay, "soon"}}
      event_obj = error_object(error_event("error.execution", wrapped))

      assert event_obj["error"]["class"] == "reason"
      assert event_obj["error"]["kind"] == "invalid_delay"
      assert event_obj["error"]["reason"] == "{:invalid_delay, \"soon\"}"
      assert event_obj["error"]["content_path"] == [0]
    end

    test "a direct %Evaluator.Error{} on an error.* event is the expression arm unchanged" do
      event_obj = error_object(error_event("error.execution", @evaluator_error))

      assert event_obj["error"]["class"] == "expression"
      refute Map.has_key?(event_obj["error"], "content_path")
      refute Map.has_key?(event_obj["error"], "reason")
    end

    test "the reason arm anchors on the owning node when ctx carries machine and source" do
      source = """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="predicator">
          <state id="idle">
              <onentry>
                  <foreach array="42" item="i">
                      <log expr="i"/>
                  </foreach>
              </onentry>
          </state>
      </scxml>
      """

      {:ok, machine} = Statifier.compile(source)

      cause = %Cause{
        origin: {:content, 0, {:onentry, 1, 0}},
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      ctx = Map.merge(@ctx, %{machine: machine, source: source})

      event_obj =
        error_object(error_event("error.execution", {:not_iterable, 42}, cause), ctx)

      assert event_obj["error"]["location_kind"] == "node"

      assert %{"start_offset" => start_offset, "end_offset" => end_offset} =
               event_obj["error"]["location"]

      assert String.slice(source, start_offset, end_offset - start_offset) =~ "<foreach"
    end

    test "the reason arm omits location when there is no machine or source" do
      cause = %Cause{
        origin: {:content, 0, {:onentry, 1, 0}},
        macrostep: 1,
        microstep: 0,
        round: 0
      }

      event_obj = error_object(error_event("error.execution", {:not_iterable, 42}, cause))

      refute Map.has_key?(event_obj["error"], "location")
      refute Map.has_key?(event_obj["error"], "location_kind")
    end
  end
end
