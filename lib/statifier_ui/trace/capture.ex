defmodule StatifierUI.Trace.Capture do
  @moduledoc """
  Record a trace off a live `Statifier.Session`, save it, load it back -
  one call each.

  Every piece of this already existed and none of it was assembled. Taking
  a message list off a running session meant knowing that
  `StatifierUI.Trace.Subscriber` needs the compiled machine, which of its
  three attach modes to pick, and that only the catch-up one recovers the
  initialize burst a subscriber that started late never saw. Saving meant
  knowing `StatifierUI.Trace.Json.encode_lines/1` is the serializer and
  writing the file yourself. Loading had no implementation at all. The
  sequence lived in `test/support/`, which ships to nobody.

      {:ok, messages} = StatifierUI.Trace.Capture.record(session, machine, source: xml)
      :ok = StatifierUI.Trace.Capture.save(messages, "run.jsonl")
      {:ok, messages} = StatifierUI.Trace.Capture.load("run.jsonl")

  ## Where the IO is

  `save/2` and `load/1` are plain functions running in the caller's
  process. That is deliberate and inherited: the subscriber is a GenServer
  in the path of every trace message, and
  `docs/plans/260817-sui-t36.3-session-subscriber-and-trace-normalizer.md`
  refuses to put file IO inside it. Nothing here sends the subscriber a
  message it did not already answer.

  ## Passing `:source` is what makes a capture reloadable

  `%Statifier.Machine{}` does not retain the SCXML it was compiled from, so
  a capture only carries its own chart text when the caller hands `:source`
  to `record/3`. It lands in the `session.start` message
  (`docs/wire-format.md`), and it is what lets a saved file be reopened
  later with no other artefact - `StatifierUI.Kino.inspect_trace/3`
  recompiles the machine from it. A capture taken without `:source` is
  still a valid v1 stream; it just needs its machine supplied again by
  whoever reads it.

  ## The stream is a snapshot, not a subscription

  `record/3` returns what the session has produced *so far* and detaches.
  A session still running will produce more, and calling `record/3` again
  returns a longer list starting from the same `session.start`. For a live
  view that keeps up, attach a `StatifierUI.Trace.Subscriber` and hold it -
  that is what `StatifierUI.Kino.inspect/3` does.
  """

  alias Statifier.Machine
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  @subscriber_opts [
    :source,
    :fixtures,
    :capacity,
    :projection,
    :parent_session,
    :invokeid,
    :otel_context
  ]

  @typedoc "Why a capture or a read refused."
  @type error ::
          :not_recorded
          | {:json, term()}
          | {:line, pos_integer(), term()}
          | Message.from_map_error()
          | File.posix()

  @doc """
  Captures everything `session` has traced so far as a message list.

  Starts a `StatifierUI.Trace.Subscriber` over `machine`, attaches it with
  `catch_up: true` (statifier ADR-0049 - the recorded prefix and the live
  subscription are taken in one session call, so there is no gap and no
  overlap), reads the buffer, and stops the subscriber again.

  `opts` are forwarded to `StatifierUI.Trace.Subscriber.start_link/1`
  unchanged: `:source`, `:fixtures`, `:capacity`, `:projection`,
  `:parent_session`, `:invokeid`, `:otel_context`. See the moduledoc on why
  `:source` is the one worth remembering.

  Returns `{:error, :not_recorded}` when `session` was not started with
  `record: true`. That is a refusal rather than a partial answer on
  purpose: without the recording there is no catch-up, so what came back
  would be whatever happened to arrive after this call - silently missing
  the initialize burst, and indistinguishable from a complete capture once
  written to a file.

  The session must be quiescent for the capture to be reproducible; a
  capture taken mid-macrostep is a valid prefix, not a corrupt stream.
  """
  @spec record(session :: pid(), machine :: Machine.t(), opts :: keyword()) ::
          {:ok, [Message.t()]} | {:error, error()}
  def record(session, %Machine{} = machine, opts \\ []) when is_pid(session) do
    subscriber_opts =
      opts
      |> Keyword.take(@subscriber_opts)
      |> Keyword.put(:machine, machine)

    {:ok, subscriber} = Subscriber.start_link(subscriber_opts)

    try do
      :ok = Subscriber.attach(subscriber, session, catch_up: true)

      if not_recorded?(Subscriber.stats(subscriber)) do
        {:error, :not_recorded}
      else
        {:ok, Subscriber.messages(subscriber)}
      end
    after
      Subscriber.detach(subscriber)
      GenServer.stop(subscriber)
    end
  end

  @doc """
  Writes `messages` to `path` as JSON Lines.

  `StatifierUI.Trace.Json.encode_lines/1` is canonical, so the same message
  list always writes the same bytes - which is what makes a saved capture
  diffable against another run, and what the round-trip law in
  `docs/wire-format.md` rests on.

  Returns `File.write/2`'s result unchanged; a missing directory is a
  `{:error, :enoent}`, not a raise.
  """
  @spec save([Message.t()], path :: Path.t()) :: :ok | {:error, File.posix()}
  def save(messages, path) when is_list(messages) do
    File.write(path, Json.encode_lines(messages))
  end

  @doc """
  Reads a JSON Lines capture back into a message list.

  The result feeds every consumer in this package directly: the pure folds
  in `StatifierUI.Inspector`, `StatifierUI.Live.State.new/2`'s `:messages`
  option, and `StatifierUI.Kino.inspect_trace/3`.

  A file that cannot be read returns `File.read/1`'s posix error; a file
  whose contents are not a v1 stream returns the tagged decode error naming
  the offending line.
  """
  @spec load(path :: Path.t()) :: {:ok, [Message.t()]} | {:error, error()}
  def load(path) do
    case File.read(path) do
      {:ok, document} -> Json.decode_lines(document)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The SCXML a capture carries, from its own `session.start` message.

  `nil` when the stream is empty, does not open with a `session.start`, or
  was captured without `:source`. Used by
  `StatifierUI.Kino.inspect_trace/3` to recompile a machine from the file
  alone; exposed because a host reloading a trace into its own surface
  needs the same thing.
  """
  @spec source([Message.t()]) :: String.t() | nil
  def source(messages) when is_list(messages) do
    Enum.find_value(messages, fn
      %Message{type: "session.start", payload: payload} -> Map.get(payload, "source")
      _other -> nil
    end)
  end

  @spec not_recorded?(Subscriber.stats()) :: boolean()
  defp not_recorded?(%{diagnostics: diagnostics}) do
    Enum.any?(diagnostics, &(&1.kind == :not_recorded))
  end
end
