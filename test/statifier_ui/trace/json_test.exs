defmodule StatifierUI.Trace.JsonTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Message

  describe "encode_to_string/1 - canonical key order" do
    test "orders keys lexicographically regardless of build order" do
      forward = %{"a" => 1, "b" => 2, "c" => 3}
      reverse = %{"c" => 3, "b" => 2, "a" => 1}

      assert Json.encode_to_string(forward) == Json.encode_to_string(reverse)
      assert Json.encode_to_string(forward) == ~s({"a":1,"b":2,"c":3})
    end

    test "stays order-stable at 32 keys, past Erlang's small-map threshold" do
      keys = for n <- 1..32, do: "k#{String.pad_leading(Integer.to_string(n), 2, "0")}"

      built_forward = Map.new(keys, &{&1, 1})
      built_backward = Map.new(Enum.reverse(keys), &{&1, 1})

      assert Json.encode_to_string(built_forward) == Json.encode_to_string(built_backward)

      expected_key_order = Enum.sort(keys)

      decoded_order =
        Regex.scan(~r/"(k\d\d)"/, Json.encode_to_string(built_forward), capture: :all_but_first)

      assert List.flatten(decoded_order) == expected_key_order
    end

    test "sorts nested objects at every level" do
      term = %{"outer_b" => %{"z" => 1, "a" => 2}, "outer_a" => 1}

      assert Json.encode_to_string(term) == ~s({"outer_a":1,"outer_b":{"a":2,"z":1}})
    end

    test "preserves array order" do
      assert Json.encode_to_string([3, 1, 2]) == "[3,1,2]"
    end

    test "delegates string escaping to the stdlib for keys and values" do
      term = %{"a \"quoted\" key\nwith a newline" => "a \"quoted\" value\nwith a newline"}

      assert Json.encode_to_string(term) ==
               ~s({"a \\"quoted\\" key\\nwith a newline":"a \\"quoted\\" value\\nwith a newline"})
    end
  end

  describe "encode_message/1" do
    test "renders a message's to_map/1 result as canonical JSON" do
      message = %Message{
        type: "session.halted",
        session: "sess_1",
        seq: 1,
        payload: %{"reason" => "done"}
      }

      assert Json.encode_message(message) ==
               ~s({"reason":"done","seq":1,"session":"sess_1","type":"session.halted"})
    end
  end

  describe "encode_lines/1" do
    test "joins each encoded message with a trailing newline" do
      messages = [
        %Message{type: "session.start", session: "sess_1", seq: 0, payload: %{"version" => 1}},
        %Message{
          type: "session.halted",
          session: "sess_1",
          seq: 1,
          payload: %{"reason" => "done"}
        }
      ]

      assert Json.encode_lines(messages) ==
               ~s({"seq":0,"session":"sess_1","type":"session.start","version":1}\n) <>
                 ~s({"reason":"done","seq":1,"session":"sess_1","type":"session.halted"}\n)
    end

    test "returns an empty string for no messages" do
      assert Json.encode_lines([]) == ""
    end
  end
end
