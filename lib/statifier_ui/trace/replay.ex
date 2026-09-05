defmodule StatifierUI.Trace.Replay do
  @moduledoc """
  The offline producer of the v1 trace wire format (ADR-0017): a pure
  function that turns a persisted session event log into the same
  `StatifierUI.Trace.Message` stream `StatifierUI.Trace.Subscriber`
  produces from a live session - with no `Statifier.Session`, no process,
  and no clock.

  A host that persists its own session event log - because it restarts, or
  because it stores runs for audit and renders them later - has the inputs
  a run was driven by, the compiled chart, and the options the session ran
  under, and nothing left to subscribe to. `from_events/4` is what it calls
  instead.

  ## The four steps, and why they are the subscriber's four steps

  `from_events/4` builds a `Statifier.Session.Recording` through that
  module's public constructors, hands it to `Statifier.Replay.run/1`, emits
  the `session.start` manifest, and folds the returned stream through the
  normalizer - which is exactly what
  `StatifierUI.Trace.Subscriber`'s catch-up attach path does, with the
  same calls in the same order:

    * `StatifierUI.Trace.Manifest.build/3` for `session.start`, stamped
      `seq: 0`;
    * `StatifierUI.Trace.Normalizer.normalize/2` for every stream element,
      with the same four-key `ctx` (so `error.location` resolves the same
      way);
    * `StatifierUI.Trace.Otel.stamp/2` and then
      `StatifierUI.Trace.Projection.project/2`, in that order, for every
      message - ADR-0013 puts `otel` in the never-projected set, and
      stamping first is what proves a projected stream carries the key
      unchanged.

  No message shape is constructed in this module. Parity with the
  subscriber (ADR-0017 decision 3) is therefore structural rather than
  promised: identical types, identical order, identical `seq` values, and
  identical payload bytes under `StatifierUI.Trace.Json.encode_lines/1`.

  ## What it deliberately does not do

    * **No `session.terminated`.** There is no process offline and no exit
      to observe; an offline stream's end is the end of the entry list.
      `session.halted` is unaffected - it comes from a `{:halted, reason}`
      stream element and is produced normally.
    * **No capacity, no fan-out, no diagnostics counter.** A function
      returning a list drops nothing and sends to nobody, so the
      subscriber's bounded buffer, its listener set, and its `stats/1` have
      no offline counterpart. The whole list is held in memory, which the
      subscriber's bound does not have to.
    * **No timers and no clock.** `Statifier.Replay` converts a schedule
      into a pending-timer credit rather than a real
      `Process.send_after/3`, and a recorded firing is delivered at its
      recorded position and nowhere else. Wall-clock time never enters,
      which is what makes this function deterministic.

  ## The name

  This module and `Statifier.Replay` collide under `alias`. That is
  intentional: the engine module is aliased here as `EngineReplay` at its
  single call site rather than naming this one something that hides what it
  is.
  """

  alias Statifier.Machine
  alias Statifier.Replay, as: EngineReplay
  alias Statifier.Session.Recording
  alias StatifierUI.Trace.Manifest
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Normalizer
  alias StatifierUI.Trace.Otel
  alias StatifierUI.Trace.Projection

  @typedoc """
  This producer's own options - the subscriber's emission options and no
  others.

  `:source`, `:fixtures`, `:parent_session` and `:invokeid` are forwarded
  verbatim to `StatifierUI.Trace.Manifest.build/3`; `:source` additionally
  widens the normalizer's `ctx` exactly as the subscriber's does.
  `:projection` and `:otel_context` are the chokepoint's two options.

  Deliberately absent are `:capacity`, `:listeners` and `:name`: a buffer,
  a fan-out and a process name are process concerns, and this is a
  function.
  """
  @type opts :: [
          source: String.t(),
          fixtures: map(),
          parent_session: String.t(),
          invokeid: String.t(),
          projection: Projection.Profile.t(),
          otel_context: Otel.resolver()
        ]

  @manifest_opts [:source, :fixtures, :parent_session, :invokeid]

  @doc """
  Produces the wire-format message stream for a recorded run, offline.

    * `machine` - the compiled chart the log was produced over, the same
      argument `StatifierUI.Trace.Manifest.build/3` and
      `Statifier.Session.Recording.new/3` take.
    * `initialize_opts` - the session options the recorded run was made
      under, in `Statifier.Session.Recording.new/3`'s normalized
      vocabulary: `:session_id`, `:trace`, `:datamodel`,
      `:max_macrostep_rounds`, `:routes`, `:invoke_types` and
      `:invoke_handlers`. `:session_id` must be a binary - every message's
      envelope carries it.
    * `events` - the persisted log, in the session's serialized input
      order, as `t:Statifier.Session.Recording.entry/0` values.
    * `opts` - this producer's own options; see `t:opts/0`.

  ## Errors are values, and the call fails closed

  The first failure returns `{:error, reason}` and no partial list. Where
  the subscriber continues past a bad effect and records a diagnostic - it
  would otherwise lose a live stream it can never recover - an offline
  caller still has the log in hand and can retry, report, or investigate,
  and a partial list returned as `{:ok, messages}` would be
  indistinguishable from a whole one (ADR-0017 decision 5).

  The reasons:

    * `{:initialize_opts, :trace_disabled}` when `initialize_opts` does not
      carry a truthy `:trace`. `Statifier.Session.Recording.new/3` defaults
      the flag to `false`, and a run made without it completes successfully
      while emitting no `trace.*` messages at all - nine of the format's
      twenty-four types missing, silently. The flag is the caller's to
      supply, because defaulting it on would produce a stream the recorded
      run never produced.
    * `{:initialize_opts, :missing_session_id}` when `:session_id` is
      absent or is not a binary.
    * `{:unknown_entry, entry}` for an entry shape this module does not
      know. `t:Statifier.Session.Recording.entry/0` has six shapes today, and
      a seventh appearing upstream must not be dropped silently - the same
      reasoning `StatifierUI.Trace.Normalizer.normalize/2` gives for
      `{:unknown_effect, tag}`.
    * anything `Statifier.Replay.run/1` returns, unwrapped - notably
      `{:unscheduled_timer_firing, send_id}`. Its `{:anchor, _}` arm cannot
      be reached from here: `from_events/4` takes no anchor, so the
      recording it builds always replays from
      `Statifier.Interpreter.initialize/2` (a host holding an anchored
      recording has the blob, and wants `Statifier.Replay.run/1` directly).
    * anything `StatifierUI.Trace.Manifest.build/3` or
      `StatifierUI.Trace.Normalizer.normalize/2` returns.

  ## Examples

      iex> {:ok, machine} = Statifier.compile(~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a"><state id="a"/></scxml>))
      iex> {:ok, [manifest | _]} =
      ...>   StatifierUI.Trace.Replay.from_events(machine, [session_id: "s", trace: true], [])
      iex> {manifest.type, manifest.session, manifest.seq}
      {"session.start", "s", 0}

      iex> {:ok, machine} = Statifier.compile(~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a"><state id="a"/></scxml>))
      iex> StatifierUI.Trace.Replay.from_events(machine, [session_id: "s"], [])
      {:error, {:initialize_opts, :trace_disabled}}

  """
  @spec from_events(
          machine :: Machine.t(),
          initialize_opts :: keyword(),
          events :: [Recording.entry()],
          opts :: opts()
        ) :: {:ok, [Message.t()]} | {:error, term()}
  def from_events(%Machine{} = machine, initialize_opts, events, opts \\ [])
      when is_list(initialize_opts) and is_list(events) and is_list(opts) do
    with {:ok, session} <- validate_initialize_opts(initialize_opts),
         {:ok, recording} <- build_recording(machine, initialize_opts, events),
         {:ok, %{stream: stream}} <- EngineReplay.run(recording) do
      emit(machine, session, stream, opts)
    end
  end

  # -- initialize opts --------------------------------------------------------

  @spec validate_initialize_opts(keyword()) ::
          {:ok, String.t()} | {:error, {:initialize_opts, atom()}}
  defp validate_initialize_opts(initialize_opts) do
    cond do
      !Keyword.get(initialize_opts, :trace, false) ->
        {:error, {:initialize_opts, :trace_disabled}}

      not is_binary(Keyword.get(initialize_opts, :session_id)) ->
        {:error, {:initialize_opts, :missing_session_id}}

      true ->
        {:ok, Keyword.fetch!(initialize_opts, :session_id)}
    end
  end

  # -- the recording ----------------------------------------------------------

  # Built through the public constructors, never as a struct literal:
  # `Statifier.Session.Recording.t()` is `@opaque` upstream, and building it
  # by hand would couple this repository to a struct deliberately closed
  # (ADR-0017 decision 2). One clause per `Recording.entry/0` shape, and an
  # unrecognized shape is an error rather than a skip.
  @spec build_recording(Machine.t(), keyword(), [Recording.entry()]) ::
          {:ok, Recording.t()} | {:error, {:unknown_entry, term()}}
  defp build_recording(machine, initialize_opts, events) do
    Enum.reduce_while(events, {:ok, Recording.new(machine, initialize_opts)}, fn
      entry, {:ok, recording} ->
        case put_entry(recording, entry) do
          {:ok, recording} -> {:cont, {:ok, recording}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  @spec put_entry(Recording.t(), Recording.entry()) ::
          {:ok, Recording.t()} | {:error, {:unknown_entry, term()}}
  defp put_entry(recording, {:event, event, routes}),
    do: {:ok, Recording.put_event(recording, event, routes)}

  defp put_entry(recording, {:invoked_event, invoke_id, event, routes}),
    do: {:ok, Recording.put_invoked_event(recording, invoke_id, event, routes)}

  defp put_entry(recording, {:cancel, routes}),
    do: {:ok, Recording.put_cancel(recording, routes)}

  defp put_entry(recording, {:timer, send_id, event, routes}),
    do: {:ok, Recording.put_timer(recording, send_id, event, routes)}

  defp put_entry(recording, {:interpret, effects, routes}),
    do: {:ok, Recording.put_interpret(recording, effects, routes)}

  defp put_entry(recording, {:internal, kind, name, origin, entry_opts, routes}),
    do: {:ok, Recording.put_internal(recording, kind, name, origin, entry_opts, routes)}

  defp put_entry(_recording, entry), do: {:error, {:unknown_entry, entry}}

  # -- emission ---------------------------------------------------------------

  # The subscriber's `emit_manifest/1` then its fold over the replayed
  # prefix, with the `seq` counter carried explicitly instead of through
  # `%State{}`. The manifest is restamped from the counter rather than
  # trusted, exactly as `subscriber.ex` does - the counter starts at 0, so
  # the value is the same and the provenance is the fold's.
  @spec emit(Machine.t(), String.t(), [EngineReplay.message()], opts()) ::
          {:ok, [Message.t()]} | {:error, term()}
  defp emit(machine, session, stream, opts) do
    with {:ok, manifest} <- Manifest.build(machine, session, Keyword.take(opts, @manifest_opts)) do
      fold(stream, %{manifest | seq: 0}, machine, session, opts)
    end
  end

  @spec fold([EngineReplay.message()], Message.t(), Machine.t(), String.t(), opts()) ::
          {:ok, [Message.t()]} | {:error, term()}
  defp fold(stream, manifest, machine, session, opts) do
    source = Keyword.get(opts, :source)

    # The accumulator is tagged rather than a bare `{messages, seq}` pair: an
    # untagged pair and an `{:error, reason}` are both two-tuples, and a
    # `case` over them can only tell them apart by clause order.
    acc = {:ok, [chokepoint(manifest, opts)], 1}

    result =
      Enum.reduce_while(stream, acc, fn input, {:ok, messages, seq} ->
        ctx = %{session: session, seq: seq, machine: machine, source: source}

        case Normalizer.normalize(input, ctx) do
          {:ok, message} -> {:cont, {:ok, [chokepoint(message, opts) | messages], seq + 1}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, messages, _seq} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  # The single point every message passes through, mirroring
  # `StatifierUI.Trace.Subscriber`'s `buffer_and_fanout/2` minus the buffer
  # and the fan-out. The stamp precedes the projection for ADR-0013's
  # reason; see this module's moduledoc.
  @spec chokepoint(Message.t(), opts()) :: Message.t()
  defp chokepoint(%Message{} = message, opts) do
    message
    |> Otel.stamp(Keyword.get(opts, :otel_context))
    |> project(Keyword.get(opts, :projection))
  end

  @spec project(Message.t(), Projection.Profile.t() | nil) :: Message.t()
  defp project(message, nil), do: message
  defp project(message, %Projection.Profile{} = profile), do: Projection.project(message, profile)
end
