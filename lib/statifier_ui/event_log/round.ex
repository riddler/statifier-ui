defmodule StatifierUI.EventLog.Round do
  @moduledoc """
  One `(macrostep, round)` bucket of an `StatifierUI.EventLog.t()`.

  A round is the timeline key the wire format names
  (`docs/wire-format.md:91-94`): the messages an event's dequeue (or, for
  the initialize burst and any eventless probe, the absence of one) sets in
  motion, up to and including the round's own `trace.macrostep_stable` when
  it reached quiescence.

  Every field below is populated by folding this round's messages in
  `{microstep, seq}` order (`StatifierUI.EventLog.build/1`); nothing here is
  computed by inspecting the round's messages a second time, so the struct
  and `messages` never disagree about what happened.
  """

  alias StatifierUI.Trace.Message

  @type t :: %__MODULE__{
          macrostep: non_neg_integer(),
          round: non_neg_integer(),
          event: map() | nil,
          from: String.t() | nil,
          cause: map() | nil,
          eventless?: boolean(),
          t_indexes: [non_neg_integer()] | nil,
          exited: [non_neg_integer()],
          entered: [non_neg_integer()],
          content: [%{owner: map(), c_indexes: [non_neg_integer()]}],
          configuration: [non_neg_integer()] | nil,
          done: map() | nil,
          budget_exhausted: map() | nil,
          messages: [Message.t()]
        }

  @enforce_keys [:macrostep, :round]
  defstruct [
    :macrostep,
    :round,
    :event,
    :from,
    :cause,
    :t_indexes,
    :configuration,
    :done,
    :budget_exhausted,
    eventless?: false,
    exited: [],
    entered: [],
    content: [],
    messages: []
  ]
end
