defmodule StatifierUI.Value do
  @moduledoc """
  Codec for ADR-0005's JSON encoding of `Predicator.Types.value/0`.

  `decode/1` reads a JSON-decoded term (as produced by the stdlib `JSON`
  module) and recovers the predicator value it encodes, resolving the
  `$`-prefixed one-key tagged shapes ADR-0005 reserves: `$undefined`,
  `$date`, `$datetime`, `$duration`. `encode/1` is the inverse, present so
  the codec is round-trip testable; it is not wired to any writer.

  JSON-native values (booleans, numbers, strings, `nil`, lists, ordinary
  maps) map to themselves in both directions. JSON `null` always decodes to
  `nil` - a present, null value - never to the `:undefined` sentinel, which
  has its own tagged encoding because absence has no positional spelling
  inside a list or map value.
  """

  @duration_units [
    :years,
    :months,
    :weeks,
    :days,
    :hours,
    :minutes,
    :seconds,
    :milliseconds
  ]

  @duration_unit_strings Map.new(@duration_units, &{Atom.to_string(&1), &1})

  @doc """
  Decodes a JSON-decoded term into a predicator value.

  Recurses through lists and map values. A one-key map whose key starts
  with `$` and is not one of the four reserved tags is an error: ADR-0005
  reserves the whole one-key `$`-prefixed shape, so an unrecognized tag is a
  spec violation on the producer's side rather than a host map to pass
  through. A multi-key map containing a `$`-prefixed key is an ordinary host
  map.

  ## Examples

      iex> StatifierUI.Value.decode(1999)
      {:ok, 1999}

      iex> StatifierUI.Value.decode(nil)
      {:ok, nil}

      iex> StatifierUI.Value.decode(%{"$undefined" => true})
      {:ok, :undefined}

  """
  @spec decode(term()) :: {:ok, term()} | {:error, term()}
  def decode(%{"$undefined" => true} = map) when map_size(map) == 1, do: {:ok, :undefined}

  def decode(%{"$date" => value} = map) when map_size(map) == 1 do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, reason} -> {:error, {:invalid_date, value, reason}}
    end
  end

  def decode(%{"$datetime" => value} = map) when map_size(map) == 1 do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_datetime, value, reason}}
    end
  end

  def decode(%{"$duration" => value} = map) when map_size(map) == 1 do
    decode_duration(value)
  end

  def decode(map) when is_map(map) and map_size(map) == 1 do
    case Map.keys(map) do
      ["$" <> _rest = key] -> {:error, {:unknown_tag, key}}
      _other -> decode_host_map(map)
    end
  end

  def decode(map) when is_map(map), do: decode_host_map(map)

  def decode(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case decode(element) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  def decode(scalar), do: {:ok, scalar}

  @doc """
  Encodes a predicator value into its ADR-0005 JSON-native term.

  The inverse of `decode/1`. Not wired to any writer; present so the codec
  is round-trip testable.

  ## Examples

      iex> StatifierUI.Value.encode(:undefined)
      {:ok, %{"$undefined" => true}}

      iex> StatifierUI.Value.encode(1999)
      {:ok, 1999}

  """
  @spec encode(term()) :: {:ok, term()} | {:error, term()}
  def encode(:undefined), do: {:ok, %{"$undefined" => true}}
  def encode(%Date{} = date), do: {:ok, %{"$date" => Date.to_iso8601(date)}}
  def encode(%DateTime{} = datetime), do: {:ok, %{"$datetime" => DateTime.to_iso8601(datetime)}}

  def encode(map) when is_map(map) do
    if duration?(map) do
      encode_duration(map)
    else
      encode_host_map(map)
    end
  end

  def encode(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn element, {:ok, acc} ->
      case encode(element) do
        {:ok, encoded} -> {:cont, {:ok, [encoded | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, _reason} = error -> error
    end
  end

  def encode(scalar), do: {:ok, scalar}

  @spec duration?(map()) :: boolean()
  defp duration?(map) do
    keys = map |> Map.keys() |> MapSet.new()

    MapSet.equal?(keys, MapSet.new(@duration_units)) and
      Enum.all?(map, fn {_key, value} -> is_integer(value) end)
  end

  @spec encode_duration(map()) :: {:ok, map()}
  defp encode_duration(duration) do
    encoded =
      Map.new(@duration_units, fn unit -> {Atom.to_string(unit), Map.get(duration, unit, 0)} end)

    {:ok, %{"$duration" => encoded}}
  end

  @spec decode_duration(term()) :: {:ok, map()} | {:error, term()}
  defp decode_duration(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, unit_value}, {:ok, acc} ->
      case decode_duration_unit(key, unit_value) do
        {:ok, unit, int_value} -> {:cont, {:ok, Map.put(acc, unit, int_value)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} ->
        {:ok, Map.new(@duration_units, fn unit -> {unit, Map.get(decoded, unit, 0)} end)}

      {:error, _reason} = error ->
        error
    end
  end

  defp decode_duration(other), do: {:error, {:invalid_duration, other}}

  @spec decode_duration_unit(term(), term()) :: {:ok, atom(), integer()} | {:error, term()}
  defp decode_duration_unit(key, value) when is_integer(value) do
    case Map.fetch(@duration_unit_strings, key) do
      {:ok, unit} -> {:ok, unit, value}
      :error -> {:error, {:unknown_duration_unit, key}}
    end
  end

  defp decode_duration_unit(key, value), do: {:error, {:invalid_duration_value, key, value}}

  @spec decode_host_map(map()) :: {:ok, map()} | {:error, term()}
  defp decode_host_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case decode(value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, key, decoded)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec encode_host_map(map()) :: {:ok, map()} | {:error, term()}
  defp encode_host_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case encode(value) do
        {:ok, encoded} -> {:cont, {:ok, Map.put(acc, key, encoded)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
