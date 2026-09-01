defmodule StatifierUI.EventInjection.SessionTest do
  use ExUnit.Case, async: true

  alias StatifierUI.EventInjection
  alias StatifierUI.EventInjection.Draft
  alias StatifierUI.EventInjection.Palette
  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Subscriber

  # A transition on "authorize.approved" - the fixture event name the palette
  # entry below is built from - from "pending" to "paid".
  @chart """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="pending" version="1.0">
      <state id="pending">
          <transition event="authorize.approved" target="paid"/>
      </state>
      <state id="paid"/>
  </scxml>
  """

  # 15 messages for @chart driven with one event: seq 0 (session.start)
  # through the driven macrostep's trace.macrostep_stable - same shape as
  # the two-state chart in trace/subscriber_test.exs.
  @full_seq 15

  defp dequeued_event_payloads(sub) do
    sub
    |> Subscriber.messages()
    |> Enum.filter(&(&1.type == "trace.event_dequeued"))
    |> Enum.map(& &1.payload["event"])
  end

  defp entered_index?(sub, index) do
    sub
    |> Subscriber.messages()
    |> Enum.filter(&(&1.type == "trace.entry_set"))
    |> Enum.any?(fn message -> index in message.payload["indexes"] end)
  end

  test "a palette entry's payload round-trips through Draft.build/2 and moves the chart" do
    machine = SessionCase.compile!(@chart)
    paid_index = machine.id_to_index["paid"]

    assert {:ok, fixtures} =
             Fixtures.new(events: %{"authorize.approved" => %{"amount_cents" => 1999}})

    assert {:ok, palette} = Palette.build(fixtures)
    assert {:ok, entry} = Palette.entry(palette, "authorize.approved")

    {sub, session} = SessionCase.start_early!(machine, "sess_palette_send")

    assert {:ok, event} = Draft.build(entry.name, entry.payload_text)
    assert :ok = EventInjection.send(session, event)

    SessionCase.wait_for_seq(sub, @full_seq)

    assert [
             %{
               "name" => "authorize.approved",
               "type" => "external",
               "data" => %{"amount_cents" => 1999}
             }
           ] =
             dequeued_event_payloads(sub)

    assert entered_index?(sub, paid_index)
  end

  test "a free-form send with an edited payload also moves the chart" do
    machine = SessionCase.compile!(@chart)
    paid_index = machine.id_to_index["paid"]

    {sub, session} = SessionCase.start_early!(machine, "sess_free_form_send")

    assert :ok =
             EventInjection.send_draft(session, "authorize.approved", ~s({"amount_cents":2500}))

    SessionCase.wait_for_seq(sub, @full_seq)

    assert [%{"name" => "authorize.approved", "data" => %{"amount_cents" => 2500}}] =
             dequeued_event_payloads(sub)

    assert entered_index?(sub, paid_index)
  end
end
