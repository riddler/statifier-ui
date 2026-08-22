defmodule StatifierUI.EventLog do
  @moduledoc """
  Folds a `[StatifierUI.Trace.Message.t()]` (in any order) into a readable
  log keyed by `(macrostep, round)`, per the sui-t36.5 plan.

  `build/1` is a pure regrouping, not an interpretation: it decides where
  each message goes, never what it means. Ordering comes entirely from the
  stamps the producer put on each message, never from arrival order or
  `seq` alone - `docs/wire-format.md:91-94` names `(macrostep, round)` as
  the format's own timeline key. Feeding `build/1` the same messages in a
  different order returns an identical struct.

  ## Bucketing, not sorting

  Buckets are ordered by `(macrostep, round)`, and only *within* a bucket
  do messages get a further order, by `{microstep, seq}`. This is two
  levels, not one flat `{macrostep, round, microstep, seq}` sort key: a
  round is a bucket a message either belongs to or does not, so a message
  stamped at a lower `microstep` than an earlier round's messages still
  lands in its own round's bucket rather than sorting ahead of them. `seq`
  is itself a producer stamp (`docs/wire-format.md:84-89`), so using it as
  the final tiebreak is still ordering from the stamps.

  ## Routing `effect.*` messages

  The routing rule is "does this message carry a `round`", never a check
  against the `"effect."` prefix. When this module was written only
  `trace.*` messages and `effect.budget_exhausted` carried `round`, so the
  other `effect.*` types landed in their macrostep's `effects`; sui-67d
  then propagated `round` onto every `effect.*` type, and - exactly as
  planned - that was a pure data change needing no change here: an
  `effect.*` message carrying a `round` is routed to its round bucket, and
  `effects` still catches any message without one (an older recorded
  stream, for example - the must-ignore rule cuts both ways).

  ## Errors

  `docs/wire-format.md:96-102` forbids merging two sessions' stamps onto
  one timeline (statifier ADR-0050 lets one mailbox carry an invoke tree of
  related sessions), so `build/1` refuses a message list naming more than
  one session id rather than corrupting the log.
  """

  alias StatifierUI.EventLog.Macrostep
  alias StatifierUI.EventLog.Round
  alias StatifierUI.Trace.Message

  @type t :: %__MODULE__{
          session: String.t() | nil,
          macrosteps: [Macrostep.t()],
          session_messages: [Message.t()],
          truncated?: boolean()
        }

  defstruct session: nil, macrosteps: [], session_messages: [], truncated?: false

  @doc """
  Folds `messages` into an `t()`.

  Returns `{:error, {:mixed_sessions, sorted_ids}}` when `messages` names
  more than one distinct session. An empty list returns an empty, default
  log with `session: nil`.
  """
  @spec build([Message.t()]) ::
          {:ok, t()} | {:error, {:mixed_sessions, [String.t()]}}
  def build([]), do: {:ok, %__MODULE__{}}

  def build(messages) do
    with {:ok, session} <- resolve_session(messages) do
      {session_messages, stamped} = Enum.split_with(messages, &session_message?/1)

      log = %__MODULE__{
        session: session,
        session_messages: Enum.sort_by(session_messages, & &1.seq),
        truncated?: truncated?(messages),
        macrosteps: build_macrosteps(stamped)
      }

      {:ok, log}
    end
  end

  # -- Session resolution -----------------------------------------------------

  @spec resolve_session([Message.t()]) ::
          {:ok, String.t() | nil} | {:error, {:mixed_sessions, [String.t()]}}
  defp resolve_session(messages) do
    case messages |> Enum.map(& &1.session) |> Enum.uniq() |> Enum.sort() do
      [] -> {:ok, nil}
      [session] -> {:ok, session}
      ids -> {:error, {:mixed_sessions, ids}}
    end
  end

  @spec truncated?([Message.t()]) :: boolean()
  defp truncated?(messages) do
    messages
    |> Enum.map(& &1.seq)
    |> Enum.min()
    |> Kernel.>(0)
  end

  @spec session_message?(Message.t()) :: boolean()
  defp session_message?(%Message{type: "session." <> _rest}), do: true
  defp session_message?(%Message{}), do: false

  # -- Macrostep grouping -------------------------------------------------

  @spec build_macrosteps([Message.t()]) :: [Macrostep.t()]
  defp build_macrosteps(stamped) do
    stamped
    |> Enum.group_by(& &1.macrostep)
    |> Enum.sort_by(fn {macrostep, _msgs} -> macrostep end)
    |> Enum.map(fn {macrostep, msgs} -> build_macrostep(macrostep, msgs) end)
  end

  @spec build_macrostep(non_neg_integer(), [Message.t()]) :: Macrostep.t()
  defp build_macrostep(macrostep, msgs) do
    {round_msgs, effect_msgs} = Enum.split_with(msgs, &(&1.round != nil))

    rounds = build_rounds(macrostep, round_msgs)
    effects = Enum.sort_by(effect_msgs, &{&1.microstep, &1.seq})

    Macrostep.new(macrostep, rounds, effects)
  end

  # -- Round grouping -------------------------------------------------------

  @spec build_rounds(non_neg_integer(), [Message.t()]) :: [Round.t()]
  defp build_rounds(macrostep, round_msgs) do
    round_msgs
    |> Enum.group_by(& &1.round)
    |> Enum.sort_by(fn {round, _msgs} -> round end)
    |> Enum.map(fn {round, msgs} -> build_round(macrostep, round, msgs) end)
  end

  @spec build_round(non_neg_integer(), non_neg_integer(), [Message.t()]) :: Round.t()
  defp build_round(macrostep, round, msgs) do
    msgs
    |> Enum.sort_by(&{&1.microstep, &1.seq})
    |> Enum.reduce(%Round{macrostep: macrostep, round: round}, &put_message(&2, &1))
  end

  # -- Reducing a round's messages into its Round fields -----------------

  @spec put_message(Round.t(), Message.t()) :: Round.t()
  defp put_message(round, %Message{type: "trace.event_dequeued", payload: payload} = m) do
    event = payload["event"]

    %{
      round
      | event: event,
        from: payload["from"],
        cause: cause_of(event),
        messages: round.messages ++ [m]
    }
  end

  defp put_message(round, %Message{type: "trace.transitions_selected", payload: payload} = m) do
    %{
      round
      | t_indexes: payload["t_indexes"],
        eventless?: not Map.has_key?(payload, "event"),
        messages: round.messages ++ [m]
    }
  end

  defp put_message(round, %Message{type: "trace.exit_set", payload: payload} = m) do
    %{round | exited: round.exited ++ payload["indexes"], messages: round.messages ++ [m]}
  end

  defp put_message(round, %Message{type: "trace.entry_set", payload: payload} = m) do
    %{round | entered: round.entered ++ payload["indexes"], messages: round.messages ++ [m]}
  end

  defp put_message(round, %Message{type: "trace.content_executed", payload: payload} = m) do
    item = %{owner: payload["owner"], c_indexes: payload["c_indexes"]}
    %{round | content: round.content ++ [item], messages: round.messages ++ [m]}
  end

  defp put_message(round, %Message{type: "trace.macrostep_stable", payload: payload} = m) do
    %{round | configuration: payload["configuration"], messages: round.messages ++ [m]}
  end

  defp put_message(round, %Message{type: "trace.done", payload: payload} = m) do
    %{round | done: payload, messages: round.messages ++ [m]}
  end

  defp put_message(round, %Message{type: "effect.budget_exhausted", payload: payload} = m) do
    %{round | budget_exhausted: payload, messages: round.messages ++ [m]}
  end

  defp put_message(round, m) do
    %{round | messages: round.messages ++ [m]}
  end

  @spec cause_of(map() | nil) :: map() | nil
  defp cause_of(nil), do: nil
  defp cause_of(event), do: event["cause"]
end
