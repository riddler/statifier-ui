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

  ## The catch-up attach path

  `attach(sub, session, catch_up: true)` closes the late-attach gap for a
  session started with `record: true` (statifier ADR-0049): the
  subscription and the recording snapshot happen in the *same* session
  `handle_call`, the missed prefix is `Statifier.Replay.run/1`'s `stream`,
  and this subscriber folds that prefix into its buffer inside its own
  `attach` call - before any live suffix from its mailbox is processed.
  Prefix and suffix are one uniform stream with no overlap, no gap, and no
  dedup key (the ADR's mid-run invariant; trust the seam). The session id
  is read from the recording's resolved `:session_id` option, so the
  `session.start` manifest is emitted as `seq: 0` ahead of the prefix.

  On a session started *without* `record: true` the session answers
  `{:error, :not_recorded}` and does not subscribe, so this subscriber
  falls back to `Statifier.Session.subscribe/2` and records a
  `:not_recorded` diagnostic in `stats/1` - the stream is live-only and
  says so; it is never silently presented as whole. A `Statifier.Replay.run/1`
  failure records `:catch_up_failed` the same way (the live subscription
  from the catch-up call itself is already in place in that case).

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

  ## Projection

  When started with a `:projection` profile this subscriber applies
  `StatifierUI.Trace.Projection.project/2` to every message in
  `buffer_and_fanout/2` - the single point every message reaches, whether it
  came from the manifest, from a normalized effect, from a replayed catch-up
  prefix, or from the hand-built `session.terminated` on monitor `:DOWN`.
  Projection therefore happens before the message is buffered and before any
  listener sees it, which is what lets a projected stream be buffered,
  encoded, persisted, or replayed without any of those having held a
  datamodel value (ADR-0012).

  Without the option nothing changes: no `projection` header, no sentinels,
  full values, identical bytes.

  ## OTel correlation

  When started with an `:otel_context` resolver this subscriber stamps the
  `otel` envelope key (ADR-0013) in the same `buffer_and_fanout/2` chokepoint,
  immediately before projection - so a projected stream carries the key
  unchanged, which is what ADR-0013 requires of it. The stamp is applied only
  to `trace.*` and `effect.*` messages carrying a `macrostep`; the manifest,
  the `session.*` lifecycle messages, and the hand-built `session.terminated`
  never carry it.

  The resolver is host code and this package reads no OTel API: see
  `StatifierUI.Trace.Otel` for its contract, the well-formedness rules the
  ids must satisfy, and why a resolver that raises is treated as "no
  context" rather than as a failure. Without the option nothing changes and
  golden captures stay byte-comparable, which is why they attach none.
  """

  use GenServer

  require Logger

  alias Statifier.Session.Recording
  alias StatifierUI.Fixtures
  alias StatifierUI.Trace.Buffer
  alias StatifierUI.Trace.Manifest
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Normalizer
  alias StatifierUI.Trace.Otel
  alias StatifierUI.Trace.Projection

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
          diagnostics: [Fixtures.diagnostic()],
          projection: %{mode: String.t(), profile: String.t()} | nil
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
            projection: Projection.Profile.t() | nil,
            otel_context: StatifierUI.Trace.Otel.resolver() | nil,
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
              projection: nil,
              otel_context: nil,
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
    - `:projection` - a `StatifierUI.Trace.Projection.Profile` struct. When
      given, every message is projected before it is buffered or fanned out
      and `session.start` carries the `projection` header (ADR-0012).
      Default `nil`, which is full fidelity and byte-unchanged.
    - `:otel_context` - a `t:StatifierUI.Trace.Otel.resolver/0`, i.e. a
      2-arity function `(session_id, macrostep -> {:ok, %{trace_id: binary,
      span_id: binary}} | :none)`, used to stamp the `otel` envelope key on
      `trace.*` and `effect.*` messages (ADR-0013). Default `nil`, which
      omits the key everywhere and leaves the stream byte-unchanged - which
      is what golden captures rely on. A value that is not a 2-arity
      function raises `ArgumentError` at `start_link/1`, rather than
      silently producing an uncorrelated stream.
    - `:name` - passed to `GenServer.start_link/3` unchanged.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    machine = Keyword.fetch!(opts, :machine)
    _ = validate_otel_context!(Keyword.get(opts, :otel_context))
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

  `opts[:catch_up]` (default `false`) selects the catch-up path described
  in the moduledoc - `Statifier.Session.subscribe/3` with `catch_up: true`,
  the replayed prefix folded in before this call returns. When set,
  `opts[:subscribe]` is ignored: catch-up decides its own subscription.

  Idempotent about the monitor: a second `attach/3` call for the same
  `session` pid does not stack a second monitor. It does not attempt to
  detect an existing subscription, which is why the two paths are
  distinguished by the explicit `:subscribe` flag rather than inferred.
  """
  @spec attach(server(), session :: pid(), opts :: keyword()) :: :ok
  def attach(server, session, opts \\ []) when is_pid(session) do
    mode =
      cond do
        Keyword.get(opts, :catch_up, false) -> :catch_up
        Keyword.get(opts, :subscribe, true) -> :late
        true -> :early
      end

    GenServer.call(server, {:attach, session, mode})
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
      projection: Keyword.get(opts, :projection),
      otel_context: validate_otel_context!(Keyword.get(opts, :otel_context)),
      buffer: Buffer.new(capacity)
    }

    {:ok, state}
  end

  # A misconfigured resolver is caught once, here, rather than silently
  # dropping the `otel` key on every message for the life of the stream: an
  # absent key means "no context" to every consumer (ADR-0013), so a bad
  # option would be indistinguishable from a correct one that found nothing.
  @spec validate_otel_context!(term()) :: Otel.resolver() | nil
  defp validate_otel_context!(nil), do: nil
  defp validate_otel_context!(resolver) when is_function(resolver, 2), do: resolver

  defp validate_otel_context!(other) do
    raise ArgumentError,
          ":otel_context must be a 2-arity function (session_id, macrostep), got: " <>
            inspect(other)
  end

  @impl GenServer
  def handle_call({:attach, session_pid, mode}, _from, state) do
    monitor_ref = ensure_monitor(state, session_pid)

    state = %{state | session_pid: session_pid, monitor_ref: monitor_ref, status: :attached}

    state =
      case mode do
        :early ->
          state

        :late ->
          :ok = Statifier.Session.subscribe(session_pid, self())
          %{state | diagnostics: state.diagnostics ++ [late_attach_diagnostic()]}

        :catch_up ->
          attach_catch_up(state, session_pid)
      end

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

  # -- catch-up -------------------------------------------------------------

  # The subscription is already made by the time either branch runs:
  # `Statifier.Session.subscribe/3` with `catch_up: true` adds this pid in
  # the same session handle_call that snapshots the recording, so the
  # replayed prefix and the mailbox suffix meet with no overlap and no gap
  # (statifier ADR-0049). Only `:not_recorded` leaves this pid
  # unsubscribed, and that branch subscribes live itself.
  @spec attach_catch_up(State.t(), pid()) :: State.t()
  defp attach_catch_up(state, session_pid) do
    case Statifier.Session.subscribe(session_pid, self(), catch_up: true) do
      {:ok, recording} ->
        replay_prefix(state, recording)

      {:error, :not_recorded} ->
        :ok = Statifier.Session.subscribe(session_pid, self())

        record_diagnostic(
          state,
          :not_recorded,
          "catch-up requested but the session was not started with record: true - " <>
            "attached live-only; everything before this attach is missing from the stream"
        )
    end
  end

  @spec replay_prefix(State.t(), Recording.t()) :: State.t()
  defp replay_prefix(state, recording) do
    session_id = recording |> Recording.opts() |> Keyword.fetch!(:session_id)

    case Statifier.Replay.run(recording) do
      {:ok, %{stream: stream}} ->
        state = emit_manifest(%{state | session: session_id})
        Enum.reduce(stream, state, &handle_statifier_message(&2, session_id, &1))

      {:error, reason} ->
        # Subscribed live (the catch-up call added this pid); the prefix is
        # simply unavailable. `session` stays nil so the first live message
        # still emits the manifest.
        record_diagnostic(
          state,
          :catch_up_failed,
          "catch-up subscribed, but replaying the recording failed " <>
            "(#{inspect(reason)}) - live-only; everything before this attach " <>
            "is missing from the stream"
        )
    end
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
    message = if is_binary(reason), do: reason, else: inspect(reason)
    diagnostic = %{kind: kind, message: message, path: [], source: nil}
    %{state | diagnostics: state.diagnostics ++ [diagnostic]}
  end

  # -- normalize / buffer / fan-out ------------------------------------------

  @spec emit_normalized(State.t(), Normalizer.input()) :: State.t()
  defp emit_normalized(state, input) do
    ctx = %{session: state.session, seq: state.seq}

    case Normalizer.normalize(input, ctx) do
      {:ok, message} -> buffer_and_fanout(state, message)
      {:error, reason} -> record_normalize_error(state, effect_tag(input), reason)
    end
  end

  # The tag names which effect failed to normalize - `reason` alone (e.g.
  # `{:unsupported_value, term}`) does not say whether the rejected value
  # came from an `effect.log`, a `trace.done`, or elsewhere, and that is
  # exactly what a human reading the warning needs first. Dedup stays keyed
  # on `reason` alone (see `record_normalize_error/3`); this is for the log
  # line's readability only.
  @spec effect_tag(Normalizer.input()) :: atom()
  defp effect_tag({:effect, {tag, _payload}}) when is_atom(tag), do: tag
  defp effect_tag({:unroutable, {tag, _payload}}) when is_atom(tag), do: tag
  defp effect_tag({:halted, reason}) when is_atom(reason), do: reason
  defp effect_tag({tag, _payload}) when is_atom(tag), do: tag

  @spec record_normalize_error(State.t(), atom(), term()) :: State.t()
  defp record_normalize_error(state, tag, reason) do
    unless MapSet.member?(state.error_reasons, reason) do
      Logger.warning(
        "StatifierUI.Trace.Subscriber: normalize error on #{tag}: #{inspect(reason)}"
      )
    end

    %{
      state
      | errors: state.errors + 1,
        error_reasons: MapSet.put(state.error_reasons, reason)
    }
  end

  # The single point every message passes through, and therefore the only
  # place projection and OTel stamping have to be applied: the manifest,
  # every normalized effect, the replayed catch-up prefix, and the
  # hand-built session.terminated all arrive here. Both run before the
  # buffer push and before the fan-out, so nothing downstream ever holds a
  # value the profile withheld, and nothing downstream has to re-derive the
  # correlation ids.
  #
  # The stamp precedes the projection because ADR-0013 puts `otel` in the
  # never-projected set: running it first is what proves a projected stream
  # carries the key unchanged rather than leaving that a property of
  # Projection.project/2 happening not to touch the envelope.
  @spec buffer_and_fanout(State.t(), Message.t()) :: State.t()
  defp buffer_and_fanout(state, %Message{} = message) do
    message =
      message
      |> Otel.stamp(state.otel_context)
      |> then(&project(state.projection, &1))

    Enum.each(state.listeners, fn pid -> send(pid, {:statifier_ui, state.session, message}) end)

    %{state | buffer: Buffer.push(state.buffer, message), seq: state.seq + 1}
  end

  @spec project(Projection.Profile.t() | nil, Message.t()) :: Message.t()
  defp project(nil, message), do: message
  defp project(%Projection.Profile{} = profile, message), do: Projection.project(message, profile)

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

  @spec projection_stats(Projection.Profile.t() | nil) ::
          %{mode: String.t(), profile: String.t()} | nil
  defp projection_stats(nil), do: nil
  defp projection_stats(%Projection.Profile{name: name}), do: %{mode: "projected", profile: name}

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
      diagnostics: state.diagnostics,
      projection: projection_stats(state.projection)
    }
  end
end
