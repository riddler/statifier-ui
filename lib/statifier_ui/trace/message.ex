defmodule StatifierUI.Trace.Message do
  @moduledoc """
  One message of the trace wire format (`docs/wire-format.md`), held as a
  struct in process and rendered to the documented JSON object by `to_map/1`.

  The envelope fields (`type`, `session`, `seq`, and the counters
  `macrostep`/`microstep`/`round`, carried by `trace.*` and `effect.*`
  messages and by no `session.*` message) live on the struct directly; everything
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
          payload: %{optional(String.t()) => json()}
        }

  @enforce_keys [:type, :session, :seq]
  defstruct [:type, :session, :seq, :macrostep, :microstep, :round, payload: %{}]

  @reserved_keys ~w(type session seq macrostep microstep round)

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
  `"microstep"`, and `"round"` are present only when non-`nil` (decisions 3
  and 5, amended by sui-67d - `trace.*` and `effect.*` messages carry all
  three, `session.*` messages carry
  none of the three). Specced for a valid message: call `validate/1` first,
  or construct through `StatifierUI.Trace.Normalizer`, which always does.
  """
  @spec to_map(t()) :: %{optional(String.t()) => json()}
  def to_map(%__MODULE__{} = message) do
    envelope =
      %{"type" => message.type, "session" => message.session, "seq" => message.seq}
      |> put_present("macrostep", message.macrostep)
      |> put_present("microstep", message.microstep)
      |> put_present("round", message.round)

    Map.merge(message.payload, envelope)
  end

  @spec put_present(map(), String.t(), json() | nil) :: map()
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
