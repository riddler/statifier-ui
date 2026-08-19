defmodule StatifierUI.Trace.GoldenTraceTest do
  @moduledoc """
  The ADR-0005 conformance mechanism: a real session, over a real chart,
  compared byte-for-byte against a checked-in fixture. This is the two-state
  chart `docs/wire-format.md`'s worked example carries, chosen deliberately
  to avoid `<invoke>` and `<send target="#_internal">` - the reordering seam
  ADR-0044 (`st-r6l9`) has since closed for every chart, not just this one,
  so live delivery order now agrees with `(macrostep, round)` order across a
  whole run regardless. What the chart choice still buys is determinism, not
  order-safety: staying off that seam keeps this test a plain byte
  comparison rather than a multiset or `(macrostep, round)`-sorted one (spike
  finding, `docs/research/260816-sui-t36.1-trace-coverage-spike.md`).
  """

  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Subscriber

  # No XML prolog, and this exact indentation - the golden fixture's byte
  # offsets were captured from this precise chart. Matches
  # docs/wire-format.md's worked example chart.
  @two_state """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  @fixture_path Path.join([__DIR__, "..", "..", "support", "trace", "two_state.jsonl"])
  @full_seq 15

  defp run_trace do
    machine = SessionCase.compile!(@two_state)
    {sub, session} = SessionCase.start_early!(machine, "sess_golden")
    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, @full_seq)

    sub
    |> Subscriber.messages()
    |> Json.encode_lines()
  end

  test "matches the checked-in fixture byte-for-byte and is stable run to run" do
    expected = File.read!(@fixture_path)

    first_run = run_trace()
    second_run = run_trace()

    assert first_run == expected
    assert second_run == expected
    assert first_run == second_run
  end
end
