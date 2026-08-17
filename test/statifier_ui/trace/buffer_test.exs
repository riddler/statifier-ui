defmodule StatifierUI.Trace.BufferTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Buffer
  alias StatifierUI.Trace.Message

  defp message(seq) do
    %Message{type: "trace.event_dequeued", session: "s", seq: seq}
  end

  defp seqs(buffer), do: Enum.map(Buffer.to_list(buffer), & &1.seq)

  describe "new/1 - construction" do
    test "builds an empty buffer with the given capacity" do
      buffer = Buffer.new(10)

      assert buffer.capacity == 10
      assert Buffer.size(buffer) == 0
      assert Buffer.dropped(buffer) == 0
      assert Buffer.to_list(buffer) == []
    end

    test "a capacity of 1 is valid" do
      buffer = Buffer.new(1)

      assert buffer.capacity == 1
    end

    test "raises ArgumentError on a zero capacity" do
      assert_raise ArgumentError, fn -> Buffer.new(0) end
    end

    test "raises ArgumentError on a negative capacity" do
      assert_raise ArgumentError, fn -> Buffer.new(-1) end
    end
  end

  describe "push/2 - under capacity" do
    test "grows size and keeps every message" do
      buffer =
        Buffer.new(5)
        |> Buffer.push(message(0))
        |> Buffer.push(message(1))

      assert Buffer.size(buffer) == 2
      assert Buffer.dropped(buffer) == 0
      assert seqs(buffer) == [0, 1]
    end
  end

  describe "push/2 - exactly at capacity" do
    test "holds every message with no drops" do
      buffer = Enum.reduce(0..4, Buffer.new(5), fn seq, acc -> Buffer.push(acc, message(seq)) end)

      assert Buffer.size(buffer) == 5
      assert Buffer.dropped(buffer) == 0
      assert seqs(buffer) == [0, 1, 2, 3, 4]
    end
  end

  describe "push/2 - one over capacity" do
    test "drops the oldest, keeps the newest, and counts one drop" do
      buffer =
        Enum.reduce(0..5, Buffer.new(5), fn seq, acc -> Buffer.push(acc, message(seq)) end)

      assert Buffer.size(buffer) == 5
      assert Buffer.dropped(buffer) == 1
      assert seqs(buffer) == [1, 2, 3, 4, 5]
    end
  end

  describe "push/2 - many over capacity" do
    test "dropped counts every loss and size stays pinned at capacity" do
      capacity = 10
      overflow = 50

      buffer =
        Enum.reduce(0..(capacity + overflow - 1), Buffer.new(capacity), fn seq, acc ->
          Buffer.push(acc, message(seq))
        end)

      assert Buffer.size(buffer) == capacity
      assert Buffer.dropped(buffer) == overflow
      assert seqs(buffer) == Enum.to_list(overflow..(capacity + overflow - 1))
    end

    test "capacity + 50 messages leaves size == capacity, dropped == 50, first seq == 50" do
      capacity = 1000
      overflow = 50

      buffer =
        Enum.reduce(0..(capacity + overflow - 1), Buffer.new(capacity), fn seq, acc ->
          Buffer.push(acc, message(seq))
        end)

      assert Buffer.size(buffer) == capacity
      assert Buffer.dropped(buffer) == overflow
      assert [%Message{seq: 50} | _] = Buffer.to_list(buffer)
    end
  end

  describe "to_list/1 - ordering" do
    test "returns messages oldest-first, matching push order" do
      buffer =
        Buffer.new(3)
        |> Buffer.push(message(0))
        |> Buffer.push(message(1))
        |> Buffer.push(message(2))

      assert seqs(buffer) == [0, 1, 2]
    end
  end

  describe "clear/1 - reset" do
    test "empties entries, preserves capacity, and resets dropped" do
      buffer =
        Enum.reduce(0..9, Buffer.new(5), fn seq, acc -> Buffer.push(acc, message(seq)) end)

      assert Buffer.dropped(buffer) == 5

      cleared = Buffer.clear(buffer)

      assert cleared.capacity == 5
      assert Buffer.size(cleared) == 0
      assert Buffer.dropped(cleared) == 0
      assert Buffer.to_list(cleared) == []
    end
  end

  describe "decision 8 - seq gap is the drop record" do
    test "after overflow, the first entry's seq is greater than 0" do
      buffer =
        Enum.reduce(0..9, Buffer.new(5), fn seq, acc -> Buffer.push(acc, message(seq)) end)

      assert [%Message{seq: first_seq} | _] = Buffer.to_list(buffer)
      assert first_seq > 0
    end
  end
end
