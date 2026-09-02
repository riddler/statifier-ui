defmodule StatifierUI.Trace.CaptureTest do
  @moduledoc """
  The three one-liners, end to end: a live session recorded, written to a
  file, read back, and asserted equal to what was captured.

  The chart is the two-state chart `docs/wire-format.md`'s worked example
  carries and the golden test byte-compares, so a failure here is about the
  capture path rather than about the chart doing something surprising.
  """

  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Capture
  alias StatifierUI.Trace.Message

  @two_state """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  defp recorded_session(session_id) do
    machine = SessionCase.compile!(@two_state)
    session = SessionCase.start_recorded!(machine, session_id)
    {machine, session}
  end

  defp tmp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "sui-pb2-#{name}-#{System.unique_integer([:positive])}.jsonl")

    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "record/3" do
    test "captures the initialize burst a late subscriber would have missed" do
      {machine, session} = recorded_session("sess_capture_initialize")

      assert {:ok, messages} = Capture.record(session, machine)

      assert [%Message{type: "session.start", seq: 0} | _rest] = messages
      assert Enum.any?(messages, &(&1.type == "trace.entry_set"))
    end

    test "captures events driven after the session started" do
      {machine, session} = recorded_session("sess_capture_events")

      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 2)

      assert {:ok, messages} = Capture.record(session, machine)

      assert Enum.any?(messages, fn message ->
               message.type == "trace.event_dequeued" and
                 get_in(message.payload, ["event", "name"]) == "go"
             end)
    end

    test "forwards :source, so the capture carries its own chart" do
      {machine, session} = recorded_session("sess_capture_source")

      assert {:ok, messages} = Capture.record(session, machine, source: @two_state)

      assert Capture.source(messages) == @two_state
    end

    test "a capture taken without :source carries no chart" do
      {machine, session} = recorded_session("sess_capture_no_source")

      assert {:ok, messages} = Capture.record(session, machine)
      assert Capture.source(messages) == nil
    end

    test "refuses a session that was not started with record: true" do
      machine = SessionCase.compile!(@two_state)
      {:ok, session} = Session.start_link(machine, trace: true, session_id: "sess_capture_unrec")

      assert {:error, :not_recorded} = Capture.record(session, machine)
    end

    test "leaves no subscriber process behind" do
      {machine, session} = recorded_session("sess_capture_cleanup")
      before = length(Process.list())

      assert {:ok, _messages} = Capture.record(session, machine)

      assert length(Process.list()) <= before
    end
  end

  describe "save/2 and load/1" do
    test "round-trips a live capture through a file" do
      {machine, session} = recorded_session("sess_capture_file")
      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 2)

      assert {:ok, captured} = Capture.record(session, machine, source: @two_state)

      path = tmp_path("round-trip")
      assert :ok = Capture.save(captured, path)
      assert {:ok, loaded} = Capture.load(path)

      assert loaded == captured
    end

    test "writes JSON Lines, one message per line" do
      {machine, session} = recorded_session("sess_capture_lines")
      assert {:ok, captured} = Capture.record(session, machine)

      path = tmp_path("lines")
      assert :ok = Capture.save(captured, path)

      assert path |> File.read!() |> String.split("\n", trim: true) |> length() ==
               length(captured)
    end

    test "save/2 reports a missing directory rather than raising" do
      path = Path.join([System.tmp_dir!(), "sui-pb2-absent-dir", "run.jsonl"])

      assert {:error, :enoent} = Capture.save([], path)
    end

    test "load/1 reports a missing file" do
      assert {:error, :enoent} =
               Capture.load(Path.join(System.tmp_dir!(), "sui-pb2-no-such-capture.jsonl"))
    end

    test "load/1 names the offending line of a malformed capture" do
      path = tmp_path("malformed")
      File.write!(path, ~s({"type":"a","session":"s","seq":0}\nnot json\n))

      assert {:error, {:line, 2, {:json, _reason}}} = Capture.load(path)
    end

    test "an empty capture saves and loads as an empty list" do
      path = tmp_path("empty")

      assert :ok = Capture.save([], path)
      assert {:ok, []} = Capture.load(path)
    end
  end

  describe "source/1" do
    test "is nil for a stream that does not open with a session.start" do
      assert Capture.source([%Message{type: "trace.done", session: "s", seq: 1}]) == nil
    end

    test "is nil for an empty stream" do
      assert Capture.source([]) == nil
    end
  end
end
