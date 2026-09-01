defmodule StatifierUI.LiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Statifier.Session
  alias StatifierUI.Live
  alias StatifierUI.Live.State
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  # The inspector test's chart: two macrosteps past initialize, a parallel
  # region so a rendered configuration has hierarchy in it. Document-order
  # indexes: 0 scxml, 1 idle, 2 running, 3 left, 4 l1, 5 l2, 6 right,
  # 7 r1, 8 r2.
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
    {sub, session} = SessionCase.start_early!(machine, "sess_ops")

    Session.send_event(session, "start")
    SessionCase.wait_for_macrostep(session, 2)
    Session.send_event(session, "tick")
    SessionCase.wait_for_macrostep(session, 3)
    wait_for_quiescent(sub, 3)

    messages = Subscriber.messages(sub)

    %{
      machine: machine,
      subscriber: sub,
      messages: messages,
      state: State.new(machine, messages: messages)
    }
  end

  describe "ops_view/1" do
    test "composes the four panes under one id root", %{state: state} do
      html = render_component(&Live.ops_view/1, id: "ops", state: state)

      assert html =~ ~s(id="ops")
      assert html =~ ~s(id="ops-status")
      assert html =~ ~s(id="ops-scrubber")
      assert html =~ ~s(id="ops-diagram")
      assert html =~ ~s(id="ops-event-log")
      assert html =~ ~s(class="statifier-ui-panes")
    end

    test "a persisted stream renders every pane with no subscriber at all", %{
      machine: machine,
      messages: messages
    } do
      html =
        render_component(&Live.ops_view/1,
          id: "ops",
          state: State.new(machine, messages: messages)
        )

      assert html =~ "stateDiagram-v2"
      assert html =~ ~s(data-status="persisted")
      assert html =~ "Macrostep 3"
    end

    test "a live stream carries the subscriber's own status and counts", %{
      machine: machine,
      subscriber: sub
    } do
      state = machine |> State.new() |> State.sync(sub)
      html = render_component(&Live.ops_view/1, id: "ops", state: state)

      assert html =~ ~s(data-status="attached")
      assert html =~ "sess_ops"
      assert html =~ "buffered"
    end
  end

  describe "diagram/1" do
    test "emits Mermaid source and stamps the drawn configuration", %{state: state} do
      html = render_component(&Live.diagram/1, id: "d", state: state)

      assert html =~ ~s(class="mermaid statifier-ui-diagram-source")
      assert html =~ "stateDiagram-v2"
      assert html =~ ~s(data-configuration="0 2 3 5 6 8")
    end

    test "follows the selection rather than the tip", %{state: state} do
      html = render_component(&Live.diagram/1, id: "d", state: State.select(state, 2))

      assert html =~ ~s(data-configuration="0 2 3 4 6 7")
    end

    test "carries a phx-hook only when the host asks for one", %{state: state} do
      refute render_component(&Live.diagram/1, id: "d", state: state) =~ "phx-hook"

      assert render_component(&Live.diagram/1, id: "d", state: state, hook: "Mermaid") =~
               ~s(phx-hook="Mermaid")
    end
  end

  describe "event_log/1" do
    test "renders one selectable entry per macrostep", %{state: state} do
      html = render_component(&Live.event_log/1, id: "log", state: state)

      for macrostep <- 1..3 do
        assert html =~ ~s(data-macrostep="#{macrostep}")
      end

      assert html =~ ~s(phx-click="statifier_ui_select")
      assert html =~ ~s(phx-value-macrostep="2")
      assert html =~ "sess_ops"
    end

    test "resolves indexes to chart ids through the manifest labels", %{state: state} do
      html = render_component(&Live.event_log/1, id: "log", state: state)

      assert html =~ "Entered"
      assert html =~ "l2"
      assert html =~ "r2"
      assert html =~ ~s(data-field="configuration")
      assert html =~ ~s(data-round="0")
    end

    test "marks and opens the selected entry, and only that one", %{state: state} do
      html = render_component(&Live.event_log/1, id: "log", state: State.select(state, 2))

      assert html =~ "shown in the diagram"
      assert html =~ ~s(data-macrostep="2" data-selected="true" open)
      assert html =~ ~s(data-macrostep="3" data-selected="false")
    end

    test "with nothing selected the newest entry is open and none is marked", %{state: state} do
      html = render_component(&Live.event_log/1, id: "log", state: state)

      refute html =~ "shown in the diagram"
      assert html =~ ~s(data-macrostep="3" data-selected="false" open)
    end

    test "the host's own event name is what the entries send", %{state: state} do
      html =
        render_component(&Live.event_log/1,
          id: "log",
          state: state,
          select_event: "ops_select",
          target: "#panel"
        )

      assert html =~ ~s(phx-click="ops_select")
      assert html =~ ~s(phx-target="#panel")
    end

    test "a refused log renders as an error line rather than raising", %{machine: machine} do
      mixed = [
        %Message{type: "trace.macrostep_stable", session: "a", seq: 0, macrostep: 1, round: 0},
        %Message{type: "trace.macrostep_stable", session: "b", seq: 1, macrostep: 1, round: 0}
      ]

      html =
        render_component(&Live.event_log/1,
          id: "log",
          state: State.new(machine, messages: mixed)
        )

      assert html =~ "Event log unavailable"
      assert html =~ "mixed_sessions"
    end

    test "an effect with no round is listed under its macrostep", %{
      machine: machine,
      messages: messages
    } do
      logged = %Message{
        type: "effect.log",
        session: "sess_ops",
        seq: 9_999,
        macrostep: 3,
        microstep: 0,
        payload: %{"label" => "audit", "value" => "ok"}
      }

      html =
        render_component(&Live.event_log/1,
          id: "log",
          state: State.new(machine, messages: messages ++ [logged])
        )

      assert html =~ ~s(data-type="effect.log")
      assert html =~ "label: audit, value: ok"
    end
  end

  describe "scrubber/1" do
    test "renders the four moves, each sending the scrub event", %{state: state} do
      html = render_component(&Live.scrubber/1, id: "s", state: state)

      for move <- ~w(first prev next live) do
        assert html =~ ~s(data-move="#{move}")
      end

      assert html =~ ~s(phx-click="statifier_ui_scrub")
      assert html =~ ~s(phx-value-move="live")
    end

    test "on :live the note says so and no macrostep is stamped", %{state: state} do
      html = render_component(&Live.scrubber/1, id: "s", state: state)

      assert html =~ ~s(data-selection="live")
      assert html =~ ~s(data-resolution="live")
      assert html =~ "Showing the live tip."
    end

    test "a quiescent selection names the macrostep and its event", %{state: state} do
      html = render_component(&Live.scrubber/1, id: "s", state: State.select(state, 3))

      assert html =~ ~s(data-selection="macrostep-3")
      assert html =~ ~s(data-resolution="quiescent")
      assert html =~ "Showing macrostep 3 (tick), at its quiescent configuration."
    end

    test "a carried configuration is never presented as a measured one", %{state: state} do
      html = render_component(&Live.scrubber/1, id: "s", state: State.select(state, 99))

      assert html =~ ~s(data-resolution="carried")
      assert html =~ "carried forward"
    end

    test "the note has no Markdown emphasis left in it", %{state: state} do
      html = render_component(&Live.scrubber/1, id: "s", state: state)

      refute html =~ "**"
    end
  end

  describe "status/1" do
    test "a persisted stream says persisted rather than inventing a status", %{
      machine: machine,
      messages: messages
    } do
      html =
        render_component(&Live.status/1, id: "st", state: State.new(machine, messages: messages))

      assert html =~ ~s(data-status="persisted")
      assert html =~ "(no session)"
      refute html =~ "buffered"
    end

    test "a live-only diagnostic is labelled, not swallowed", %{machine: machine} do
      state =
        machine
        |> State.new()
        |> State.put_stats(stats(diagnostics: [%{kind: :not_recorded, message: "no recording"}]))

      html = render_component(&Live.status/1, id: "st", state: state)

      assert html =~ ~s(data-kind="not_recorded")
      assert html =~ "Live-only"
      assert html =~ "no recording"
    end

    test "an unknown diagnostic kind still gets a readable label", %{machine: machine} do
      state =
        machine
        |> State.new()
        |> State.put_stats(
          stats(diagnostics: [%{kind: :manifest_failed, message: "bad fixtures"}])
        )

      assert render_component(&Live.status/1, id: "st", state: state) =~ "Manifest_failed"
    end

    test "a projected stream carries the ADR-0012 banner with its profile", %{machine: machine} do
      state =
        machine
        |> State.new()
        |> State.put_stats(stats(projection: %{profile: :structure_only}))

      html = render_component(&Live.status/1, id: "st", state: state)

      assert html =~ "statifier-ui-projection"
      assert html =~ "structure_only"
      assert html =~ "not unbound"
    end

    test "an unprojected stream carries no banner", %{state: state} do
      refute render_component(&Live.status/1, id: "st", state: state) =~
               "statifier-ui-projection"
    end
  end

  defp stats(overrides) do
    Enum.into(overrides, %{
      session: "sess_ops",
      status: :attached,
      seq: 0,
      buffered: 0,
      dropped: 0,
      errors: 0,
      foreign: 0,
      diagnostics: []
    })
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
