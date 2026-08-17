defmodule StatifierUI.Trace.Json do
  @moduledoc """
  The canonical JSON encoder that makes ADR-0005's byte-comparable golden
  traces real.

  `JSON.encode!/1` alone is not enough: Erlang map iteration order tracks
  insertion order only below the small-map threshold, so two runs of the
  same producer can build the same keys in different orders and get
  different bytes back. `encode/1` walks the term itself instead - objects
  emit their keys in `Enum.sort/1` (lexicographic) order at every nesting
  level, arrays emit in the order given (the producer has already put them
  in the order `docs/wire-format.md` requires), and every scalar and string
  is delegated to `JSON.encode_to_iodata!/1` so escaping is the stdlib's
  problem, not this module's.

  This encoder rejects nothing: a term outside `StatifierUI.Trace.Message.json()`
  is a producer bug that `JSON.encode_to_iodata!/1` raises on, which is the
  right failure for an invariant `StatifierUI.Trace.Normalizer` is supposed
  to have already established.
  """

  alias StatifierUI.Trace.Message

  @doc """
  Encodes a JSON-ready term to canonical iodata - object keys lexicographic
  at every level, arrays in the order given.
  """
  @spec encode(Message.json()) :: iodata()
  def encode(map) when is_map(map) do
    entries =
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> [encode_key(key), ?:, encode(value)] end)
      |> Enum.intersperse(?,)

    [?{, entries, ?}]
  end

  def encode(list) when is_list(list) do
    entries = list |> Enum.map(&encode/1) |> Enum.intersperse(?,)
    [?[, entries, ?]]
  end

  def encode(scalar), do: JSON.encode_to_iodata!(scalar)

  @doc """
  `encode/1`, flattened to a binary.
  """
  @spec encode_to_string(Message.json()) :: String.t()
  def encode_to_string(term), do: term |> encode() |> IO.iodata_to_binary()

  @doc """
  Renders one `%Message{}` to a canonical JSON string - `Message.to_map/1`
  followed by `encode_to_string/1`.
  """
  @spec encode_message(Message.t()) :: String.t()
  def encode_message(%Message{} = message) do
    message |> Message.to_map() |> encode_to_string()
  end

  @doc """
  Renders a list of messages as JSON Lines: one `encode_message/1` result
  per line, each terminated by `"\\n"` - the shape the golden fixtures use.
  """
  @spec encode_lines([Message.t()]) :: String.t()
  def encode_lines(messages) do
    messages
    |> Enum.map(&(encode_message(&1) <> "\n"))
    |> IO.iodata_to_binary()
  end

  @spec encode_key(String.t()) :: iodata()
  defp encode_key(key), do: JSON.encode_to_iodata!(key)
end
