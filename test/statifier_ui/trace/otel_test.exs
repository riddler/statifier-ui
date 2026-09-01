defmodule StatifierUI.Trace.OtelTest do
  use ExUnit.Case, async: true

  doctest StatifierUI.Trace.Otel

  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Otel

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @span_id "00f067aa0ba902b7"

  defp resolver(trace_id \\ @trace_id, span_id \\ @span_id) do
    fn _session, _macrostep -> {:ok, %{trace_id: trace_id, span_id: span_id}} end
  end

  defp message(type, fields \\ []) do
    struct!(
      %Message{type: type, session: "sess_1", seq: 7, macrostep: 2, microstep: 1, round: 0},
      fields
    )
  end

  describe "stamp/2 - where the key is legal" do
    test "stamps trace.* and effect.* messages carrying a macrostep" do
      for type <- ["trace.entry_set", "trace.macrostep_stable", "effect.log", "effect.done"] do
        assert Otel.stamp(message(type), resolver()).otel == %{
                 "span_id" => @span_id,
                 "trace_id" => @trace_id
               }
      end
    end

    test "never stamps a session.* message, even with a resolver attached" do
      for type <- [
            "session.start",
            "session.datamodel",
            "session.halted",
            "session.terminated",
            "session.unroutable"
          ] do
        assert Otel.stamp(message(type, macrostep: nil), resolver()).otel == nil
      end
    end

    test "does not stamp a trace.* message with no macrostep" do
      assert Otel.stamp(message("trace.entry_set", macrostep: nil), resolver()).otel == nil
    end

    test "correlatable?/1 tracks the same rule" do
      assert Otel.correlatable?(message("trace.entry_set"))
      assert Otel.correlatable?(message("effect.log"))
      refute Otel.correlatable?(message("session.start", macrostep: nil))
      refute Otel.correlatable?(message("trace.entry_set", macrostep: nil))
    end
  end

  describe "stamp/2 - absence is the failure mode" do
    test "a nil resolver leaves every message untouched" do
      original = message("trace.entry_set")

      assert Otel.stamp(original, nil) == original
    end

    test ":none leaves the key absent" do
      assert Otel.stamp(message("trace.entry_set"), fn _s, _m -> :none end).otel == nil
    end

    test "a half pair is omitted rather than written" do
      halves = [
        fn _s, _m -> {:ok, %{trace_id: @trace_id}} end,
        fn _s, _m -> {:ok, %{span_id: @span_id}} end,
        fn _s, _m -> {:ok, %{trace_id: @trace_id, span_id: nil}} end
      ]

      for half <- halves do
        assert Otel.stamp(message("trace.entry_set"), half).otel == nil
      end
    end

    test "a malformed id is omitted - the encoding is W3C Trace Context hex" do
      malformed = [
        # uppercase
        {String.upcase(@trace_id), @span_id},
        {@trace_id, String.upcase(@span_id)},
        # wrong length
        {String.slice(@trace_id, 0..30), @span_id},
        {@trace_id <> "0", @span_id},
        {@trace_id, String.slice(@span_id, 0..14)},
        # a span id where a trace id belongs, and the reverse
        {@span_id, @span_id},
        {@trace_id, @trace_id},
        # prefixed / punctuated
        {"0x" <> String.slice(@trace_id, 0..29), @span_id},
        {@trace_id, "00f067aa-0ba902b"}
      ]

      for {trace_id, span_id} <- malformed do
        assert Otel.stamp(message("trace.entry_set"), resolver(trace_id, span_id)).otel == nil,
               "expected #{inspect({trace_id, span_id})} to be rejected"
      end
    end

    test "an unrecognized return shape is omitted" do
      shapes = [
        fn _s, _m -> :ok end,
        fn _s, _m -> {:ok, %{"trace_id" => @trace_id, "span_id" => @span_id}} end,
        fn _s, _m -> {:error, :no_span} end,
        fn _s, _m -> nil end
      ]

      for shape <- shapes do
        assert Otel.stamp(message("trace.entry_set"), shape).otel == nil
      end
    end

    test "a resolver that raises, exits, or throws is treated as :none" do
      failing = [
        fn _s, _m -> raise "boom" end,
        fn _s, _m -> exit(:boom) end,
        fn _s, _m -> throw(:boom) end
      ]

      for resolver <- failing do
        assert Otel.stamp(message("trace.entry_set"), resolver).otel == nil
      end
    end
  end

  describe "stamp/2 - what the resolver is given" do
    test "is called with this message's session id and macrostep" do
      test_pid = self()

      resolver = fn session, macrostep ->
        send(test_pid, {:resolved, session, macrostep})
        :none
      end

      Otel.stamp(message("trace.entry_set", session: "sess_9", macrostep: 4), resolver)

      assert_received {:resolved, "sess_9", 4}
    end
  end

  describe "the stamped key on the wire" do
    test "renders as the documented object beside the counters" do
      map = message("trace.entry_set") |> Otel.stamp(resolver()) |> Message.to_map()

      assert map["otel"] == %{"span_id" => @span_id, "trace_id" => @trace_id}
      assert map["macrostep"] == 2
    end

    test "encodes with canonically sorted keys" do
      json = message("trace.entry_set") |> Otel.stamp(resolver()) |> Json.encode_message()

      assert json =~ ~s("otel":{"span_id":"#{@span_id}","trace_id":"#{@trace_id}"})
    end

    test "an unstamped message encodes exactly as it did before - never null, never {}" do
      json =
        message("trace.entry_set") |> Otel.stamp(fn _s, _m -> :none end) |> Json.encode_message()

      refute json =~ "otel"
    end
  end
end
