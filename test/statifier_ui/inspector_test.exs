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
