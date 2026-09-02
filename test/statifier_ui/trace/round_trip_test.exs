defmodule StatifierUI.Trace.RoundTripTest do
  @moduledoc """
  The wire format v1 round-trip law, proved against the same checked-in
  fixture `golden_trace_test.exs` byte-compares a live session with.

  `golden_trace_test.exs` proves the producer half - a real session over a
  real chart emits exactly these bytes. This module proves the consumer
  half closes the loop: decoding those bytes and re-encoding them
  reproduces them exactly. Together they are what
  `docs/wire-format.md`'s "Persistence and the v1 round-trip" section
  claims, in executable form.

  It matters that the fixture is a real capture rather than a hand-written
  sample: it carries every envelope shape the format has (a `session.start`
  with no counters, `trace.*` and `effect.*` messages with all three), and
  payload values in `$`-tagged wire shape that a value-decoding reader
  would silently rewrite.
  """

  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Message

  @fixture_path Path.join([__DIR__, "..", "..", "support", "trace", "two_state.jsonl"])

  defp fixture, do: File.read!(@fixture_path)

  describe "decode_lines/1 then encode_lines/1" do
    test "reproduces the golden capture byte-for-byte" do
      bytes = fixture()

      assert {:ok, messages} = Json.decode_lines(bytes)
      assert Json.encode_lines(messages) == bytes
    end

    test "reads back every message in the fixture, in order" do
      assert {:ok, messages} = Json.decode_lines(fixture())

      assert Enum.map(messages, & &1.seq) == Enum.to_list(0..(length(messages) - 1))
      assert [%Message{type: "session.start", seq: 0} | _rest] = messages
    end

    test "leaves the fixture's own line count intact" do
      lines = fixture() |> String.split("\n", trim: true)

      assert {:ok, messages} = Json.decode_lines(fixture())
      assert length(messages) == length(lines)
    end
  end

  describe "the envelope/payload split" do
    test "a session.start carries no counters and keeps its payload" do
      assert {:ok, [start | _rest]} = Json.decode_lines(fixture())

      assert %Message{macrostep: nil, microstep: nil, round: nil, otel: nil} = start
      assert Map.has_key?(start.payload, "version")
      assert Map.has_key?(start.payload, "states")

      refute Enum.any?(
               ~w(type session seq macrostep microstep round otel),
               &Map.has_key?(start.payload, &1)
             )
    end

    test "a trace.* message carries all three counters off the payload" do
      assert {:ok, messages} = Json.decode_lines(fixture())

      traced = Enum.find(messages, &String.starts_with?(&1.type, "trace."))

      assert %Message{macrostep: macrostep, microstep: microstep, round: round} = traced
      assert is_integer(macrostep) and is_integer(microstep) and is_integer(round)
      refute Map.has_key?(traced.payload, "macrostep")
    end

    test "from_map/1 inverts to_map/1 for every message in the fixture" do
      assert {:ok, messages} = Json.decode_lines(fixture())

      for message <- messages do
        assert {:ok, ^message} = message |> Message.to_map() |> Message.from_map()
      end
    end
  end

  describe "malformed input" do
    test "a line that is not JSON names its line number" do
      document = ~s({"type":"a","session":"s","seq":0}\nnot json\n)

      assert {:error, {:line, 2, {:json, _reason}}} = Json.decode_lines(document)
    end

    test "a JSON object missing an envelope key names the key" do
      assert {:error, {:line, 1, {:missing_envelope_key, "seq"}}} =
               Json.decode_lines(~s({"type":"a","session":"s"}\n))
    end

    test "a seq of the wrong shape is refused with its value" do
      assert {:error, {:invalid_envelope_value, "seq", "0"}} =
               Json.decode(~s({"type":"a","session":"s","seq":"0"}))
    end

    test "a JSON array is not an object" do
      assert {:error, {:not_an_object, []}} = Json.decode("[]")
    end

    test "blank lines are skipped rather than failing the read" do
      assert {:ok, [%Message{seq: 0}]} =
               Json.decode_lines(~s(\n{"type":"a","session":"s","seq":0}\n\n))
    end
  end
end
