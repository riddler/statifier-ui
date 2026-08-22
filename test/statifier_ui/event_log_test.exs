defmodule StatifierUI.EventLogTest do
  use ExUnit.Case, async: true

  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.Macrostep
  alias StatifierUI.EventLog.Round
  alias StatifierUI.Trace.Message

  # The worked example, `docs/wire-format.md:775-791` - the two-state chart
  # driven by one external "go" event, transcribed as struct literals. Kept
  # as a module attribute so every describe block below exercises the same
  # fifteen messages.
  @worked_example [
    %Message{type: "session.start", session: "sess_golden", seq: 0, payload: %{"version" => 1}},
    %Message{type: "session.datamodel", session: "sess_golden", seq: 1, payload: %{}},
    %Message{
      type: "trace.entry_set",
      session: "sess_golden",
      seq: 2,
      macrostep: 1,
      microstep: 1,
      round: 0,
      payload: %{"indexes" => [0, 1]}
    },
    %Message{
      type: "trace.transitions_selected",
      session: "sess_golden",
      seq: 3,
      macrostep: 1,
      microstep: 1,
      round: 1,
      payload: %{"t_indexes" => []}
    },
    %Message{
      type: "trace.invoke_pass",
      session: "sess_golden",
      seq: 4,
      macrostep: 1,
      microstep: 1,
      round: 1,
      payload: %{"state_indexes" => [0, 1], "invoke_ids" => []}
    },
    %Message{
      type: "trace.macrostep_stable",
      session: "sess_golden",
      seq: 5,
      macrostep: 1,
      microstep: 1,
      round: 1,
      payload: %{"configuration" => [0, 1]}
    },
    %Message{
      type: "trace.event_dequeued",
      session: "sess_golden",
      seq: 6,
      macrostep: 2,
      microstep: 0,
      round: 0,
      payload: %{"event" => %{"name" => "go", "type" => "external"}, "from" => "external"}
    },
    %Message{
      type: "trace.finalize_autoforward",
      session: "sess_golden",
      seq: 7,
      macrostep: 2,
      microstep: 0,
      round: 0,
      payload: %{
        "event" => %{"name" => "go", "type" => "external"},
        "finalized" => [],
        "forwarded" => []
      }
    },
    %Message{
      type: "trace.transitions_selected",
      session: "sess_golden",
      seq: 8,
      macrostep: 2,
      microstep: 0,
      round: 0,
      payload: %{"event" => %{"name" => "go", "type" => "external"}, "t_indexes" => [0]}
    },
    %Message{
      type: "trace.exit_set",
      session: "sess_golden",
      seq: 9,
      macrostep: 2,
      microstep: 1,
      round: 0,
      payload: %{"indexes" => [1]}
    },
    %Message{
      type: "trace.content_executed",
      session: "sess_golden",
      seq: 10,
      macrostep: 2,
      microstep: 1,
      round: 0,
      payload: %{"owner" => %{"kind" => "transition", "t_index" => 0}, "c_indexes" => []}
    },
    %Message{
      type: "trace.entry_set",
      session: "sess_golden",
      seq: 11,
      macrostep: 2,
      microstep: 1,
      round: 0,
      payload: %{"indexes" => [2]}
    },
    %Message{
      type: "trace.transitions_selected",
      session: "sess_golden",
      seq: 12,
      macrostep: 2,
      microstep: 1,
      round: 1,
      payload: %{"t_indexes" => []}
    },
    %Message{
      type: "trace.invoke_pass",
      session: "sess_golden",
      seq: 13,
      macrostep: 2,
      microstep: 1,
      round: 1,
      payload: %{"state_indexes" => [2], "invoke_ids" => []}
    },
    %Message{
      type: "trace.macrostep_stable",
      session: "sess_golden",
      seq: 14,
      macrostep: 2,
      microstep: 1,
      round: 1,
      payload: %{"configuration" => [0, 2]}
    }
  ]

  describe "build/1 - the worked example" do
    setup do
      {:ok, log} = EventLog.build(@worked_example)
      %{log: log}
    end

    test "groups into two macrosteps", %{log: log} do
      assert [%Macrostep{macrostep: 1}, %Macrostep{macrostep: 2}] = log.macrosteps
    end

    test "macrostep 1 has rounds 0 and 1 and no dequeued event", %{log: log} do
      [macrostep_1, _macrostep_2] = log.macrosteps

      assert macrostep_1.event == nil
      assert [%Round{round: 0}, %Round{round: 1}] = macrostep_1.rounds
    end

    test "macrostep 2 round 0 carries the dequeue and its selection/exit/entry", %{log: log} do
      [_macrostep_1, macrostep_2] = log.macrosteps
      [round_0, _round_1] = macrostep_2.rounds

      assert round_0.event == %{"name" => "go", "type" => "external"}
      assert round_0.from == "external"
      assert round_0.t_indexes == [0]
      assert round_0.exited == [1]
      assert round_0.entered == [2]
    end

    test "macrostep 2 round 1 carries the quiescent configuration", %{log: log} do
      [_macrostep_1, macrostep_2] = log.macrosteps
      [_round_0, round_1] = macrostep_2.rounds

      assert round_1.configuration == [0, 2]
    end

    test "nothing is dropped", %{log: log} do
      counted =
        length(log.session_messages) +
          Enum.sum(Enum.map(log.macrosteps, &length(&1.effects))) +
          Enum.sum(
            Enum.map(log.macrosteps, fn macrostep ->
              Enum.sum(Enum.map(macrostep.rounds, &length(&1.messages)))
            end)
          )

      assert counted == length(@worked_example)
    end
  end

  describe "build/1 - shuffle invariance" do
    test "the same messages in any order fold to the same log" do
      {:ok, expected} = EventLog.build(@worked_example)

      for seed <- 1..5 do
        :rand.seed(:exsss, {seed, seed, seed})
        shuffled = Enum.shuffle(@worked_example)
        assert {:ok, ^expected} = EventLog.build(shuffled)
      end
    end
  end

  describe "build/1 - exit and entry order" do
    test "exit order is preserved, not sorted (ADR-0011)" do
      messages = [
        %Message{
          type: "trace.exit_set",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [3, 2, 1]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.exited == [3, 2, 1]
    end

    test "entry order is preserved, not sorted (ADR-0011)" do
      messages = [
        %Message{
          type: "trace.entry_set",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [5, 4, 6]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.entered == [5, 4, 6]
    end
  end

  describe "build/1 - rounds do not interleave across microsteps" do
    test "a round spanning two microsteps keeps both, in round order" do
      messages = [
        %Message{
          type: "trace.event_dequeued",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"event" => %{"name" => "go", "type" => "external"}, "from" => "external"}
        },
        %Message{
          type: "trace.exit_set",
          session: "s",
          seq: 1,
          macrostep: 1,
          microstep: 1,
          round: 0,
          payload: %{"indexes" => [1]}
        },
        %Message{
          type: "trace.transitions_selected",
          session: "s",
          seq: 2,
          macrostep: 1,
          microstep: 1,
          round: 1,
          payload: %{"t_indexes" => []}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps

      assert [%Round{round: 0} = round_0, %Round{round: 1}] = macrostep.rounds
      assert length(round_0.messages) == 2
    end

    test "a round-1 message stamped at a lower microstep than round 0 still lands in round 1" do
      # The engine may never emit this shape - see decision 1 in the plan -
      # but the model does not depend on microstep never decreasing as
      # round increases, because bucketing is by round, not a flat sort.
      messages = [
        %Message{
          type: "trace.exit_set",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 5,
          round: 0,
          payload: %{"indexes" => [1]}
        },
        %Message{
          type: "trace.entry_set",
          session: "s",
          seq: 1,
          macrostep: 1,
          microstep: 0,
          round: 1,
          payload: %{"indexes" => [2]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps

      assert [%Round{round: 0, exited: [1], entered: []}, %Round{round: 1, entered: [2]}] =
               macrostep.rounds
    end
  end

  describe "build/1 - t_indexes" do
    test "is nil when the round carries no trace.transitions_selected" do
      messages = [
        %Message{
          type: "trace.entry_set",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [1]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.t_indexes == nil
    end

    test "is an empty list when the message selected nothing" do
      messages = [
        %Message{
          type: "trace.transitions_selected",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"t_indexes" => []}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.t_indexes == []
    end
  end

  describe "build/1 - eventless?" do
    test "is true when trace.transitions_selected omits its event key" do
      messages = [
        %Message{
          type: "trace.transitions_selected",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"t_indexes" => []}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.eventless? == true
    end

    test "is false when trace.transitions_selected carries an event" do
      messages = [
        %Message{
          type: "trace.transitions_selected",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"event" => %{"name" => "go", "type" => "external"}, "t_indexes" => [0]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.eventless? == false
    end
  end

  describe "build/1 - cause hoisting" do
    test "an internal event's cause is hoisted to Round.cause" do
      cause = %{
        "origin" => %{"kind" => "transition", "t_index" => 0},
        "macrostep" => 1,
        "microstep" => 0,
        "round" => 0
      }

      messages = [
        %Message{
          type: "trace.event_dequeued",
          session: "s",
          seq: 0,
          macrostep: 2,
          microstep: 0,
          round: 0,
          payload: %{
            "event" => %{"name" => "internal", "type" => "internal", "cause" => cause},
            "from" => "internal"
          }
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.cause == cause
    end

    test "an external event with no cause hoists nil" do
      messages = [
        %Message{
          type: "trace.event_dequeued",
          session: "s",
          seq: 0,
          macrostep: 2,
          microstep: 0,
          round: 0,
          payload: %{"event" => %{"name" => "go", "type" => "external"}, "from" => "external"}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert round.cause == nil
    end
  end

  describe "build/1 - effect placement" do
    test "round-less effects land in Macrostep.effects in {microstep, seq} order" do
      messages = [
        %Message{
          type: "effect.send",
          session: "s",
          seq: 1,
          macrostep: 1,
          microstep: 1,
          payload: %{}
        },
        %Message{
          type: "effect.log",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          payload: %{}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps

      assert [%Message{type: "effect.log"}, %Message{type: "effect.send"}] = macrostep.effects
      assert macrostep.rounds == []
    end

    # Since sui-67d the live producer stamps `round` on every `effect.*`
    # message, so this is the live-stream shape; the round-less case above
    # remains what an older recorded stream looks like.
    test "a round-carrying effect lands in its round, not in Macrostep.effects" do
      messages = [
        %Message{
          type: "effect.log",
          session: "s",
          seq: 0,
          macrostep: 2,
          microstep: 1,
          round: 3,
          payload: %{"label" => "hi"}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert macrostep.effects == []
      assert round.round == 3
      assert [%Message{type: "effect.log"}] = round.messages
    end

    test "effect.budget_exhausted lands in its round, not in Macrostep.effects" do
      payload = %{
        "budget" => 10,
        "configuration" => [0, 1],
        "pending_internal_events" => []
      }

      messages = [
        %Message{
          type: "effect.budget_exhausted",
          session: "s",
          seq: 0,
          macrostep: 3,
          microstep: 4,
          round: 12,
          payload: payload
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps
      [round] = macrostep.rounds

      assert macrostep.effects == []
      assert round.round == 12
      assert round.budget_exhausted == payload
      assert round.configuration == nil
    end
  end

  describe "build/1 - multiple trace.macrostep_stable in one macrostep" do
    test "the macrostep's configuration is the later round's" do
      messages = [
        %Message{
          type: "trace.macrostep_stable",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"configuration" => [0, 1]}
        },
        %Message{
          type: "trace.macrostep_stable",
          session: "s",
          seq: 1,
          macrostep: 1,
          microstep: 1,
          round: 1,
          payload: %{"configuration" => [0, 2]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      [macrostep] = log.macrosteps

      assert macrostep.configuration == [0, 2]
    end
  end

  describe "build/1 - session_messages and truncated?" do
    test "session.* land in session_messages and truncated? is false at seq 0" do
      messages = [
        %Message{type: "session.start", session: "s", seq: 0, payload: %{}},
        %Message{type: "session.datamodel", session: "s", seq: 1, payload: %{}}
      ]

      {:ok, log} = EventLog.build(messages)

      assert length(log.session_messages) == 2
      assert log.macrosteps == []
      assert log.truncated? == false
    end

    test "a list starting above seq 0 is truncated" do
      messages = [
        %Message{type: "session.datamodel", session: "s", seq: 7, payload: %{}}
      ]

      {:ok, log} = EventLog.build(messages)

      assert log.truncated? == true
    end
  end

  describe "build/1 - mixed sessions" do
    test "returns a sorted mixed_sessions error" do
      messages = [
        %Message{type: "session.start", session: "b", seq: 0, payload: %{}},
        %Message{type: "session.start", session: "a", seq: 0, payload: %{}}
      ]

      assert EventLog.build(messages) == {:error, {:mixed_sessions, ["a", "b"]}}
    end
  end

  describe "build/1 - empty input" do
    test "returns an empty log" do
      assert {:ok, %EventLog{session: nil, macrosteps: [], session_messages: []}} =
               EventLog.build([])
    end
  end
end
