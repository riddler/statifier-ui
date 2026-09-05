defmodule StatifierUI.Trace.ReplayTest do
  @moduledoc """
  ADR-0017's parity proof and its error paths.

  The round-trip case is the parity proof: the same two-state chart the
  `session.start` golden was captured over, run a second way - live with
  `record: true` - then replayed offline through `from_events/4`, encoded,
  and compared to `test/support/trace/two_state.jsonl` byte for byte. The
  live producer already compares against that same fixture in
  `StatifierUI.Trace.GoldenTraceTest`, so a divergence in either producer
  fails the same file. That shared fixture is what makes this a parity test
  rather than two independent goldens that can drift apart.

  The chart is deliberately the narrow one: no `<invoke>` and no
  `<send target="#_internal">`, which is what keeps the comparison a plain
  byte comparison rather than a `(macrostep, round)`-sorted one (ADR-0017's
  open question O-4 leaves widening it to whoever needs the coverage).
  """

  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Session
  alias Statifier.Session.Recording
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Projection
  alias StatifierUI.Trace.Replay

  doctest StatifierUI.Trace.Replay

  # Byte-identical to `StatifierUI.Trace.GoldenTraceTest`'s chart, including
  # the indentation: the fixture's source offsets were captured from it.
  @two_state """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @fixture_path Path.join([__DIR__, "..", "..", "support", "trace", "two_state.jsonl"])

  # A branching chart: statifier 2.5.0 emits a
  # `Statifier.Effect.Trace.CondsEvaluated` for the selection round that
  # evaluates `ready`, and ADR-0018 gave it `trace.conds_evaluated`, so the
  # golden below now carries that message rather than a gap where it was.
  # What this fixture proves is that the offline path produces the new type
  # exactly as the live one does - `sui-9fs` proved the path survives the
  # effect at all, and `StatifierUI.Trace.GoldenCondsEvaluatedTest` is where
  # the type's own three outcomes are captured.
  # Off `<invoke>` and `<send target="#_internal">` for the same reason the
  # two-state chart is: a plain byte comparison.
  @guarded """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <datamodel>
          <data id="ready" expr="true"/>
      </datamodel>
      <state id="a">
          <transition event="go" cond="ready" target="b"/>
          <transition event="go" target="c"/>
      </state>
      <state id="b"/>
      <state id="c"/>
  </scxml>
  """

  @guarded_fixture_path Path.join([__DIR__, "..", "..", "support", "trace", "guarded.jsonl"])

  @minimal """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a"/>
  </scxml>
  """

  defp minimal_machine, do: SessionCase.compile!(@minimal)

  defp trace_opts(extra \\ []),
    do: Keyword.merge([session_id: "sess_offline", trace: true], extra)

  describe "the round trip against the checked-in golden" do
    test "reproduces the live producer's stream byte-for-byte" do
      machine = SessionCase.compile!(@two_state)

      session = SessionCase.start_recorded!(machine, "sess_golden")
      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 1)

      {:ok, recording} = Session.recording(session)

      {:ok, messages} =
        Replay.from_events(
          Recording.machine(recording),
          Recording.opts(recording),
          Recording.entries(recording)
        )

      assert Json.encode_lines(messages) == File.read!(@fixture_path)
    end

    test "stamps seq from zero, contiguously, with session.start first" do
      machine = SessionCase.compile!(@two_state)

      session = SessionCase.start_recorded!(machine, "sess_golden")
      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 1)

      {:ok, recording} = Session.recording(session)

      {:ok, [manifest | rest]} =
        Replay.from_events(
          Recording.machine(recording),
          Recording.opts(recording),
          Recording.entries(recording)
        )

      assert %Message{type: "session.start", seq: 0, session: "sess_golden"} = manifest
      assert Enum.map(rest, & &1.seq) == Enum.to_list(1..length(rest))
      assert Enum.all?(rest, &(&1.session == "sess_golden"))

      # ADR-0017 decision 4: there is no process offline and no exit to
      # observe, so the offline stream never carries this type.
      refute Enum.any?(rest, &(&1.type == "session.terminated"))
    end
  end

  describe "a chart with a guarded transition" do
    test "round-trips against the checked-in golden byte-for-byte" do
      machine = SessionCase.compile!(@guarded)

      session = SessionCase.start_recorded!(machine, "sess_guarded")
      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 1)

      {:ok, recording} = Session.recording(session)

      assert {:ok, messages} =
               Replay.from_events(
                 Recording.machine(recording),
                 Recording.opts(recording),
                 Recording.entries(recording)
               )

      assert Json.encode_lines(messages) == File.read!(@guarded_fixture_path)
    end

    test "maps the guard-evaluation effect, offline, into the same message the live producer emits" do
      machine = SessionCase.compile!(@guarded)

      session = SessionCase.start_recorded!(machine, "sess_guarded")
      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 1)

      {:ok, recording} = Session.recording(session)

      assert {:ok, [manifest | rest]} =
               Replay.from_events(
                 Recording.machine(recording),
                 Recording.opts(recording),
                 Recording.entries(recording)
               )

      assert %Message{type: "session.start", seq: 0} = manifest
      assert Enum.map(rest, & &1.seq) == Enum.to_list(1..length(rest))

      # The guard fired - the chart really did take the cond'd transition -
      # and the round that evaluated `ready` reports it, which is the whole
      # point of ADR-0018. The offline producer consumes a `seq` for it, so
      # the message is not a rendering detail of the live path.
      assert Enum.any?(rest, &(&1.type == "trace.entry_set"))

      assert [%Message{payload: %{"evaluations" => evaluations}}] =
               Enum.filter(rest, &(&1.type == "trace.conds_evaluated"))

      assert evaluations == [%{"t_index" => 0, "outcome" => "enabled"}]
    end
  end

  describe "initialize_opts" do
    test "an absent :trace flag is an error, not a silently trace-free stream" do
      assert Replay.from_events(minimal_machine(), [session_id: "s"], []) ==
               {:error, {:initialize_opts, :trace_disabled}}
    end

    test "an explicitly false :trace flag is the same error" do
      assert Replay.from_events(minimal_machine(), [session_id: "s", trace: false], []) ==
               {:error, {:initialize_opts, :trace_disabled}}
    end

    test "a missing :session_id is an error" do
      assert Replay.from_events(minimal_machine(), [trace: true], []) ==
               {:error, {:initialize_opts, :missing_session_id}}
    end

    test "a non-binary :session_id is the same error" do
      assert Replay.from_events(minimal_machine(), [session_id: :s, trace: true], []) ==
               {:error, {:initialize_opts, :missing_session_id}}
    end
  end

  describe "the entry fold" do
    test "accepts every Recording.entry/0 shape" do
      machine = minimal_machine()
      origin = {:state, 0}

      entries = [
        {:event, Event.external("e"), nil},
        {:invoked_event, "inv_1", Event.external("e"), nil},
        {:interpret, [], nil},
        {:internal, :internal, "raised", origin, [], nil},
        {:internal, :platform, "error.execution", origin, [], nil},
        {:cancel, nil}
      ]

      assert {:ok, messages} = Replay.from_events(machine, trace_opts(), entries)
      assert Enum.any?(messages, &(&1.type == "session.halted"))
    end

    test "a timer entry is accepted and its upstream error is passed through" do
      entries = [{:timer, "send_1", Event.external("tick"), nil}]

      assert Replay.from_events(minimal_machine(), trace_opts(), entries) ==
               {:error, {:unscheduled_timer_firing, "send_1"}}
    end

    test "an unrecognized entry shape is an error, not a skip" do
      assert Replay.from_events(minimal_machine(), trace_opts(), [{:teleport, :somewhere}]) ==
               {:error, {:unknown_entry, {:teleport, :somewhere}}}
    end

    test "fails closed - a bad entry returns no partial list" do
      entries = [{:event, Event.external("e"), nil}, {:teleport, :somewhere}]

      assert {:error, {:unknown_entry, _}} =
               Replay.from_events(minimal_machine(), trace_opts(), entries)
    end
  end

  describe "opts" do
    test "forwards the manifest options verbatim" do
      opts = [
        source: @minimal,
        fixtures: %{"k" => "v"},
        parent_session: "sess_parent",
        invokeid: "inv_1"
      ]

      assert {:ok, [manifest | _]} =
               Replay.from_events(minimal_machine(), trace_opts(), [], opts)

      assert manifest.payload["source"] == @minimal
      assert manifest.payload["fixtures"] == %{"k" => "v"}
      assert manifest.payload["parent_session"] == "sess_parent"
      assert manifest.payload["invokeid"] == "inv_1"
    end

    test "surfaces a manifest build failure as an error value" do
      assert Replay.from_events(minimal_machine(), trace_opts(), [], fixtures: :not_a_map) ==
               {:error, {:invalid_fixtures, :not_a_map}}
    end

    test "applies the projection profile" do
      {:ok, profile} = Projection.profile("strict", allow_source: false)

      assert {:ok, [manifest | _]} =
               Replay.from_events(minimal_machine(), trace_opts(), [],
                 source: @minimal,
                 projection: profile
               )

      assert manifest.payload["source"] == %{"$redacted" => true}
      assert manifest.payload["projection"] == %{"mode" => "projected", "profile" => "strict"}
    end

    test "stamps otel before projecting, so the key survives a profile" do
      {:ok, profile} = Projection.profile("strict", allow_source: false)
      trace_id = String.duplicate("a", 32)
      span_id = String.duplicate("b", 16)
      resolver = fn _session, _macrostep -> {:ok, %{trace_id: trace_id, span_id: span_id}} end

      assert {:ok, messages} =
               Replay.from_events(minimal_machine(), trace_opts(), [],
                 projection: profile,
                 otel_context: resolver
               )

      stamped = Enum.filter(messages, &(&1.otel != nil))

      assert stamped != []
      assert Enum.all?(stamped, &(&1.otel == %{"trace_id" => trace_id, "span_id" => span_id}))
      assert Enum.all?(stamped, &String.starts_with?(&1.type, "trace."))
    end
  end
end
