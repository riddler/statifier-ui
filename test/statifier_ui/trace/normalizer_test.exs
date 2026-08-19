defmodule StatifierUI.Trace.NormalizerTest do
  use ExUnit.Case, async: true

  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
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

  # The eighteen {tag, payload_module} pairs the engine can emit today
  # (nine trace payloads, nine core effects) - the table Success Criteria
  # names, so a payload module added upstream and not handled here fails
  # the first assertion below, and a field dropped from a payload fails the
  # second.
  @coverage [
    {:trace, Trace.EventDequeued},
    {:trace, Trace.TransitionsSelected},
    {:trace, Trace.ExitSet},
    {:trace, Trace.ContentExecuted},
    {:trace, Trace.EntrySet},
    {:trace, Trace.MacrostepStable},
    {:trace, Trace.Done},
    {:trace, Trace.InvokePass},
    {:trace, Trace.FinalizeAutoforward},
    {:log, Log},
    {:done, Done},
    {:budget_exhausted, BudgetExhausted},
    {:invoke, Invoke},
    {:cancel_invoke, CancelInvoke},
    {:autoforward, Autoforward},
    {:send, Send},
    {:send_delayed, SendDelayed},
    {:cancel, Cancel}
  ]

  describe "normalize/2 - the nine trace.* effects" do
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
        round: 0
      }

      assert {:ok, %Message{type: "effect.log", macrostep: 1, microstep: 0, round: nil} = message} =
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

      assert {:ok, %Message{type: "effect.done", round: nil} = message} =
               Normalizer.normalize({:done, payload}, @ctx)

      assert message.payload == %{"configuration" => [0]}
      refute Map.has_key?(message.payload, "donedata")
    end

    test "effect.budget_exhausted carries round, unlike every other core effect" do
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

      assert {:ok, %Message{type: "effect.invoke", round: nil} = message} =
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

      assert {:ok, %Message{type: "effect.send", round: nil} = message} =
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
        round: 0
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
        round: 0
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
    test "returns exactly 23 sorted, unique type strings" do
      types = Normalizer.types()

      assert length(types) == 23
      assert Enum.uniq(types) == types
      assert Enum.sort(types) == types
      assert "session.datamodel" in types
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
      round: 0
    }
  end

  defp maximal(:cancel, Cancel) do
    %Cancel{
      send_id: "send1",
      c_index: 0,
      owner: {:transition, 0},
      macrostep: 1,
      microstep: 0,
      round: 0
    }
  end

  defp expected_keys(:trace, Trace.EventDequeued), do: MapSet.new(~w(event from))
  defp expected_keys(:trace, Trace.TransitionsSelected), do: MapSet.new(~w(t_indexes event))
  defp expected_keys(:trace, Trace.ExitSet), do: MapSet.new(~w(indexes))
  defp expected_keys(:trace, Trace.ContentExecuted), do: MapSet.new(~w(owner c_indexes))
  defp expected_keys(:trace, Trace.EntrySet), do: MapSet.new(~w(indexes))
  defp expected_keys(:trace, Trace.MacrostepStable), do: MapSet.new(~w(configuration))
  defp expected_keys(:trace, Trace.Done), do: MapSet.new(~w(donedata configuration))
  defp expected_keys(:trace, Trace.InvokePass), do: MapSet.new(~w(state_indexes invoke_ids))

  defp expected_keys(:trace, Trace.FinalizeAutoforward),
    do: MapSet.new(~w(event finalized forwarded))

  defp expected_keys(:log, Log), do: MapSet.new(~w(label value c_index owner))
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
end
