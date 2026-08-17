defmodule StatifierUI.Trace.MessageTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Message

  describe "to_map/1 - envelope merge" do
    test "always includes type, session, and seq" do
      message = %Message{type: "effect.log", session: "sess_1", seq: 3}

      assert Message.to_map(message) == %{
               "type" => "effect.log",
               "session" => "sess_1",
               "seq" => 3
             }
    end

    test "includes macrostep, microstep, and round when set" do
      message = %Message{
        type: "trace.entry_set",
        session: "sess_1",
        seq: 4,
        macrostep: 1,
        microstep: 1,
        round: 0,
        payload: %{"indexes" => [2]}
      }

      assert Message.to_map(message) == %{
               "type" => "trace.entry_set",
               "session" => "sess_1",
               "seq" => 4,
               "macrostep" => 1,
               "microstep" => 1,
               "round" => 0,
               "indexes" => [2]
             }
    end

    test "omits macrostep, microstep, and round when nil" do
      message = %Message{
        type: "session.halted",
        session: "sess_1",
        seq: 5,
        payload: %{"reason" => "done"}
      }

      map = Message.to_map(message)

      refute Map.has_key?(map, "macrostep")
      refute Map.has_key?(map, "microstep")
      refute Map.has_key?(map, "round")
      assert map["reason"] == "done"
    end

    test "merges payload keys alongside the envelope" do
      message = %Message{
        type: "effect.cancel_invoke",
        session: "sess_1",
        seq: 2,
        payload: %{"invoke_id" => "inv1", "state_index" => 3}
      }

      assert Message.to_map(message) == %{
               "type" => "effect.cancel_invoke",
               "session" => "sess_1",
               "seq" => 2,
               "invoke_id" => "inv1",
               "state_index" => 3
             }
    end
  end

  describe "validate/1 - reserved payload keys" do
    test "accepts a message whose payload carries no reserved key" do
      message = %Message{
        type: "effect.log",
        session: "sess_1",
        seq: 0,
        payload: %{"label" => "hi"}
      }

      assert Message.validate(message) == {:ok, message}
    end

    test "rejects a payload key colliding with type" do
      message = %Message{
        type: "effect.log",
        session: "sess_1",
        seq: 0,
        payload: %{"type" => "oops"}
      }

      assert Message.validate(message) == {:error, {:reserved_payload_key, "type"}}
    end

    test "rejects a payload key colliding with session" do
      message = %Message{
        type: "effect.log",
        session: "sess_1",
        seq: 0,
        payload: %{"session" => "oops"}
      }

      assert Message.validate(message) == {:error, {:reserved_payload_key, "session"}}
    end

    test "rejects a payload key colliding with seq" do
      message = %Message{type: "effect.log", session: "sess_1", seq: 0, payload: %{"seq" => 99}}

      assert Message.validate(message) == {:error, {:reserved_payload_key, "seq"}}
    end

    test "rejects a payload key colliding with macrostep, microstep, or round" do
      for key <- ~w(macrostep microstep round) do
        message = %Message{type: "effect.log", session: "sess_1", seq: 0, payload: %{key => 1}}

        assert Message.validate(message) == {:error, {:reserved_payload_key, key}}
      end
    end
  end
end
