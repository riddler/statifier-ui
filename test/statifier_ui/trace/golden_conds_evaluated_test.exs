defmodule StatifierUI.Trace.GoldenCondsEvaluatedTest do
  @moduledoc """
  The ADR-0018 counterpart to `StatifierUI.Trace.GoldenTraceTest`: a real
  session over a real chart, compared byte-for-byte against a checked-in
  fixture, for `trace.conds_evaluated`.

  It exists because no other golden reaches the type's interesting half.
  `two_state.jsonl` has no guard at all, and `guarded.jsonl`'s single `cond`
  answers `true` - so `"enabled"` is the only outcome either of them can
  capture, and a producer that emitted `"enabled"` for every evaluation would
  pass both. The chart below evaluates one guard to false, one to true, and
  one to a non-boolean result, so all three `outcome` values and the `reason`
  object appear in checked-in bytes.

  The three rounds it produces, in order:

  - `continue` in `details` evaluates two written `cond`s - `variant == 'a'`
    is `"disabled"` and `variant == 'b'` is `"enabled"`. **Two entries in one
    message**, which is the array shape a single-entry fixture cannot prove.
  - `continue` in `plan_b` evaluates `variant`, a string, which spec 5.9.1
    joins with evaluation failure into the single `"error"` outcome. Its
    `reason` is ADR-0014's `class: "reason"` object, anchored on the guarded
    transition (`location_kind: "node"` - a reason has no expression span to
    resolve against).
  - The unguarded fallback beside it gets **no entry at all**: a `nil` `cond`
    short-circuits ahead of the evaluator, so it is not an evaluation.

  The fixture also carries the join ADR-0018 decision 2 states is
  load-bearing: the `error.execution` the erroring round raised appears
  later in the stream carrying an `error` object byte-identical to the
  entry's `reason`, which is what lets a consumer pair the *n*th `"error"`
  entry with the *n*th raised event.

  Deliberately off `<invoke>` and `<send target="#_internal">` for the same
  reason `GoldenTraceTest` is: staying off that seam keeps this a plain byte
  comparison rather than an order-insensitive one.
  """

  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Normalizer
  alias StatifierUI.Trace.Subscriber

  # No XML prolog, and this exact indentation - the golden fixture's byte
  # offsets were captured from this precise chart.
  @wizard """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="details" version="1.0" datamodel="predicator">
      <datamodel>
          <data id="variant" expr="'b'"/>
      </datamodel>
      <state id="details">
          <transition event="continue" cond="variant == 'a'" target="plan_a"/>
          <transition event="continue" cond="variant == 'b'" target="plan_b"/>
      </state>
      <state id="plan_a"/>
      <state id="plan_b">
          <transition event="continue" cond="variant" target="review"/>
          <transition event="continue" target="review"/>
      </state>
      <state id="review"/>
  </scxml>
  """

  @fixture_path Path.join([__DIR__, "..", "..", "support", "trace", "conds_evaluated.jsonl"])
  @full_seq 30

  defp run_trace do
    machine = SessionCase.compile!(@wizard)

    {:ok, sub} = Subscriber.start_link(machine: machine, source: @wizard)

    {:ok, session} =
      Session.start_link(machine, trace: true, subscribers: [sub], session_id: "sess_wizard")

    :ok = Subscriber.attach(sub, session, subscribe: false)
    Session.send_event(session, "continue")
    Session.send_event(session, "continue")
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

    assert stats.seq == @full_seq
    assert stats.dropped == 0
    assert stats.errors == 0
  end

  describe "the captured trace.conds_evaluated messages" do
    setup do
      messages =
        @fixture_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      %{
        messages: messages,
        conds: Enum.filter(messages, &(&1["type"] == "trace.conds_evaluated"))
      }
    end

    test "the round with two written conds carries both, in walk order", %{conds: conds} do
      assert [first, _second] = conds

      assert first["evaluations"] == [
               %{"t_index" => 0, "outcome" => "disabled"},
               %{"t_index" => 1, "outcome" => "enabled"}
             ]
    end

    test "reason is absent on the non-error outcomes, not null", %{conds: conds} do
      for entry <- Enum.flat_map(conds, & &1["evaluations"]),
          entry["outcome"] != "error" do
        refute Map.has_key?(entry, "reason")
      end
    end

    test "the erroring round carries one entry and the reason object", %{conds: conds} do
      assert [_first, second] = conds
      assert [%{"t_index" => 2, "outcome" => "error", "reason" => reason}] = second["evaluations"]

      assert reason["class"] == "reason"
      assert reason["kind"] == "non_boolean_cond"
      assert reason["reason"] == ~s({:non_boolean_cond, "b"})
      # A reason has no expression span to compose against, so the anchor is
      # the guarded transition's own node span.
      assert reason["location_kind"] == "node"
      assert reason["location"]["start_line"] == 11
    end

    test "the unguarded fallback beside the erroring transition gets no entry", %{conds: conds} do
      t_indexes = conds |> Enum.flat_map(& &1["evaluations"]) |> Enum.map(& &1["t_index"])

      # t_index 3 is `<transition event="continue" target="review"/>`, written
      # without a `cond`: no evaluation, so no entry.
      assert t_indexes == [0, 1, 2]
    end

    test "the error entry's reason is the object the raised error.execution carries", %{
      conds: conds,
      messages: messages
    } do
      [%{"reason" => reason}] = List.last(conds)["evaluations"]

      raised =
        messages
        |> Enum.filter(&(&1["type"] == "trace.event_dequeued"))
        |> Enum.map(& &1["event"])
        |> Enum.filter(&(&1["name"] == "error.execution"))

      assert [%{"error" => ^reason}] = raised
    end
  end

  test "every message the run produced carries a documented type" do
    types =
      @fixture_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!(&1)["type"])
      |> Enum.uniq()

    assert Enum.all?(types, &(&1 in Normalizer.types()))
    assert "trace.conds_evaluated" in types
  end
end
