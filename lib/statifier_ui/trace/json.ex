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

  @doc """
  Reads one JSON object - a single JSON Lines line - back into a
  `%Message{}`.

  The inverse of `encode_message/1`, and the function
  `docs/ops-embedding.md` tells a host to call over a persisted stream.
  Decoding is structural only: `StatifierUI.Trace.Message.from_map/1`
  splits the envelope from the payload and leaves payload values in wire
  shape, so `encode_message/1` over the result reproduces the input bytes
  exactly (`encode/1` is canonical, so key order cannot drift).

  A line that is not JSON is `{:error, {:json, reason}}`; valid JSON that
  is not a well-formed envelope is the tagged error
  `StatifierUI.Trace.Message.from_map/1` returned.
  """
  @spec decode(String.t()) :: {:ok, Message.t()} | {:error, term()}
  def decode(line) when is_binary(line) do
    case JSON.decode(line) do
      {:ok, map} -> Message.from_map(map)
      {:error, reason} -> {:error, {:json, reason}}
    end
  end

  @doc """
  Reads a JSON Lines document back into a message list - the inverse of
  `encode_lines/1`.

  Blank lines are skipped, so the trailing newline `encode_lines/1` writes
  round-trips cleanly and a hand-edited file with a stray blank line still
  loads. The first line that fails stops the read and is reported as
  `{:error, {:line, number, reason}}`, one-based, because "which line"
  is the first thing anyone debugging a truncated capture needs.
  """
  @spec decode_lines(String.t()) ::
          {:ok, [Message.t()]} | {:error, {:line, pos_integer(), term()}}
  def decode_lines(document) when is_binary(document) do
    document
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _number} -> String.trim(line) == "" end)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
      case decode(line) do
        {:ok, message} -> {:cont, {:ok, [message | acc]}}
        {:error, reason} -> {:halt, {:error, {:line, number, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_key(String.t()) :: iodata()
  defp encode_key(key), do: JSON.encode_to_iodata!(key)
end
