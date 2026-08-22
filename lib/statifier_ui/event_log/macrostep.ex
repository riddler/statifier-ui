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
  """

  alias StatifierUI.EventLog.Round
  alias StatifierUI.Trace.Message

  @type t :: %__MODULE__{
          macrostep: non_neg_integer(),
          rounds: [Round.t()],
          effects: [Message.t()],
          configuration: [non_neg_integer()] | nil,
          event: map() | nil
        }

  @enforce_keys [:macrostep]
  defstruct [:macrostep, :configuration, :event, rounds: [], effects: []]

  @doc """
  Builds a macrostep from its already-ordered rounds and its already-sorted
  round-less `effects`, deriving `configuration` and `event` from `rounds`.
  """
  @spec new(non_neg_integer(), [Round.t()], [Message.t()]) :: t()
  def new(macrostep, rounds, effects) do
    %__MODULE__{
      macrostep: macrostep,
      rounds: rounds,
      effects: effects,
      configuration: last_configuration(rounds),
      event: first_event(rounds)
    }
  end

  @spec last_configuration([Round.t()]) :: [non_neg_integer()] | nil
  defp last_configuration(rounds) do
    rounds
    |> Enum.map(& &1.configuration)
    |> Enum.reject(&is_nil/1)
    |> List.last()
  end

  @spec first_event([Round.t()]) :: map() | nil
  defp first_event([]), do: nil
  defp first_event([%Round{event: event} | _rest]), do: event
end
