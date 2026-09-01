defmodule StatifierUI.Live.StateTest do
  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Live.State
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  # Document-order indexes: 0 scxml, 1 idle, 2 running, 3 left, 4 l1,
  # 5 l2, 6 right, 7 r1, 8 r2 - the inspector test's chart, so a
  # configuration read here is a configuration with hierarchy in it.
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

  setup do
    machine = SessionCase.compile!(@nested)
    {sub, session} = SessionCase.start_early!(machine, "sess_live")

    Session.send_event(session, "start")
    SessionCase.wait_for_macrostep(session, 2)
    Session.send_event(session, "tick")
    SessionCase.wait_for_macrostep(session, 3)
    wait_for_quiescent(sub, 3)

    %{machine: machine, subscriber: sub, messages: Subscriber.messages(sub)}
  end

  describe "new/2 - a persisted stream" do
    test "folds the message list without any process", %{machine: machine, messages: messages} do
      state = State.new(machine, messages: messages)

      assert state.selection == :live
      assert state.stats == nil
      assert length(State.points(state)) == 3
      assert State.selected_macrostep(state) == nil
    end

    test "the live tip is the newest quiescent configuration", %{
      machine: machine,
      messages: messages
    } do
      state = State.new(machine, messages: messages)

      # scxml, running, left, l2, right, r2 - both regions moved on "tick".
      assert State.configuration(state) == [0, 2, 3, 5, 6, 8]
      assert State.resolution(state) == :live
    end

    test "an empty stream draws the caller's initial configuration", %{machine: machine} do
      state = State.new(machine, initial_configuration: [0, 1])

      assert State.configuration(state) == [0, 1]
      assert State.points(state) == []
      assert State.selection_note(state) == "**Showing** the live tip."
    end

    test "the diagram source is Mermaid for the selected configuration", %{
      machine: machine,
      messages: messages
    } do
      source = machine |> State.new(messages: messages) |> State.diagram_source()

      assert String.starts_with?(source, "stateDiagram-v2")
      assert source =~ "class s2,s3,s5,s6,s8 active"
    end
  end

  describe "selection" do
    test "select/2 pins one macrostep and configuration follows it", %{
      machine: machine,
      messages: messages
    } do
      state = machine |> State.new(messages: messages) |> State.select(2)

      assert State.selected_macrostep(state) == 2
      assert State.resolution(state) == {:quiescent, 2}
      # After "start", before "tick": both regions at their initial children.
      assert State.configuration(state) == [0, 2, 3, 4, 6, 7]
    end

    test "scrub/2 walks first, prev, next and back to live", %{
      machine: machine,
      messages: messages
    } do
      state = State.new(machine, messages: messages)

      first = State.scrub(state, :first)
      assert first.selection == {:macrostep, 1}

      assert State.scrub(first, :prev).selection == {:macrostep, 1}
      assert State.scrub(first, :next).selection == {:macrostep, 2}

      last = state |> State.scrub(:first) |> State.scrub(:next) |> State.scrub(:next)
      assert last.selection == {:macrostep, 3}
      assert State.scrub(last, :next).selection == :live
      assert State.scrub(last, :live).selection == :live
    end

    test "prev from :live pins the newest macrostep", %{machine: machine, messages: messages} do
      state = machine |> State.new(messages: messages) |> State.scrub(:prev)

      assert state.selection == {:macrostep, 3}
    end

    test "with no points every move resolves to :live", %{machine: machine} do
      state = State.new(machine)

      for move <- [:first, :prev, :next, :live] do
        assert State.scrub(state, move).selection == :live
      end
    end

    test "a macrostep naming no bucket carries the newest configuration below it", %{
      machine: machine,
      messages: messages
    } do
      state = machine |> State.new(messages: messages) |> State.select(99)

      assert State.resolution(state) == {:carried, 99, 3}
      assert State.selection_note(state) =~ "carried forward"
    end
  end

  describe "push/2 - a live stream" do
    test "appends a message the state has not seen", %{machine: machine} do
      state = State.new(machine)
      message = %Message{type: "session.start", session: "s", seq: 0, payload: %{"version" => 1}}

      assert %State{messages: [^message], last_seq: 0} = State.push(state, message)
    end

    test "drops a message whose seq the state already holds", %{
      machine: machine,
      messages: messages
    } do
      state = State.new(machine, messages: messages)
      replayed = hd(messages)

      assert State.push(state, replayed).messages == messages
    end

    test "the add_listener-then-sync overlap is dropped in full", %{
      machine: machine,
      messages: messages
    } do
      state = State.new(machine, messages: messages)

      assert State.push(state, messages).messages == messages
    end

    test "a newer message still appends after an overlap", %{
      machine: machine,
      messages: messages
    } do
      state = State.new(machine, messages: messages)
      newest = List.last(messages)
      next = %{newest | seq: newest.seq + 1, type: "session.terminated", payload: %{}}

      assert state |> State.push(messages) |> State.push(next) |> Map.fetch!(:messages) ==
               messages ++ [next]
    end
  end

  describe "sync/2 and put_stats/2" do
    test "pulls the subscriber's buffer and stats in one call", %{
      machine: machine,
      subscriber: sub,
      messages: messages
    } do
      state = machine |> State.new() |> State.sync(sub)

      assert state.messages == messages
      assert state.stats.session == "sess_live"
      assert state.stats.status == :attached
    end

    test "put_stats/2 replaces the snapshot without touching the messages", %{
      machine: machine,
      messages: messages
    } do
      state =
        machine
        |> State.new(messages: messages)
        |> State.put_stats(%{session: "sess_live", status: :terminated})

      assert state.stats.status == :terminated
      assert state.messages == messages
    end
  end

  describe "log/1" do
    test "folds the stream", %{machine: machine, messages: messages} do
      assert {:ok, log} = machine |> State.new(messages: messages) |> State.log()
      assert log.session == "sess_live"
      assert length(log.macrosteps) == 3
    end

    test "refuses a list naming two sessions rather than corrupting the timeline", %{
      machine: machine
    } do
      mixed = [
        %Message{type: "trace.macrostep_stable", session: "a", seq: 0, macrostep: 1, round: 0},
        %Message{type: "trace.macrostep_stable", session: "b", seq: 1, macrostep: 1, round: 0}
      ]

      assert {:error, {:mixed_sessions, ["a", "b"]}} =
               machine |> State.new(messages: mixed) |> State.log()
    end
  end

  defp wait_for_quiescent(sub, target, timeout \\ 1000) do
    points = StatifierUI.Inspector.points(Subscriber.messages(sub))

    cond do
      Enum.any?(points, &(&1.macrostep == target and &1.quiescent?)) ->
        :ok

      timeout <= 0 ->
        flunk("macrostep #{target} never reached quiescence in the subscriber")

      true ->
        Process.sleep(10)
        wait_for_quiescent(sub, target, timeout - 10)
    end
  end
end
