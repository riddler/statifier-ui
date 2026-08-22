defmodule StatifierUI.KinoTest do
  # `configure_livebook_bridge` swaps this process's group leader, so these
  # tests stay out of the async pool.
  use ExUnit.Case, async: false

  import Kino.Test

  alias Statifier.Session
  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Subscriber

  setup :configure_livebook_bridge

  @two_state """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  test "inspect/3 composes a layout over a recorded session, palette included" do
    machine = SessionCase.compile!(@two_state)

    {:ok, session} =
      Session.start_link(machine, trace: true, record: true, session_id: "sess_kino_smoke")

    {:ok, fixtures} = Fixtures.new(events: %{"go" => %{"note" => "demo"}})

    layout = StatifierUI.Kino.inspect(session, fixtures, source: @two_state)
    assert %Kino.Layout{} = layout

    # The widget must not have subscribed live-only: the session records,
    # so a second subscriber catching up now sees the same whole stream the
    # widget's own subscriber folded in - the initialize burst included.
    sub = SessionCase.attach_catch_up!(machine, session)
    messages = Subscriber.messages(sub)
    assert Enum.any?(messages, &(&1.type == "session.start"))
    assert Enum.any?(messages, &(&1.payload["indexes"] == [0, 1]))

    # Driving the session after assembly must not crash anything the
    # widget started; the updater re-renders on its coalesced tick.
    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, 15)
  end

  test "inspect/3 without fixtures renders no palette and still assembles" do
    machine = SessionCase.compile!(@two_state)

    {:ok, session} =
      Session.start_link(machine, trace: true, record: true, session_id: "sess_kino_bare")

    assert %Kino.Layout{} = StatifierUI.Kino.inspect(session)
  end

  test "inspect/3 on an unrecorded session still assembles (live-only)" do
    machine = SessionCase.compile!(@two_state)
    {:ok, session} = Session.start_link(machine, trace: true, session_id: "sess_kino_lo")

    assert %Kino.Layout{} = StatifierUI.Kino.inspect(session)
  end
end
