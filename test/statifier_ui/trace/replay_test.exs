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

  `recording/3`'s cases add a third chart, `@timed`, and a second kind of
  input: rows in a host's own storage shape rather than
  `t:Statifier.Session.Recording.entry/0` values taken straight back out of
  a live recording. Reconstructing those rows is what a host actually does
  (`docs/ops-embedding.md`'s mapping table), and the one row that has more
  than one plausible reading - a fired delayed send - is the reason "the
  timer rule" has its own cases.
  """

  use ExUnit.Case, async: true

  alias Statifier.Event
  alias Statifier.Send.Routes
  alias Statifier.Session
  alias Statifier.Session.Recording
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Projection
  alias StatifierUI.Trace.Replay
  alias StatifierUI.Trace.Subscriber

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

  # One delayed `<send>`, armed on entry, whose firing takes the chart out of
  # the state that armed it - so exactly one pending-timer credit exists for
  # the whole run and nothing re-arms it. That is what makes the credit
  # arithmetic in "the timer rule" below observable rather than incidental.
  @timed """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <onentry>
              <send id="t1" event="tick" delay="10ms"/>
          </onentry>
          <transition event="tick" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @minimal """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a"/>
  </scxml>
  """

  defp minimal_machine, do: SessionCase.compile!(@minimal)

  defp trace_opts(extra \\ []),
    do: Keyword.merge([session_id: "sess_offline", trace: true], extra)

  # The @timed run's whole stream: seq 0 through 16.
  @timed_full_seq 16
  @timed_session "sess_timer"

  defp timed_opts, do: [session_id: @timed_session, trace: true]

  # A host's own storage shape for the @timed run - one row per recorded
  # input, in serialized input order, carrying only what a column can hold.
  # `docs/ops-embedding.md`'s "From a persisted event log" is the table this
  # mirrors, and `"kind"` is the discriminator it maps on.
  defp timer_rows do
    [
      %{
        "kind" => "timer",
        "send_id" => "t1",
        "event" => "tick",
        "origin" => "#_scxml_#{@timed_session}",
        "origintype" => "http://www.w3.org/TR/scxml/#SCXMLEventProcessor"
      }
    ]
  end

  defp entry_from_row(%{"kind" => "timer"} = row),
    do: {:timer, row["send_id"], row_event(row), nil}

  defp entry_from_row(%{"kind" => "event"} = row),
    do: {:event, row_event(row), nil}

  defp row_event(row) do
    Event.external(row["event"],
      sendid: row["send_id"],
      origin: row["origin"],
      origintype: row["origintype"]
    )
  end

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

  describe "recording/3 over a host's own stored rows" do
    test "a stored log with one fired timer replays to the live session's trace" do
      machine = SessionCase.compile!(@timed)
      {:ok, sub} = Subscriber.start_link(machine: machine)

      {:ok, session} =
        Session.start_link(machine,
          trace: true,
          record: true,
          subscribers: [sub],
          session_id: "sess_timer"
        )

      :ok = Subscriber.attach(sub, session, subscribe: false)
      SessionCase.wait_for_seq(sub, @timed_full_seq)

      entries = Enum.map(timer_rows(), &entry_from_row/1)

      assert {:ok, recording} = Replay.recording(machine, timed_opts(), entries)
      assert Recording.entries(recording) == entries

      # The live session named the same firing the same way, over the same
      # event. Its route snapshot is the one that was in force; the host
      # stored `nil`, which means the session-start snapshot - the same set
      # here, and the streams below agree because of it.
      assert {:ok, live_recording} = Session.recording(session)
      assert [{:timer, "t1", live_event, %Routes{}}] = Recording.entries(live_recording)
      assert [{:timer, "t1", ^live_event, nil}] = entries

      assert {:ok, messages} = Replay.from_events(machine, timed_opts(), entries)
      assert Json.encode_lines(messages) == Json.encode_lines(Subscriber.messages(sub))
    end

    test "an unrecognized row shape is an error, not a skip" do
      assert Replay.recording(minimal_machine(), trace_opts(), [{:teleport, :somewhere}]) ==
               {:error, {:unknown_entry, {:teleport, :somewhere}}}
    end

    test "fails closed - a bad entry returns no partial recording" do
      entries = [{:event, Event.external("e"), nil}, {:teleport, :somewhere}]

      assert Replay.recording(minimal_machine(), trace_opts(), entries) ==
               {:error, {:unknown_entry, {:teleport, :somewhere}}}
    end

    test "checks :trace and :session_id nowhere - those are from_events/4's" do
      assert {:ok, recording} = Replay.recording(minimal_machine(), [], [])
      assert Recording.opts(recording)[:trace] == false
      assert Recording.opts(recording)[:session_id] == nil
    end
  end

  describe "the timer rule" do
    test "a fired timer draws the pending credit its {:timer, ...} name matches" do
      machine = SessionCase.compile!(@timed)
      [row] = timer_rows()
      fired = entry_from_row(row)

      # One `<send>` armed one credit, and the first firing spent it. A
      # second has nothing left to draw, which is the check the shape buys.
      assert Replay.from_events(machine, timed_opts(), [fired, fired]) ==
               {:error, {:unscheduled_timer_firing, "t1"}}
    end

    test "naming the same firing {:event, ...} leaves the credit outstanding" do
      machine = SessionCase.compile!(@timed)
      [row] = timer_rows()
      fired = entry_from_row(row)
      mislabelled = entry_from_row(Map.put(row, "kind", "event"))

      # Same delivered event, same position, and for a single firing the same
      # stream - so the divergence only shows once something else asks after
      # the credit. Here the second firing is accepted because the first never
      # spent it.
      assert {:ok, _messages} = Replay.from_events(machine, timed_opts(), [mislabelled, fired])
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
