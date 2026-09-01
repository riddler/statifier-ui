defmodule StatifierUI.InspectorTest do
  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Inspector
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Subscriber

  @two_state """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  # The datamodel chart mirrors the explorer pane's own live-mode tests:
  # one declared variable, assigned on the driven transition.
  @counter """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <datamodel>
          <data id="count" expr="41 + 1"/>
      </datamodel>
      <state id="a">
          <transition event="bump" target="a">
              <assign location="count" expr="count + 1"/>
          </transition>
      </state>
  </scxml>
  """

  # A compound-and-parallel chart, so a selected macrostep is checked
  # against a configuration with hierarchy in it rather than one leaf
  # (sui-3gg's "correct across compound/parallel configurations").
  #
  # Document-order indexes: 0 scxml, 1 idle, 2 running, 3 left, 4 l1,
  # 5 l2, 6 right, 7 r1, 8 r2.
  @nested """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0">
      <state id="idle">
          <transition event="start" target="running"/>
      </state>
      <parallel id="running">
          <state id="left" initial="l1">
              <state id="l1">
                  <transition event="tick" target="l2"/>
              </state>
              <state id="l2"/>
          </state>
          <state id="right" initial="r1">
              <state id="r1">
                  <transition event="tick" target="r2"/>
              </state>
              <state id="r2"/>
          </state>
      </parallel>
  </scxml>
  """

  # Drives the nested chart through three macrosteps: 1 initialize,
  # 2 "start" (into the parallel), 3 "tick" (both regions move).
  defp nested_messages(session_id) do
    machine = SessionCase.compile!(@nested)
    {sub, session} = SessionCase.start_early!(machine, session_id)
    Session.send_event(session, "start")
    SessionCase.wait_for_macrostep(session, 2)
    Session.send_event(session, "tick")
    SessionCase.wait_for_macrostep(session, 3)
    wait_for_quiescent_macrostep(sub, 3)
    {machine, Subscriber.messages(sub)}
  end

  # The subscriber is a separate process from the session, so a session
  # that has finished macrostep n has not necessarily delivered its
  # `trace.macrostep_stable` yet. Poll the fold, not the session.
  defp wait_for_quiescent_macrostep(sub, target, timeout \\ 1000) do
    points = Inspector.points(Subscriber.messages(sub))

    cond do
      Enum.any?(points, &(&1.macrostep == target and &1.quiescent?)) -> :ok
      timeout <= 0 -> flunk("macrostep #{target} never reached quiescence in the subscriber")
      true -> sleep_then_retry(sub, target, timeout)
    end
  end

  defp sleep_then_retry(sub, target, timeout) do
    Process.sleep(10)
    wait_for_quiescent_macrostep(sub, target, timeout - 10)
  end

  defp driven_messages(xml, session_id) do
    machine = SessionCase.compile!(xml)
    {sub, session} = SessionCase.start_early!(machine, session_id)
    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, 15)
    {machine, Subscriber.messages(sub), Subscriber.stats(sub)}
  end

  describe "active_configuration/2" do
    test "reads the newest trace.macrostep_stable" do
      {_machine, messages, _stats} = driven_messages(@two_state, "sess_insp_conf")

      # After "go" the chart sits in "b" (index 2, root index 0 included).
      assert Inspector.active_configuration(messages) == [0, 2]
    end

    test "falls back to the initial configuration when no macrostep is in view" do
      assert Inspector.active_configuration([], initial_configuration: MapSet.new([0, 1])) ==
               [0, 1]

      assert Inspector.active_configuration([]) == []
    end
  end

  describe "diagram/3" do
    test "highlights the fold's configuration" do
      {machine, messages, _stats} = driven_messages(@two_state, "sess_insp_diag")

      source = Inspector.diagram(machine, messages)
      assert String.starts_with?(source, "stateDiagram-v2")
      assert source =~ "class s2 active"
      refute source =~ "class s1 active"
    end
  end

  describe "event_log/1" do
    test "renders the driven macrostep" do
      {_machine, messages, _stats} = driven_messages(@two_state, "sess_insp_log")

      markdown = Inspector.event_log(messages)
      assert markdown =~ "Macrostep 2"
      assert markdown =~ "go"
    end

    test "an empty message list still renders" do
      assert is_binary(Inspector.event_log([]))
    end
  end

  describe "points/1" do
    test "names every macrostep, its event, and whether it settled" do
      {_machine, messages} = nested_messages("sess_insp_points")

      assert [
               %{macrostep: 1, event: nil, quiescent?: true},
               %{macrostep: 2, event: "start", quiescent?: true},
               %{macrostep: 3, event: "tick", quiescent?: true}
             ] = Inspector.points(messages)
    end

    test "an empty stream offers nothing to select" do
      assert Inspector.points([]) == []
    end
  end

  describe "active_configuration/2 under a selection" do
    test "a selected macrostep reads that macrostep's configuration, not the tip" do
      {_machine, messages} = nested_messages("sess_insp_sel_conf")

      # The tip: both regions have ticked over to l2/r2.
      assert Inspector.active_configuration(messages) == [0, 2, 3, 5, 6, 8]

      # Macrostep 2, the parallel just entered: l1/r1, with the parallel
      # and both regions in the configuration - the compound/parallel case.
      assert Inspector.active_configuration(messages, selection: {:macrostep, 2}) ==
               [0, 2, 3, 4, 6, 7]

      # Macrostep 1, the initialize burst: the simple state it started in.
      assert Inspector.active_configuration(messages, selection: {:macrostep, 1}) == [0, 1]
    end

    test "selecting the newest macrostep matches the live reading" do
      {_machine, messages} = nested_messages("sess_insp_sel_tip")

      assert Inspector.active_configuration(messages, selection: {:macrostep, 3}) ==
               Inspector.active_configuration(messages)
    end

    test "a macrostep below every stamp falls back to the initial configuration" do
      {_machine, messages} = nested_messages("sess_insp_sel_before")

      assert Inspector.active_configuration(messages,
               selection: {:macrostep, 0},
               initial_configuration: MapSet.new([0, 1])
             ) == [0, 1]

      assert Inspector.resolution(messages, selection: {:macrostep, 0}) == {:before_first, 0}
    end

    test "a macrostep above every stamp carries the newest one forward" do
      {_machine, messages} = nested_messages("sess_insp_sel_after")

      assert Inspector.resolution(messages, selection: {:macrostep, 9}) == {:carried, 9, 3}

      assert Inspector.active_configuration(messages, selection: {:macrostep, 9}) ==
               Inspector.active_configuration(messages)
    end

    test "a stream reconstructed by catch-up selects identically" do
      # The acceptance criterion's "via ADR-0034 replay": a subscriber that
      # missed the whole run and caught up afterwards must resolve every
      # selection the same way a live subscriber does. Nothing here
      # re-derives a configuration - replay re-drove the core and stamped
      # these, and both streams carry the same stamps.
      machine = SessionCase.compile!(@nested)
      session = SessionCase.start_recorded!(machine, "sess_insp_sel_replay")
      Session.send_event(session, "start")
      SessionCase.wait_for_macrostep(session, 2)
      Session.send_event(session, "tick")
      SessionCase.wait_for_macrostep(session, 3)

      sub = SessionCase.attach_catch_up!(machine, session)
      wait_for_quiescent_macrostep(sub, 3)
      replayed = Subscriber.messages(sub)

      {_machine, live} = nested_messages("sess_insp_sel_replay_live")

      assert Enum.map(Inspector.points(replayed), & &1.macrostep) == [1, 2, 3]

      for macrostep <- 1..3 do
        assert Inspector.active_configuration(replayed, selection: {:macrostep, macrostep}) ==
                 Inspector.active_configuration(live, selection: {:macrostep, macrostep})
      end
    end

    test "no selection resolves live" do
      {_machine, messages} = nested_messages("sess_insp_sel_live")
      assert Inspector.resolution(messages) == :live
    end
  end

  describe "diagram/3 under a selection" do
    test "draws the selected macrostep's configuration" do
      {machine, messages} = nested_messages("sess_insp_sel_diag")

      # The parallel, both its regions, and each region's first child - the
      # synthesized root (s0) is filtered out of the class list, so what a
      # reader sees is l1/r1 highlighted and l2/r2 not.
      source = Inspector.diagram(machine, messages, selection: {:macrostep, 2})
      assert source =~ "class s2,s3,s4,s6,s7 active"

      # The tip would have highlighted l2/r2 instead.
      assert Inspector.diagram(machine, messages) =~ "class s2,s3,s5,s6,s8 active"
    end
  end

  describe "step/3" do
    setup do
      %{points: [%{macrostep: 1}, %{macrostep: 2}, %{macrostep: 3}]}
    end

    test "prev from live pins the newest macrostep", %{points: points} do
      assert Inspector.step(:live, points, :prev) == {:macrostep, 3}
    end

    test "next from live keeps following the tip", %{points: points} do
      assert Inspector.step(:live, points, :next) == :live
    end

    test "prev walks back and stops at the oldest", %{points: points} do
      assert Inspector.step({:macrostep, 3}, points, :prev) == {:macrostep, 2}
      assert Inspector.step({:macrostep, 1}, points, :prev) == {:macrostep, 1}
    end

    test "next walks forward and returns to live past the newest", %{points: points} do
      assert Inspector.step({:macrostep, 1}, points, :next) == {:macrostep, 2}
      assert Inspector.step({:macrostep, 3}, points, :next) == :live
    end

    test "first selects the oldest, live returns live", %{points: points} do
      assert Inspector.step({:macrostep, 3}, points, :first) == {:macrostep, 1}
      assert Inspector.step({:macrostep, 2}, points, :live) == :live
    end

    test "every move with nothing to select stays live" do
      for move <- [:first, :prev, :next, :live] do
        assert Inspector.step({:macrostep, 2}, [], move) == :live
      end
    end

    test "a selection naming a macrostep no longer in view still moves" do
      # A dropped prefix can leave the selection below every point.
      points = [%{macrostep: 7}, %{macrostep: 8}]
      assert Inspector.step({:macrostep, 2}, points, :next) == {:macrostep, 7}
      assert Inspector.step({:macrostep, 2}, points, :prev) == {:macrostep, 2}
    end
  end

  describe "selection_note/2" do
    test "live says so" do
      assert Inspector.selection_note([]) == "**Showing** the live tip."
    end

    test "a quiescent macrostep names itself and its event" do
      {_machine, messages} = nested_messages("sess_insp_note_q")

      note = Inspector.selection_note(messages, selection: {:macrostep, 2})
      assert note =~ "macrostep 2"
      assert note =~ "`start`"
      assert note =~ "quiescent configuration"
    end

    test "the initialize macrostep is named as such" do
      {_machine, messages} = nested_messages("sess_insp_note_init")
      assert Inspector.selection_note(messages, selection: {:macrostep, 1}) =~ "(initialize)"
    end

    test "a carried configuration says which macrostep it came from" do
      {_machine, messages} = nested_messages("sess_insp_note_carried")

      note = Inspector.selection_note(messages, selection: {:macrostep, 9})
      assert note =~ "not quiescent"
      assert note =~ "macrostep 3's, carried forward"
    end

    test "a macrostep below every stamp says the initial configuration is drawn" do
      {_machine, messages} = nested_messages("sess_insp_note_before")

      assert Inspector.selection_note(messages, selection: {:macrostep, 0}) =~
               "initial configuration is drawn"
    end
  end

  # sui-4w2: the same nested run with a host resolver attached, so the
  # messages carry the wire format's `otel` key exactly as a bridged host's
  # would (ADR-0013) rather than being hand-stamped here. One trace per
  # macrostep, matching the upstream span topology.
  @deep_link "https://apm.example.com/trace/{trace_id}?span={span_id}"

  defp correlated_messages(session_id) do
    resolver = fn _session, macrostep ->
      digit = Integer.to_string(macrostep)

      {:ok, %{trace_id: String.duplicate(digit, 32), span_id: String.duplicate(digit, 16)}}
    end

    machine = SessionCase.compile!(@nested)
    {sub, session} = SessionCase.start_early!(machine, session_id, otel_context: resolver)
    Session.send_event(session, "start")
    SessionCase.wait_for_macrostep(session, 2)
    Session.send_event(session, "tick")
    SessionCase.wait_for_macrostep(session, 3)
    wait_for_quiescent_macrostep(sub, 3)
    Subscriber.messages(sub)
  end

  describe "deep links (sui-4w2)" do
    test "the event log links each macrostep to its own trace" do
      messages = correlated_messages("sess_insp_link_log")

      markdown = Inspector.event_log(messages, deep_link: @deep_link)

      assert markdown =~
               "[trace](https://apm.example.com/trace/#{String.duplicate("2", 32)}" <>
                 "?span=#{String.duplicate("2", 16)})"

      assert markdown =~ "[trace](https://apm.example.com/trace/#{String.duplicate("3", 32)}"
    end

    test "the selection note links the macrostep on screen" do
      messages = correlated_messages("sess_insp_link_note")

      note = Inspector.selection_note(messages, selection: {:macrostep, 2}, deep_link: @deep_link)

      assert note =~ "quiescent configuration."
      assert note =~ "[open trace](https://apm.example.com/trace/#{String.duplicate("2", 32)}"
    end

    test "a carried configuration keeps its wording and gains no link" do
      messages = correlated_messages("sess_insp_link_carried")

      note = Inspector.selection_note(messages, selection: {:macrostep, 9}, deep_link: @deep_link)

      assert note =~ "not quiescent"
      assert note =~ "macrostep 3's, carried forward"
      refute note =~ "[open trace]"
    end

    test "the panes are unchanged when the host configures no template" do
      messages = correlated_messages("sess_insp_link_off")

      assert Inspector.event_log(messages, selection: {:macrostep, 2}) ==
               Inspector.event_log(messages, selection: {:macrostep, 2}, deep_link: nil)

      refute Inspector.event_log(messages) =~ "[trace]("

      refute Inspector.selection_note(messages, selection: {:macrostep, 2}) =~ "[open trace]"
    end

    test "a run with no correlation renders no link even with a template" do
      {_machine, messages} = nested_messages("sess_insp_link_none")

      refute Inspector.event_log(messages, deep_link: @deep_link) =~ "[trace]("

      refute Inspector.selection_note(messages, selection: {:macrostep, 2}, deep_link: @deep_link) =~
               "[open trace]"
    end
  end

  describe "event_log/2 under a selection" do
    test "marks and opens the selected macrostep" do
      {_machine, messages} = nested_messages("sess_insp_log_sel")

      markdown = Inspector.event_log(messages, selection: {:macrostep, 2})
      assert markdown =~ "Macrostep 2: start"
      assert markdown =~ "- shown in the diagram"

      # Exactly one entry is marked, and it is the open one.
      assert markdown |> String.split("- shown in the diagram") |> length() == 2
      assert markdown =~ ~r/<details open>\s*<summary>Macrostep 2:/
    end

    test "with no selection nothing is marked and the last entry opens" do
      {_machine, messages} = nested_messages("sess_insp_log_live")

      markdown = Inspector.event_log(messages)
      refute markdown =~ "shown in the diagram"
      assert markdown =~ ~r/<details open>\s*<summary>Macrostep 3:/
    end
  end

  describe "datamodel/1" do
    test "renders live entries with their current values" do
      machine = SessionCase.compile!(@counter)
      {sub, session} = SessionCase.start_early!(machine, "sess_insp_data")
      Session.send_event(session, "bump")
      SessionCase.wait_until(sub, 1000, fn stats -> stats.seq >= 10 end)

      markdown = Inspector.datamodel(Subscriber.messages(sub))
      assert markdown =~ "count"
    end
  end

  describe "status/1" do
    test "renders session, counts, and no warnings for a whole stream" do
      {_machine, _messages, stats} = driven_messages(@two_state, "sess_insp_status")

      markdown = Inspector.status(stats)
      assert markdown =~ "`sess_insp_status`"
      assert markdown =~ "attached"
      refute markdown =~ "Live-only"
    end

    test "labels a :not_recorded diagnostic Live-only" do
      machine = SessionCase.compile!(@two_state)
      {:ok, session} = Session.start_link(machine, trace: true, session_id: "sess_insp_lo")
      {:ok, sub} = Subscriber.start_link(machine: machine)
      :ok = Subscriber.attach(sub, session, catch_up: true)

      markdown = Inspector.status(Subscriber.stats(sub))
      assert markdown =~ "**Live-only:**"
      assert markdown =~ "record: true"
    end

    test "a stats snapshot before any message names no session" do
      {:ok, sub} = Subscriber.start_link(machine: SessionCase.compile!(@two_state))
      assert Inspector.status(Subscriber.stats(sub)) =~ "(awaiting first message)"
    end
  end
end
