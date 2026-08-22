defmodule StatifierUI.Trace.SubscriberTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Statifier.Effect.Log
  alias Statifier.Session
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Normalizer
  alias StatifierUI.Trace.Subscriber

  # Two states, one external transition - the same chart the golden trace
  # test and docs/wire-format.md's worked example use. `xmlns` and
  # `version` are required on the root element (`Statifier.Validator`).
  @two_state """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # 15 messages total for @two_state driven with one "go": seq 0
  # (session.start) through seq 14 (the driven macrostep's
  # trace.macrostep_stable) - see docs/wire-format.md's worked example. seq 1
  # is session.datamodel, emitted unconditionally on every initialize/2
  # (st-1xwh).
  @full_seq 15

  defp drive_and_wait(sub, session, target \\ @full_seq) do
    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, target)
  end

  describe "attach paths" do
    test "early attach sees the initialize burst; late attach does not, and records :late_attach" do
      machine = SessionCase.compile!(@two_state)

      {early_sub, early_session} = SessionCase.start_early!(machine, "sess_early")
      drive_and_wait(early_sub, early_session)
      early_messages = Subscriber.messages(early_sub)

      # session.datamodel is emitted unconditionally right after the seq: 0
      # manifest (st-1xwh). The initialize burst then enters "a" (state
      # index 1) before any event is driven - its trace.entry_set carries
      # indexes [0, 1] (the synthesized root is always a member) at seq 2.
      assert [
               %{type: "session.start", seq: 0},
               %{type: "session.datamodel", seq: 1},
               %{type: "trace.entry_set", seq: 2} = burst | _
             ] = early_messages

      assert burst.payload["indexes"] == [0, 1]

      assert Subscriber.stats(early_sub).diagnostics == []

      {late_sub, late_session} = SessionCase.start_late!(machine, "sess_late")
      drive_and_wait(late_sub, late_session)
      late_messages = Subscriber.messages(late_sub)

      # A late attach never sees the initial macrostep's entry_set for
      # state "a" (indexes [0, 1]) - only the driven event's entry_set for
      # "b" (indexes [2]) shows up.
      entry_sets = Enum.filter(late_messages, &(&1.type == "trace.entry_set"))
      assert Enum.all?(entry_sets, &(&1.payload["indexes"] != [0, 1]))
      assert Enum.any?(entry_sets, &(&1.payload["indexes"] == [2]))

      assert [%{kind: :late_attach}] = Subscriber.stats(late_sub).diagnostics
    end
  end

  describe "catch-up attach (statifier ADR-0049)" do
    test "reconstructs the full stream after the fact - prefix, then live suffix" do
      machine = SessionCase.compile!(@two_state)
      session = SessionCase.start_recorded!(machine, "sess_catch_up")

      # Drive the transition BEFORE any subscriber exists, and wait until
      # the session has fully processed it (the driven macrostep is 2).
      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 2)

      sub = SessionCase.attach_catch_up!(machine, session)

      # The replayed prefix is available synchronously - attach/3 folds it
      # into the buffer inside its own call.
      messages = Subscriber.messages(sub)
      assert length(messages) == @full_seq
      assert Enum.map(messages, & &1.seq) == Enum.to_list(0..(@full_seq - 1))

      # The initialize burst a plain late attach can never see is present.
      assert [
               %{type: "session.start", seq: 0},
               %{type: "session.datamodel", seq: 1},
               %{type: "trace.entry_set", seq: 2} = burst | _
             ] = messages

      assert burst.payload["indexes"] == [0, 1]

      # No :late_attach diagnostic - this stream is whole.
      assert Subscriber.stats(sub).diagnostics == []

      # The live suffix continues seamlessly: nothing more to transition
      # to, but the dequeue itself is notified and lands after the prefix.
      Session.send_event(session, "go")
      stats = SessionCase.wait_for_seq(sub, @full_seq + 1)
      assert stats.seq > @full_seq
      seqs = Enum.map(Subscriber.messages(sub), & &1.seq)
      assert seqs == Enum.to_list(0..(length(seqs) - 1))
    end

    test "an unrecorded session falls back to live-only with a :not_recorded diagnostic" do
      machine = SessionCase.compile!(@two_state)
      {:ok, session} = Session.start_link(machine, trace: true, session_id: "sess_unrecorded")

      {:ok, sub} = Subscriber.start_link(machine: machine)
      :ok = Subscriber.attach(sub, session, catch_up: true)

      assert [%{kind: :not_recorded}] = Subscriber.stats(sub).diagnostics

      # The fallback did subscribe live: a driven event still arrives, but
      # the initialize burst stays missing - exactly the late-attach shape.
      Session.send_event(session, "go")
      SessionCase.wait_until(sub, 1000, fn stats -> stats.seq > 0 end)

      entry_sets =
        Enum.filter(Subscriber.messages(sub), &(&1.type == "trace.entry_set"))

      assert Enum.all?(entry_sets, &(&1.payload["indexes"] != [0, 1]))
      assert Enum.any?(entry_sets, &(&1.payload["indexes"] == [2]))
    end

    test "catch-up attach monitors the session: a kill still yields session.terminated" do
      machine = SessionCase.compile!(@two_state)
      session = SessionCase.start_recorded!(machine, "sess_catch_up_down")
      SessionCase.wait_for_macrostep(session, 1)

      sub = SessionCase.attach_catch_up!(machine, session)

      Process.unlink(session)
      Process.exit(session, :kill)

      stats = SessionCase.wait_until(sub, 1000, fn stats -> stats.status == :terminated end)
      assert stats.status == :terminated
      assert List.last(Subscriber.messages(sub)).type == "session.terminated"
    end
  end

  describe "seq stamping" do
    test "session.start is seq 0, the first effect is seq 1, and seq is monotone with no gaps" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_seq")
      drive_and_wait(sub, session)

      messages = Subscriber.messages(sub)
      assert length(messages) == @full_seq
      assert Enum.map(messages, & &1.seq) == Enum.to_list(0..(@full_seq - 1))
      assert hd(messages).type == "session.start"
      assert hd(messages).seq == 0
      assert Enum.at(messages, 1).seq == 1
    end
  end

  describe "capacity overflow" do
    test "drops oldest and leaves a seq gap plus a non-zero dropped count" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_overflow", capacity: 2)
      drive_and_wait(sub, session)

      stats = Subscriber.stats(sub)
      assert stats.dropped > 0
      assert stats.buffered == 2

      messages = Subscriber.messages(sub)
      assert length(messages) == 2
      # The buffer kept the tail; its first entry's seq is not 0, which is
      # how a consumer detects loss without a synthetic drop message.
      assert hd(messages).seq > 0
    end
  end

  describe "listeners" do
    test "receive {:statifier_ui, session_id, %Message{}} in order" do
      machine = SessionCase.compile!(@two_state)

      {:ok, sub} =
        Subscriber.start_link(machine: machine, listeners: [self()])

      {:ok, session} =
        Session.start_link(machine, trace: true, subscribers: [sub], session_id: "sess_listen")

      :ok = Subscriber.attach(sub, session, subscribe: false)
      drive_and_wait(sub, session)

      received = collect_listener_messages("sess_listen", @full_seq)
      assert Enum.map(received, & &1.seq) == Enum.to_list(0..(@full_seq - 1))
    end

    test "add_listener/2 mid-stream receives only subsequent messages" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_mid_listen")

      # The initialize burst (seq 0..5) has already flowed by the time this
      # returns true - nobody is listening yet.
      SessionCase.wait_for_seq(sub, 6)

      :ok = Subscriber.add_listener(sub, self())
      drive_and_wait(sub, session)

      received = collect_listener_messages("sess_mid_listen", @full_seq - 6)
      assert Enum.all?(received, &(&1.seq >= 6))
    end

    test "remove_listener/2 stops delivery to that pid" do
      machine = SessionCase.compile!(@two_state)

      # The listener is registered at start_link time, not via
      # add_listener/2: an add_listener call races the initialize burst's
      # delivery into the subscriber's mailbox (different senders, no
      # ordering guarantee), so the listener could catch a stray burst
      # message and trip the refutation below (sui-hmm).
      {sub, session} =
        SessionCase.start_early!(machine, "sess_remove_listen", listeners: [self()])

      # Delivery is live before removal: the whole burst arrives here.
      SessionCase.wait_for_seq(sub, 6)
      received = collect_listener_messages("sess_remove_listen", 6)
      assert Enum.map(received, & &1.seq) == Enum.to_list(0..5)

      # remove_listener/2 is synchronous and the driven event is sent only
      # after it returns, so every subsequent message is fanned out to an
      # already-empty listener set.
      :ok = Subscriber.remove_listener(sub, self())

      drive_and_wait(sub, session)

      # drive_and_wait's final stats call returned after the subscriber
      # processed the last message; any fan-out it did was sent before that
      # reply, so an unwanted message would already be in this mailbox.
      refute_received {:statifier_ui, "sess_remove_listen", _message}
    end
  end

  describe "detach/1" do
    test "stops delivery and keeps the buffer" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_detach")
      SessionCase.wait_for_seq(sub, 5)

      :ok = Subscriber.detach(sub)
      assert Subscriber.stats(sub).status == :detached
      buffered_before = Subscriber.messages(sub)

      Session.send_event(session, "go")
      Process.sleep(100)

      assert Subscriber.messages(sub) == buffered_before
    end
  end

  describe "session termination" do
    test "a killed session yields session.terminated, status :terminated, and a readable buffer" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_kill")
      drive_and_wait(sub, session)

      # Session.start_link/2 links the caller (this test process); unlink
      # first so the untrappable :kill signal does not also crash the test.
      Process.unlink(session)
      Process.exit(session, :kill)

      stats =
        SessionCase.wait_until(sub, 1000, fn stats -> stats.status == :terminated end)

      assert stats.status == :terminated

      messages = Subscriber.messages(sub)
      assert messages != []
      assert %{type: "session.terminated", payload: %{"reason" => reason}} = List.last(messages)
      assert is_binary(reason)
    end
  end

  describe "the st-r6l9 regression: trace effects after {:halted, :done}" do
    test "a message arriving after :halted is still normalized and buffered" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_halt")
      drive_and_wait(sub, session)

      session_id = Subscriber.stats(sub).session
      before_seq = Subscriber.stats(sub).seq

      send(sub, {:statifier, session_id, {:halted, :done}})

      late_effect =
        {:log, %Log{label: "after-halt", macrostep: 99, microstep: 0, round: 0}}

      send(sub, {:statifier, session_id, {:effect, late_effect}})

      SessionCase.wait_for_seq(sub, before_seq + 2)

      messages = Subscriber.messages(sub)
      assert Enum.any?(messages, &(&1.type == "session.halted"))

      assert Enum.any?(
               messages,
               &(&1.type == "effect.log" and &1.payload["label"] == "after-halt")
             )

      # And the subscriber kept running, not just kept the buffer.
      assert Subscriber.stats(sub).status == :attached
    end
  end

  describe "foreign session ids" do
    test "a message from a different session id is counted and ignored" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_foreign")
      drive_and_wait(sub, session)

      seq_before = Subscriber.stats(sub).seq

      late_effect = {:log, %Log{label: "foreign", macrostep: 1, microstep: 0, round: 0}}
      send(sub, {:statifier, "some_other_session", {:effect, late_effect}})

      SessionCase.wait_until(sub, 500, fn stats -> stats.foreign == 1 end)

      stats = Subscriber.stats(sub)
      assert stats.foreign == 1
      assert stats.seq == seq_before
      refute Enum.any?(Subscriber.messages(sub), &(&1.payload["label"] == "foreign"))
    end
  end

  describe "Manifest.build/3 failure" do
    test "a bad fixtures option skips the manifest but leaves the trace flowing" do
      machine = SessionCase.compile!(@two_state)

      {sub, session} =
        SessionCase.start_early!(machine, "sess_bad_manifest", fixtures: "not a map")

      drive_and_wait(sub, session, @full_seq - 1)

      messages = Subscriber.messages(sub)
      refute Enum.any?(messages, &(&1.type == "session.start"))
      assert Enum.any?(messages, &(&1.type == "trace.entry_set"))

      stats = Subscriber.stats(sub)
      assert Enum.any?(stats.diagnostics, &(&1.kind == :manifest_build_failed))
    end
  end

  describe "the three constructed lifecycle types are real wire types" do
    test "session.halted, session.terminated, and session.unroutable are all in Normalizer.types/0" do
      types = Normalizer.types()
      assert "session.halted" in types
      assert "session.terminated" in types
      assert "session.unroutable" in types
    end
  end

  describe "normalize errors" do
    # A pid occupies a value position (`Log.value`) but is outside
    # `StatifierUI.Value.encode/1`'s closed value domain (ADR-0005), so it
    # is rejected with `{:error, {:unsupported_value, term}}` rather than
    # passed through - sui-qlf. That makes it reachable here.
    defp out_of_domain_log(label, macrostep) do
      {:log, %Log{label: label, value: self(), macrostep: macrostep, microstep: 0, round: 0}}
    end

    test "an out-of-domain value drives stats.errors up through a live subscriber" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_normalize_error")
      drive_and_wait(sub, session)

      session_id = Subscriber.stats(sub).session
      before_seq = Subscriber.stats(sub).seq

      capture_log(fn ->
        send(sub, {:statifier, session_id, {:effect, out_of_domain_log("bad", 99)}})
        SessionCase.wait_until(sub, 500, fn stats -> stats.errors == 1 end)
      end)

      assert Subscriber.stats(sub).errors == 1
      # The failed effect is never buffered - seq does not advance for it.
      assert Subscriber.stats(sub).seq == before_seq
    end

    test "a repeated identical reason logs exactly once but counts every occurrence" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_normalize_dedup")
      drive_and_wait(sub, session)

      session_id = Subscriber.stats(sub).session

      log =
        capture_log(fn ->
          send(sub, {:statifier, session_id, {:effect, out_of_domain_log("dup", 99)}})
          SessionCase.wait_until(sub, 500, fn stats -> stats.errors == 1 end)

          send(sub, {:statifier, session_id, {:effect, out_of_domain_log("dup", 99)}})
          SessionCase.wait_until(sub, 500, fn stats -> stats.errors == 2 end)
        end)

      assert Subscriber.stats(sub).errors == 2

      occurrences =
        log
        |> String.split("\n")
        |> Enum.count(&(&1 =~ "normalize error"))

      assert occurrences == 1
    end

    test "the warning names the effect tag and the reason" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_normalize_tag")
      drive_and_wait(sub, session)

      session_id = Subscriber.stats(sub).session

      log =
        capture_log(fn ->
          send(sub, {:statifier, session_id, {:effect, out_of_domain_log("tagged", 99)}})
          SessionCase.wait_until(sub, 500, fn stats -> stats.errors == 1 end)
        end)

      assert log =~ "normalize error on log:"
      assert log =~ "unsupported_value"
    end

    test "the subscriber survives a normalize error and keeps normalizing subsequent messages" do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_normalize_survives")
      drive_and_wait(sub, session)

      session_id = Subscriber.stats(sub).session
      before_seq = Subscriber.stats(sub).seq

      capture_log(fn ->
        send(sub, {:statifier, session_id, {:effect, out_of_domain_log("boom", 99)}})
        SessionCase.wait_until(sub, 500, fn stats -> stats.errors == 1 end)
      end)

      good_effect =
        {:log, %Log{label: "still-alive", value: "ok", macrostep: 99, microstep: 0, round: 0}}

      send(sub, {:statifier, session_id, {:effect, good_effect}})

      SessionCase.wait_for_seq(sub, before_seq + 1)

      assert Subscriber.stats(sub).status == :attached

      assert Enum.any?(
               Subscriber.messages(sub),
               &(&1.type == "effect.log" and &1.payload["label"] == "still-alive")
             )
    end
  end

  # -- helpers ----------------------------------------------------------

  defp collect_listener_messages(session_id, count) do
    for _ <- 1..count do
      receive do
        {:statifier_ui, ^session_id, message} -> message
      after
        1000 -> flunk("timed out waiting for a listener message")
      end
    end
  end
end
