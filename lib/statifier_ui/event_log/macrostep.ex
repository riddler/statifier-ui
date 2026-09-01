defmodule StatifierUI.EventLog.Macrostep do
  @moduledoc """
  One macrostep's worth of an `StatifierUI.EventLog.t()`: its rounds, its
  round-less `effect.*` messages, and two summaries derived from its rounds
  rather than carried on any single message.

  `configuration` is the configuration of the *last* round (by round order)
  that carried a `trace.macrostep_stable` - statifier ADR-0044's rule that
  the last-arriving `trace.macrostep_stable` in a macrostep is that
  macrostep's quiescence, since a stream may carry more than one. `event`
  is the first round's dequeued event, `nil` for the initialize burst,
  which lets a collapsed macrostep be summarized by what triggered it
  without inspecting every round.

  `final_configuration` is the same reading for the *halting* macrostep
  (sui-dc7). A run that ends by entering a top-level `<final>` never
  reaches quiescence in that macrostep, so it emits no
  `trace.macrostep_stable` at all; `trace.done` carries the configuration
  instead - `docs/wire-format.md`'s `trace.done` row defines its
  `configuration` field as "the full configuration as it stood at exit, a
  genuine set, sorted ascending", the same shape and the same authority as
  a `macrostep_stable` payload. It is kept in its own field rather than
  folded into `configuration` so a reader can still tell a configuration
  the chart *settled* in from the one it *exited* in; `stamped/1` is the
  reading for a caller that only needs "whichever this macrostep stamped".
  """

  alias StatifierUI.EventLog.Round
  alias StatifierUI.Trace.Message

  @type t :: %__MODULE__{
          macrostep: non_neg_integer(),
          rounds: [Round.t()],
          effects: [Message.t()],
          configuration: [non_neg_integer()] | nil,
          final_configuration: [non_neg_integer()] | nil,
          event: map() | nil
        }

  @enforce_keys [:macrostep]
  defstruct [
    :macrostep,
    :configuration,
    :final_configuration,
    :event,
    rounds: [],
    effects: []
  ]

  @doc """
  Builds a macrostep from its already-ordered rounds and its already-sorted
  round-less `effects`, deriving `configuration`, `final_configuration` and
  `event` from `rounds`.
  """
  @spec new(non_neg_integer(), [Round.t()], [Message.t()]) :: t()
  def new(macrostep, rounds, effects) do
    %__MODULE__{
      macrostep: macrostep,
      rounds: rounds,
      effects: effects,
      configuration: last_configuration(rounds),
      final_configuration: last_final_configuration(rounds),
      event: first_event(rounds)
    }
  end

  @doc """
  Whichever configuration this macrostep stamped, exit reading first, or
  `nil` when it stamped neither.

  The exit reading wins because it is the later of the two: a macrostep
  that both stabilized and then halted ended where `trace.done` says it
  did. Callers that must distinguish the two read the fields.
  """
  @spec stamped(t()) :: [non_neg_integer()] | nil
  def stamped(%__MODULE__{final_configuration: nil, configuration: configuration}),
    do: configuration

  def stamped(%__MODULE__{final_configuration: configuration}), do: configuration

  @spec last_configuration([Round.t()]) :: [non_neg_integer()] | nil
  defp last_configuration(rounds) do
    rounds
    |> Enum.map(& &1.configuration)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  # `done` is the whole `trace.done` payload, and its `configuration` key is
  # always present per the wire format - but a projected or truncated stream
  # is data this module does not get to assume about, so a payload without
  # it reads as no stamp rather than as `nil` being a configuration.
  @spec last_final_configuration([Round.t()]) :: [non_neg_integer()] | nil
  defp last_final_configuration(rounds) do
    rounds
    |> Enum.map(fn
      %Round{done: %{"configuration" => configuration}} -> configuration
      %Round{} -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  @spec first_event([Round.t()]) :: map() | nil
  defp first_event([]), do: nil
  defp first_event([%Round{event: event} | _rest]), do: event
end
