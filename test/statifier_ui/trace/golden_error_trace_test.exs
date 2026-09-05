defmodule StatifierUI.Trace.GoldenErrorTraceTest do
  @moduledoc """
  The ADR-0014 counterpart to `StatifierUI.Trace.GoldenTraceTest`: a real
  session over a real chart, compared byte-for-byte against a checked-in
  fixture, for the `error` object's **reason** arm.

  It exists because that arm has no coverage the other golden could give
  it. `two_state.jsonl` contains no `error` object at all, and before
  ADR-0014 an `error.execution` carrying a reason term never reached a
  consumer to be captured: the term is not a predicator value, so the whole
  message failed to normalize and `StatifierUI.Trace.Subscriber` dropped it.
  The fixture below is therefore the evidence that the messages arrive at
  all, and `dropped`/`errors` being zero on the subscriber's own stats is
  asserted beside the bytes rather than left implied.

  Two shapes, both reachable from the engine as shipped and both
  deterministic:

  - state `a` raises `{:not_iterable, 42}` from a `<foreach>` over a
    literal - the plain reason arm, no `content_path`;
  - state `b` raises the same failure one level down, inside an enclosing
    `<foreach>` body, so the producer peels `{:nested_content, _, _}` and
    emits `content_path`.

  Deliberately off `<invoke>` and `<send target="#_internal">` for the same
  reason `GoldenTraceTest` is: staying off that seam keeps this a plain byte
  comparison rather than an order-insensitive one.
  """

  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Subscriber

  # No XML prolog, and this exact indentation - the golden fixture's byte
  # offsets were captured from this precise chart.
  @foreach_error """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <state id="a">
          <onentry>
              <foreach array="42" item="i">
                  <log expr="i"/>
              </foreach>
          </onentry>
          <transition event="go" target="b"/>
      </state>
      <state id="b">
          <onentry>
              <foreach array="[1, 2]" item="i">
                  <foreach array="99" item="j">
                      <log expr="j"/>
                  </foreach>
              </foreach>
          </onentry>
      </state>
  </scxml>
  """

  @fixture_path Path.join([__DIR__, "..", "..", "support", "trace", "foreach_error.jsonl"])
  @full_seq 23

  defp run_trace do
    machine = SessionCase.compile!(@foreach_error)

    {:ok, sub} = Subscriber.start_link(machine: machine, source: @foreach_error)

    {:ok, session} =
      Session.start_link(machine,
        trace: true,
        subscribers: [sub],
        session_id: "sess_foreach_error"
      )

    :ok = Subscriber.attach(sub, session, subscribe: false)
    Session.send_event(session, "go")
    stats = SessionCase.wait_for_seq(sub, @full_seq)

    {Json.encode_lines(Subscriber.messages(sub)), stats}
  end

  test "matches the checked-in fixture byte-for-byte and is stable run to run" do
    expected = File.read!(@fixture_path)

    {first_run, _stats} = run_trace()
    {second_run, _stats} = run_trace()

    assert first_run == expected
    assert second_run == expected
    assert first_run == second_run
  end

  test "nothing is dropped and nothing fails to normalize" do
    {_lines, stats} = run_trace()

    assert stats.dropped == 0
    assert stats.errors == 0
  end

  describe "the captured error objects" do
    setup do
      objects =
        @fixture_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)
        |> Enum.filter(&(&1["type"] == "trace.event_dequeued"))
        |> Enum.map(& &1["event"]["error"])
        |> Enum.reject(&is_nil/1)

      %{objects: objects}
    end

    test "the plain reason arm carries class, kind, reason and no content_path", %{
      objects: objects
    } do
      plain = Enum.find(objects, &(not Map.has_key?(&1, "content_path")))

      assert plain["class"] == "reason"
      assert plain["kind"] == "not_iterable"
      assert plain["reason"] == "{:not_iterable, 42}"
      refute Map.has_key?(plain, "expression")
      refute Map.has_key?(plain, "span")
      assert plain["location_kind"] == "node"
    end

    test "the wrapped arm carries a content_path of contents-table indexes", %{objects: objects} do
      wrapped = Enum.find(objects, &Map.has_key?(&1, "content_path"))

      assert wrapped["class"] == "reason"
      assert wrapped["kind"] == "not_iterable"
      assert wrapped["reason"] == "{:not_iterable, 99}"
      assert wrapped["content_path"] == [3]
    end
  end
end
