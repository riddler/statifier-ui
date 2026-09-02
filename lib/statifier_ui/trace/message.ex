defmodule StatifierUI.Trace.Message do
  @moduledoc """
  One message of the trace wire format (`docs/wire-format.md`), held as a
  struct in process and rendered to the documented JSON object by `to_map/1`.

  The envelope fields (`type`, `session`, `seq`, the counters
  `macrostep`/`microstep`/`round`, carried by `trace.*` and `effect.*`
  messages and by no `session.*` message, and the optional `otel`
  correlation object legal in exactly the same places) live on the struct
  directly; everything
  type-specific lives in `payload`, already in wire shape - a string-keyed
  map ready to merge over the envelope. This is decision 1 of the plan: one
  envelope struct rather than one struct per message type, so the spec stays
  the single definition site of what a payload contains.

  A payload key is never allowed to collide with an envelope key - that
  would be a producer bug, silently resolved by whichever side `to_map/1`
  happened to favor. `validate/1` catches it explicitly; `StatifierUI.Trace.Normalizer`
  calls it on every message it builds, so by the time anything else sees a
  `%Message{}` the invariant already holds and `to_map/1` can be specced for
  a valid message.
  """

  @typedoc "A JSON-ready term - the codomain every payload value must land in."
  @type json ::
          nil
          | boolean()
          | integer()
          | float()
          | String.t()
          | [json()]
          | %{optional(String.t()) => json()}

  @type t :: %__MODULE__{
          type: String.t(),
          session: String.t(),
          seq: non_neg_integer(),
          macrostep: non_neg_integer() | nil,
          microstep: non_neg_integer() | nil,
          round: non_neg_integer() | nil,
          otel: %{optional(String.t()) => String.t()} | nil,
          payload: %{optional(String.t()) => json()}
        }

  @enforce_keys [:type, :session, :seq]
  defstruct [:type, :session, :seq, :macrostep, :microstep, :round, :otel, payload: %{}]

  @reserved_keys ~w(type session seq macrostep microstep round otel)

  @doc """
  Checks that `message`'s payload carries no key reserved for the envelope.

  Returns `{:error, {:reserved_payload_key, key}}` naming the first
  colliding key found, rather than letting the envelope silently win in
  `to_map/1`. Called by `StatifierUI.Trace.Normalizer` on every message it
  builds, so any other caller can treat a `%Message{}` it receives as
  already valid.

  ## Examples

      iex> message = %StatifierUI.Trace.Message{type: "effect.log", session: "s", seq: 0}
      iex> StatifierUI.Trace.Message.validate(message)
      {:ok, message}

  """
  @spec validate(t()) :: {:ok, t()} | {:error, {:reserved_payload_key, String.t()}}
  def validate(%__MODULE__{payload: payload} = message) do
    case Enum.find(@reserved_keys, &Map.has_key?(payload, &1)) do
      nil -> {:ok, message}
      key -> {:error, {:reserved_payload_key, key}}
    end
  end

  @doc """
  Renders `message` to the documented JSON object: the envelope merged over
  the payload.

  `"type"`, `"session"`, and `"seq"` are always present; `"macrostep"`,
  `"microstep"`, `"round"`, and `"otel"` are present only when non-`nil`
  (decisions 3 and 5, amended by sui-67d - `trace.*` and `effect.*` messages
  carry all three counters, `session.*` messages carry
  none of the three; `otel` is stamped only where a counter is legal and
  only when a host attached a resolver, ADR-0013). Specced for a valid
  message: call `validate/1` first, or construct through
  `StatifierUI.Trace.Normalizer`, which always does.
  """
  @spec to_map(t()) :: %{optional(String.t()) => json()}
  def to_map(%__MODULE__{} = message) do
    envelope =
      %{"type" => message.type, "session" => message.session, "seq" => message.seq}
      |> put_present("macrostep", message.macrostep)
      |> put_present("microstep", message.microstep)
      |> put_present("round", message.round)
      |> put_present("otel", message.otel)

    Map.merge(message.payload, envelope)
  end

  @doc """
  Reads a decoded JSON object back into a `%Message{}` - the inverse of
  `to_map/1`.

  The seven reserved keys become envelope fields and everything else
  becomes `payload`, which is the whole of the transform: **payload values
  are not decoded**. `payload` holds wire-shape terms by definition (see
  the moduledoc), and the consumers that want Elixir terms call
  `StatifierUI.Value.decode/1` themselves at read time -
  `StatifierUI.DatamodelExplorer` documents at its own decode site why
  decoding a second time would re-read an already-decoded `Date` as a
  `$`-tagged map. Staying structural is also what makes the round trip
  exact: re-encoding the result of `from_map/1` reproduces the bytes it was
  read from.

  Absent optional keys stay `nil`, mirroring `to_map/1` omitting them.
  A missing `type`, `session`, or `seq` is
  `{:error, {:missing_envelope_key, key}}`; a present one of the wrong
  shape is `{:error, {:invalid_envelope_value, key, value}}`. Both are
  malformed input rather than producer bugs, so they are values and not
  raises.

  ## Examples

      iex> StatifierUI.Trace.Message.from_map(%{"type" => "effect.log", "session" => "s", "seq" => 0})
      {:ok, %StatifierUI.Trace.Message{type: "effect.log", session: "s", seq: 0}}

      iex> StatifierUI.Trace.Message.from_map(%{"type" => "effect.log", "session" => "s"})
      {:error, {:missing_envelope_key, "seq"}}

  """
  @spec from_map(map()) :: {:ok, t()} | {:error, from_map_error()}
  def from_map(map) when is_map(map) do
    with {:ok, type} <- fetch_string(map, "type"),
         {:ok, session} <- fetch_string(map, "session"),
         {:ok, seq} <- fetch_seq(map) do
      {:ok,
       %__MODULE__{
         type: type,
         session: session,
         seq: seq,
         macrostep: Map.get(map, "macrostep"),
         microstep: Map.get(map, "microstep"),
         round: Map.get(map, "round"),
         otel: Map.get(map, "otel"),
         payload: Map.drop(map, @reserved_keys)
       }}
    end
  end

  def from_map(other), do: {:error, {:not_an_object, other}}

  @typedoc "Why `from_map/1` refused a term."
  @type from_map_error ::
          {:not_an_object, term()}
          | {:missing_envelope_key, String.t()}
          | {:invalid_envelope_value, String.t(), term()}

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, from_map_error()}
  defp fetch_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_envelope_value, key, value}}
      :error -> {:error, {:missing_envelope_key, key}}
    end
  end

  @spec fetch_seq(map()) :: {:ok, non_neg_integer()} | {:error, from_map_error()}
  defp fetch_seq(map) do
    case Map.fetch(map, "seq") do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_envelope_value, "seq", value}}
      :error -> {:error, {:missing_envelope_key, "seq"}}
    end
  end

  @spec put_present(map(), String.t(), json() | nil) :: map()
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
