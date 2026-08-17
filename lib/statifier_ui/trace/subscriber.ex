defmodule StatifierUI.Trace.Subscriber do
  @moduledoc """
  The only `GenServer` in this bead - it owns attach and detach, `seq`
  stamping, the `session.start` manifest emission, session-death handling,
  and the bounded buffer, and fans every message out to registered
  listeners. Everything else under `lib/statifier_ui/trace/` is a pure
  module; this is the process that wires them to a live
  `Statifier.Session`.

  ## The recommended (early) attach sequence

  The only path that sees the initialize burst - `Statifier.Session.start_link/2`
  runs `Statifier.Interpreter.initialize/2` to quiescence before returning,
  so a subscriber added afterward has already missed the opening
  `EntrySet`/`ContentExecuted`/`InvokePass`/`MacrostepStable` (GAP 6 /
  `st-uqo4`). Passing this subscriber's pid in `:subscribers` at
  `Statifier.Session.start_link/2` time is the only way around that:

      {:ok, sub} = StatifierUI.Trace.Subscriber.start_link(machine: machine, source: source)

      {:ok, session} =
        Statifier.Session.start_link(machine, trace: true, subscribers: [sub], session_id: "sess_1")

      :ok = StatifierUI.Trace.Subscriber.attach(sub, session, subscribe: false)

  The session already has `sub` in its monitored subscriber set from
  `:subscribers`, so `attach/3` with `subscribe: false` only takes the
  monitor - it never calls `Statifier.Session.subscribe/2`.

  ## The late attach path

  `attach(sub, session)` (default `subscribe: true`) calls
  `Statifier.Session.subscribe/2` itself, in addition to monitoring. A
  `:late_attach` diagnostic is recorded in `stats/1`'s `diagnostics` list -
  the initialize burst is gone by the time this call can run, because
  `Statifier.Session.start_link/2` already returned.

  ## Session id discovery

  This subscriber never asks the session for its id (decision 9 of the
  plan): no `GenServer.call` from this process into the session it is
  subscribed to, because the session runs `initialize/2` inside its own
  `init/1` and a call issued while the caller's `start_link` chain is still
  unwinding can block on a process that is itself blocked (GAP 5 /
  `st-xbaz`). The session id instead arrives on the first
  `{:statifier, session_id, _}` message this process receives. At that
  moment the `session.start` manifest is built and emitted as `seq: 0`,
  and the triggering message is normalized immediately after as `seq: 1`.
  If `StatifierUI.Trace.Manifest.build/3` fails (a bad `:fixtures` value,
  say), no manifest is emitted, the failure is recorded as a diagnostic in
  `stats/1`, and normalization continues - losing the index tables is bad,
  losing the whole trace is worse.

  ## Halting is not end-of-stream

  `{:halted, reason}` becomes a `session.halted` message and changes
  nothing else: this subscriber does not stop, does not unsubscribe, and
  does not mark the stream complete. GAP 4 / `st-r6l9` shows `trace.*`
  effects arriving *after* `{:halted, :done}`, and dropping them is the
  failure this note exists to prevent. Only the session process actually
  exiting - observed as this subscriber's own monitor `:DOWN` - produces
  `session.terminated` and moves `stats/1`'s `status` to `:terminated`; the
  buffer is kept and stays readable either way.
  """

  use GenServer

  require Logger

  alias StatifierUI.Fixtures
  alias StatifierUI.Trace.Buffer
  alias StatifierUI.Trace.Manifest
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Normalizer

  @type server :: GenServer.server()

  @typedoc "The snapshot `stats/1` returns."
  @type stats :: %{
          session: String.t() | nil,
          status: :detached | :attached | :terminated,
          seq: non_neg_integer(),
          buffered: non_neg_integer(),
          dropped: non_neg_integer(),
          errors: non_neg_integer(),
          foreign: non_neg_integer(),
          diagnostics: [Fixtures.diagnostic()]
        }

  @default_capacity 1000

  defmodule State do
    @moduledoc false

    alias StatifierUI.Fixtures
    alias StatifierUI.Trace.Buffer

    @type t :: %__MODULE__{
            machine: Statifier.Machine.t(),
            source: String.t() | nil,
            fixtures: map() | nil,
            parent_session: String.t() | nil,
            invokeid: String.t() | nil,
            capacity: pos_integer(),
            listeners: [pid()],
            session: String.t() | nil,
            status: :detached | :attached | :terminated,
            seq: non_neg_integer(),
            buffer: Buffer.t(),
            session_pid: pid() | nil,
            monitor_ref: reference() | nil,
            error_reasons: MapSet.t(),
            errors: non_neg_integer(),
            foreign: non_neg_integer(),
            diagnostics: [Fixtures.diagnostic()]
          }

    @enforce_keys [:machine, :capacity, :buffer]
    defstruct machine: nil,
              source: nil,
              fixtures: nil,
              parent_session: nil,
              invokeid: nil,
              capacity: nil,
              listeners: [],
              session: nil,
              status: :detached,
              seq: 0,
              buffer: nil,
              session_pid: nil,
              monitor_ref: nil,
              error_reasons: MapSet.new(),
              errors: 0,
              foreign: 0,
              diagnostics: []
  end

  # -- client -----------------------------------------------------------------

  @doc """
  Starts a subscriber.

  `opts`:

    - `:machine` (required) - the compiled `%Statifier.Machine{}` the
      `session.start` manifest is built from.
    - `:source` - the SCXML text, for `session.start`'s `source` field.
      Optional, since `%Statifier.Machine{}` does not retain it.
    - `:fixtures` - the decoded sidecar JSON object, for `session.start`'s
      `fixtures` field. Optional.
    - `:parent_session`, `:invokeid` - invoke-tree origin fields, forwarded
      to `session.start` when supplied. Optional.
    - `:capacity` - the bounded buffer's capacity, default `1000`.
    - `:listeners` - pids receiving `{:statifier_ui, session_id, %Message{}}`
      as messages arrive. Default `[]`.
    - `:name` - passed to `GenServer.start_link/3` unchanged.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    machine = Keyword.fetch!(opts, :machine)
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, {machine, opts}, gen_opts)
  end

  @doc """
  Attaches this subscriber to `session`, monitoring it for termination.

  `opts[:subscribe]` (default `true`) selects the late path -
  `Statifier.Session.subscribe/2` is called and a `:late_attach` diagnostic
  is recorded. Pass `subscribe: false` for the recommended early path,
  where `session` already carries this subscriber's pid in its own
  `:subscribers` start option.

  Idempotent about the monitor: a second `attach/3` call for the same
  `session` pid does not stack a second monitor. It does not attempt to
  detect an existing subscription, which is why the two paths are
  distinguished by the explicit `:subscribe` flag rather than inferred.
  """
  @spec attach(server(), session :: pid(), opts :: keyword()) :: :ok
  def attach(server, session, opts \\ []) when is_pid(session) do
    subscribe? = Keyword.get(opts, :subscribe, true)
    GenServer.call(server, {:attach, session, subscribe?})
  end

  @doc """
  Detaches this subscriber from its session: unsubscribes, demonitors with
  `[:flush]`, and sets `stats/1`'s `status` to `:detached`. The buffer is
  kept and stays readable.
  """
  @spec detach(server()) :: :ok
  def detach(server), do: GenServer.call(server, :detach)

  @doc "Returns every `%Message{}` currently held, oldest first."
  @spec messages(server()) :: [Message.t()]
  def messages(server), do: GenServer.call(server, :messages)

  @doc "Returns this subscriber's current `stats()` snapshot."
  @spec stats(server()) :: stats()
  def stats(server), do: GenServer.call(server, :stats)

  @doc "Registers `pid` to receive `{:statifier_ui, session_id, %Message{}}` for every subsequent message."
  @spec add_listener(server(), pid()) :: :ok
  def add_listener(server, pid) when is_pid(pid), do: GenServer.call(server, {:add_listener, pid})

  @doc "Removes `pid` from the listener set. A no-op if it was never registered."
  @spec remove_listener(server(), pid()) :: :ok
  def remove_listener(server, pid) when is_pid(pid),
    do: GenServer.call(server, {:remove_listener, pid})

  # -- callbacks ----------------------------------------------------------

  @impl GenServer
  def init({machine, opts}) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    state = %State{
      machine: machine,
      source: Keyword.get(opts, :source),
      fixtures: Keyword.get(opts, :fixtures),
      parent_session: Keyword.get(opts, :parent_session),
      invokeid: Keyword.get(opts, :invokeid),
      capacity: capacity,
      listeners: Keyword.get(opts, :listeners, []),
      buffer: Buffer.new(capacity)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:attach, session_pid, subscribe?}, _from, state) do
    monitor_ref = ensure_monitor(state, session_pid)

    if subscribe? do
      :ok = Statifier.Session.subscribe(session_pid, self())
    end

    diagnostics =
      if subscribe? do
        state.diagnostics ++ [late_attach_diagnostic()]
      else
        state.diagnostics
      end

    state = %{
      state
      | session_pid: session_pid,
        monitor_ref: monitor_ref,
        status: :attached,
        diagnostics: diagnostics
    }

    {:reply, :ok, state}
  end

  def handle_call(:detach, _from, state) do
    if state.session_pid, do: Statifier.Session.unsubscribe(state.session_pid, self())
    if state.monitor_ref, do: Process.demonitor(state.monitor_ref, [:flush])

    state = %{state | status: :detached, monitor_ref: nil, session_pid: nil}
    {:reply, :ok, state}
  end

  def handle_call(:messages, _from, state), do: {:reply, Buffer.to_list(state.buffer), state}

  def handle_call(:stats, _from, state), do: {:reply, build_stats(state), state}

  def handle_call({:add_listener, pid}, _from, state) do
    listeners = if pid in state.listeners, do: state.listeners, else: state.listeners ++ [pid]
    {:reply, :ok, %{state | listeners: listeners}}
  end

  def handle_call({:remove_listener, pid}, _from, state) do
    {:reply, :ok, %{state | listeners: List.delete(state.listeners, pid)}}
  end

  @impl GenServer
  def handle_info({:statifier, session_id, message}, %State{session: nil} = state) do
    state
    |> Map.put(:session, session_id)
    |> emit_manifest()
    |> handle_statifier_message(session_id, message)
    |> then(&{:noreply, &1})
  end

  def handle_info({:statifier, session_id, message}, %State{session: session_id} = state) do
    {:noreply, handle_statifier_message(state, session_id, message)}
  end

  def handle_info({:statifier, _other_session_id, _message}, state) do
    {:noreply, %{state | foreign: state.foreign + 1}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{monitor_ref: ref} = state) do
    {:noreply, handle_down(state, reason)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # -- attach helpers -----------------------------------------------------

  @spec ensure_monitor(State.t(), pid()) :: reference()
  defp ensure_monitor(%State{session_pid: pid, monitor_ref: ref}, pid) when not is_nil(ref),
    do: ref

  defp ensure_monitor(%State{monitor_ref: ref}, session_pid) do
    if ref, do: Process.demonitor(ref, [:flush])
    Process.monitor(session_pid)
  end

  @spec late_attach_diagnostic() :: Fixtures.diagnostic()
  defp late_attach_diagnostic do
    %{
      kind: :late_attach,
      message:
        "attached after Statifier.Session.start_link/2 already ran initialize/2 to " <>
          "quiescence - the opening entry_set/content_executed/invoke_pass/macrostep_stable " <>
          "burst was already delivered and missed",
      path: [],
      source: nil
    }
  end

  # -- message handling -----------------------------------------------------

  @spec handle_statifier_message(State.t(), String.t(), term()) :: State.t()
  defp handle_statifier_message(state, session_id, {:effect, _effect} = message)
       when session_id == state.session do
    emit_normalized(state, message)
  end

  defp handle_statifier_message(state, session_id, {:halted, _reason} = message)
       when session_id == state.session do
    emit_normalized(state, message)
  end

  defp handle_statifier_message(state, session_id, {:unroutable, _effect} = message)
       when session_id == state.session do
    emit_normalized(state, message)
  end

  defp handle_statifier_message(state, session_id, _other) when session_id == state.session,
    do: state

  # -- manifest -------------------------------------------------------------

  @spec emit_manifest(State.t()) :: State.t()
  defp emit_manifest(%State{session: session} = state) do
    manifest_opts = [
      source: state.source,
      fixtures: state.fixtures,
      parent_session: state.parent_session,
      invokeid: state.invokeid
    ]

    case Manifest.build(state.machine, session, manifest_opts) do
      {:ok, message} -> buffer_and_fanout(state, %{message | seq: state.seq})
      {:error, reason} -> record_diagnostic(state, :manifest_build_failed, reason)
    end
  end

  @spec record_diagnostic(State.t(), atom(), term()) :: State.t()
  defp record_diagnostic(state, kind, reason) do
    diagnostic = %{kind: kind, message: inspect(reason), path: [], source: nil}
    %{state | diagnostics: state.diagnostics ++ [diagnostic]}
  end

  # -- normalize / buffer / fan-out ------------------------------------------

  @spec emit_normalized(State.t(), Normalizer.input()) :: State.t()
  defp emit_normalized(state, input) do
    ctx = %{session: state.session, seq: state.seq}

    case Normalizer.normalize(input, ctx) do
      {:ok, message} -> buffer_and_fanout(state, message)
      {:error, reason} -> record_normalize_error(state, reason)
    end
  end

  @spec record_normalize_error(State.t(), term()) :: State.t()
  defp record_normalize_error(state, reason) do
    unless MapSet.member?(state.error_reasons, reason) do
      Logger.warning("StatifierUI.Trace.Subscriber: normalize error #{inspect(reason)}")
    end

    %{
      state
      | errors: state.errors + 1,
        error_reasons: MapSet.put(state.error_reasons, reason)
    }
  end

  @spec buffer_and_fanout(State.t(), Message.t()) :: State.t()
  defp buffer_and_fanout(state, %Message{} = message) do
    Enum.each(state.listeners, fn pid -> send(pid, {:statifier_ui, state.session, message}) end)

    %{state | buffer: Buffer.push(state.buffer, message), seq: state.seq + 1}
  end

  # -- session death ----------------------------------------------------------

  @spec handle_down(State.t(), term()) :: State.t()
  defp handle_down(%State{session: nil} = state, _reason) do
    %{state | status: :terminated, monitor_ref: nil, session_pid: nil}
  end

  defp handle_down(%State{session: session} = state, reason) do
    message = %Message{
      type: "session.terminated",
      session: session,
      seq: state.seq,
      payload: %{"reason" => inspect(reason)}
    }

    state =
      case Message.validate(message) do
        {:ok, message} -> buffer_and_fanout(state, message)
        {:error, _reason} -> state
      end

    %{state | status: :terminated, monitor_ref: nil, session_pid: nil}
  end

  # -- stats ------------------------------------------------------------------

  @spec build_stats(State.t()) :: stats()
  defp build_stats(state) do
    %{
      session: state.session,
      status: state.status,
      seq: state.seq,
      buffered: Buffer.size(state.buffer),
      dropped: Buffer.dropped(state.buffer),
      errors: state.errors,
      foreign: state.foreign,
      diagnostics: state.diagnostics
    }
  end
end
