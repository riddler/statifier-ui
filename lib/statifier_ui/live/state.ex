defmodule StatifierUI.Live.State do
  @moduledoc """
  The read model a host LiveView keeps in its socket: a compiled
  `Statifier.Machine`, the wire-format v1 messages seen so far, and which
  point in the run the panes are showing.

  Everything here is pure and touches no LiveView, so the whole behaviour
  of `StatifierUI.Live`'s components is testable without Phoenix - the same
  split `StatifierUI.Inspector` gives the Kino inspector. This module adds
  no semantics of its own: every reading it answers is delegated to
  `StatifierUI.Inspector`, which reads the engine's own
  `trace.macrostep_stable` stamps (ADR-0002's inherited clause). Nothing
  here re-derives a configuration.

  ## Persisted and live streams are the same struct

  A persisted stream is a `[StatifierUI.Trace.Message.t()]` decoded from
  storage - `StatifierUI.Trace.Json.decode/1`, an ops table, a recording -
  handed to `new/2` or `put_messages/2`. A live stream is the same list
  arriving one message at a time from a `StatifierUI.Trace.Subscriber` the
  host added itself to as a listener. `push/2` appends those.

  Both are wire format v1 (`docs/wire-format.md`), so no pane knows which
  it is looking at.

  ## The safe attach order

  A host that wants live *and* the prefix the subscriber already buffered
  runs, in `mount/3`:

      :ok = Subscriber.add_listener(subscriber, self())
      state = State.new(machine) |> State.sync(subscriber)

  Listener first, snapshot second: the other order loses every message
  emitted between the two calls. That order can deliver a message twice -
  once in the snapshot, once in the mailbox - so `push/2` drops any message
  whose `seq` is not newer than the newest one held. `seq` is the
  subscriber's own monotonic stamp (`docs/wire-format.md`), which is what
  makes that check exact rather than a heuristic.

  ## Selection

  `selection` is `:live` (follow the tip) or `{:macrostep, n}`. `scrub/2`
  moves it with the scrubber's vocabulary and `select/2` jumps to one
  macrostep; both are `StatifierUI.Inspector.step/3` and its selection type,
  unchanged.
  """

  alias Statifier.Machine
  alias StatifierUI.EventLog
  alias StatifierUI.Inspector
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  @typedoc "The read model one ops view renders from."
  @type t :: %__MODULE__{
          machine: Machine.t(),
          messages: [Message.t()],
          selection: Inspector.selection(),
          initial_configuration: [non_neg_integer()],
          stats: Subscriber.stats() | nil,
          last_seq: non_neg_integer() | nil
        }

  @enforce_keys [:machine]
  defstruct machine: nil,
            messages: [],
            selection: :live,
            initial_configuration: [],
            stats: nil,
            last_seq: nil

  @doc """
  Builds the read model for `machine`.

  Options:

    * `:messages` - a persisted wire-format v1 message list (default `[]`).
    * `:initial_configuration` - the configuration to draw before any
      macrostep has stabilized in view, typically
      `Statifier.Session.snapshot/1`'s (default `[]`).
    * `:selection` - where to start; `:live` (default) or `{:macrostep, n}`.
    * `:stats` - a `t:StatifierUI.Trace.Subscriber.stats/0` snapshot for the
      status pane. A persisted stream has none, and the pane says so.
  """
  @spec new(Machine.t(), keyword()) :: t()
  def new(%Machine{} = machine, opts \\ []) do
    %__MODULE__{
      machine: machine,
      selection: Keyword.get(opts, :selection, :live),
      initial_configuration: opts |> Keyword.get(:initial_configuration, []) |> Enum.to_list(),
      stats: Keyword.get(opts, :stats)
    }
    |> put_messages(Keyword.get(opts, :messages, []))
  end

  @doc """
  Replaces the whole message list - the persisted read, and what `sync/2`
  uses for a subscriber's buffer snapshot.
  """
  @spec put_messages(t(), [Message.t()]) :: t()
  def put_messages(%__MODULE__{} = state, messages) when is_list(messages) do
    %{state | messages: messages, last_seq: newest_seq(messages)}
  end

  @doc """
  Appends one live message, or a list of them.

  A message whose `seq` is not newer than the newest one held is dropped,
  so the `add_listener` then `sync/2` order in the moduledoc cannot
  double-count its overlap. Every message carries a `seq` - the envelope
  enforces it - so that check is exact rather than best-effort.
  """
  @spec push(t(), Message.t() | [Message.t()]) :: t()
  def push(%__MODULE__{} = state, messages) when is_list(messages) do
    Enum.reduce(messages, state, &push(&2, &1))
  end

  def push(%__MODULE__{} = state, %Message{} = message) do
    if stale?(state, message) do
      state
    else
      %{state | messages: state.messages ++ [message], last_seq: message.seq}
    end
  end

  @doc """
  Records a fresh `t:StatifierUI.Trace.Subscriber.stats/0` snapshot for the
  status pane.
  """
  @spec put_stats(t(), Subscriber.stats()) :: t()
  def put_stats(%__MODULE__{} = state, stats) when is_map(stats) do
    %{state | stats: stats}
  end

  @doc """
  Pulls `subscriber`'s buffered messages and stats in one call.

  This is the only function here that talks to a process. Call it in
  `mount/3` *after* `StatifierUI.Trace.Subscriber.add_listener/2`, and
  again whenever a host wants to re-baseline (after a reconnect, say):
  `push/2`'s `seq` check makes the overlap harmless either way.
  """
  @spec sync(t(), Subscriber.server()) :: t()
  def sync(%__MODULE__{} = state, subscriber) do
    state
    |> put_messages(Subscriber.messages(subscriber))
    |> put_stats(Subscriber.stats(subscriber))
  end

  @doc """
  Moves the selection one scrubber step: `:first`, `:prev`, `:next`, or
  `:live`. `StatifierUI.Inspector.step/3` decides where it lands.
  """
  @spec scrub(t(), :live | :first | :prev | :next) :: t()
  def scrub(%__MODULE__{} = state, move) when move in [:live, :first, :prev, :next] do
    %{state | selection: Inspector.step(state.selection, points(state), move)}
  end

  @doc """
  Selects macrostep `n` directly - what clicking an event-log entry does.

  A macrostep naming no bucket in this log is not an error; it resolves
  against whatever buckets sit below it, exactly as
  `StatifierUI.EventLog.configuration_at/2` does.
  """
  @spec select(t(), non_neg_integer()) :: t()
  def select(%__MODULE__{} = state, n) when is_integer(n) and n >= 0 do
    %{state | selection: {:macrostep, n}}
  end

  @doc "The selectable macrosteps, oldest first."
  @spec points(t()) :: [Inspector.point()]
  def points(%__MODULE__{} = state), do: Inspector.points(state.messages)

  @doc "The configuration the current selection implies."
  @spec configuration(t()) :: [non_neg_integer()]
  def configuration(%__MODULE__{} = state) do
    Inspector.active_configuration(state.messages, opts(state))
  end

  @doc """
  The configuration the current selection implies, as state IDS rather than
  wire indexes - `StatifierUI.Inspector.active_configuration_ids/2` over the
  messages this read model holds.

  This is the read a host drawing its own diagram wants: the indexes
  `configuration/1` answers are positions in the stream that produced them,
  while a host works in the chart's ids. `{:error, :no_manifest}` when the
  stream carries no `session.start` to resolve through (the late-attach
  case); `configuration/1` still answers indexes there.

  ## Examples

      iex> {:ok, machine} =
      ...>   Statifier.compile(~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending"><state id="pending"/><state id="authorized"/></scxml>))
      iex> {:ok, manifest} = StatifierUI.Trace.Manifest.build(machine, "sess_ops")
      iex> machine
      ...> |> StatifierUI.Live.State.new(messages: [manifest], initial_configuration: [1])
      ...> |> StatifierUI.Live.State.configuration_ids()
      {:ok, ["pending"]}
  """
  @spec configuration_ids(t()) :: {:ok, [String.t()]} | {:error, :no_manifest}
  def configuration_ids(%__MODULE__{} = state) do
    Inspector.active_configuration_ids(state.messages, opts(state))
  end

  @doc "How the current selection resolved - see `StatifierUI.Inspector.resolution/2`."
  @spec resolution(t()) ::
          :live
          | {:quiescent, non_neg_integer()}
          | {:final, non_neg_integer()}
          | {:carried, non_neg_integer(), non_neg_integer()}
          | {:before_first, non_neg_integer()}
  def resolution(%__MODULE__{} = state), do: Inspector.resolution(state.messages, opts(state))

  @doc """
  The one-line note naming the point on screen, as Markdown - the same
  string the Livebook inspector puts above its diagram.
  """
  @spec selection_note(t()) :: String.t()
  def selection_note(%__MODULE__{} = state) do
    Inspector.selection_note(state.messages, opts(state))
  end

  @doc """
  Mermaid `stateDiagram-v2` source for the diagram pane, highlighted at the
  current selection.

  `opts[:active_style]` is passed to `StatifierUI.Diagram` unchanged - the
  hook a dark host uses to reach the active-configuration highlight.
  """
  @spec diagram_source(t(), [Inspector.opt()]) :: String.t()
  def diagram_source(%__MODULE__{} = state, extra \\ []) do
    Inspector.diagram(state.machine, state.messages, opts(state) ++ extra)
  end

  @doc """
  The folded event log, or the reason it refused to build - a message list
  naming more than one session is the only refusal
  (`StatifierUI.EventLog.build/1`).
  """
  @spec log(t()) :: {:ok, EventLog.t()} | {:error, {:mixed_sessions, [String.t()]}}
  def log(%__MODULE__{} = state), do: EventLog.build(state.messages)

  @doc """
  The macrostep the diagram is showing, or `nil` on `:live` - what marks one
  event-log entry as the selected one.
  """
  @spec selected_macrostep(t()) :: non_neg_integer() | nil
  def selected_macrostep(%__MODULE__{selection: {:macrostep, n}}), do: n
  def selected_macrostep(%__MODULE__{}), do: nil

  @spec opts(t()) :: [Inspector.opt()]
  defp opts(%__MODULE__{} = state) do
    [initial_configuration: state.initial_configuration, selection: state.selection]
  end

  @spec stale?(t(), Message.t()) :: boolean()
  defp stale?(%__MODULE__{last_seq: nil}, _message), do: false
  defp stale?(%__MODULE__{last_seq: last}, %Message{seq: seq}), do: seq <= last

  @spec newest_seq([Message.t()]) :: non_neg_integer() | nil
  defp newest_seq(messages) do
    messages
    |> Enum.map(& &1.seq)
    |> Enum.max(&>=/2, fn -> nil end)
  end
end
