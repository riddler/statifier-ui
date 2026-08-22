if Code.ensure_loaded?(Kino) do
  defmodule StatifierUI.Kino do
    @moduledoc """
    The Livebook inspector: `inspect/3` composes the four panes -
    configuration diagram, datamodel explorer, event injection, event
    log - over one shared `StatifierUI.Trace.Subscriber`, attached with
    catch-up (statifier ADR-0049), inside one `Kino.Layout`.

    Compiled only when the optional `:kino` dependency is present
    (ADR-0004); a host without it gets a stub whose `inspect/3` raises
    with instructions. Nothing else in this package touches Kino.

    ## Lifecycle

    Every process this module starts - the subscriber and the updater -
    goes through `Kino.start_child/1`, so re-evaluating the cell
    terminates them with it. The session notices the dead subscriber
    through its own monitor and drops it from its subscriber set: that is
    the clean detach, with nothing to unsubscribe by hand. The session
    itself is *not* owned here - it keeps running across cell
    re-evaluations, which is exactly what makes catch-up worth having.

    ## Catch-up needs `record: true`

    Start the session with `record: true` (and `trace: true`) for the
    inspector to reconstruct everything it missed. Without it the
    subscriber falls back to live delivery and the status header labels
    the panes **Live-only** - a partial stream is never presented as
    whole. Replay cost grows with run length (it re-runs the recording in
    the attaching process), so expect cell evaluation on a very long-lived
    session to take correspondingly longer.
    """

    alias StatifierUI.EventInjection
    alias StatifierUI.Fixtures
    alias StatifierUI.Kino.Updater
    alias StatifierUI.Trace.Subscriber

    @doc """
    Builds the inspector for `session` and returns the composed
    `Kino.Layout` for the cell to render.

    `fixtures` is a `StatifierUI.Fixtures.t/0` (or `nil`): it feeds the
    injection palette's per-event buttons. `opts`:

      * `:source` - the SCXML text, forwarded to the subscriber for the
        `session.start` manifest.
      * `:capacity` - the subscriber's buffer capacity (default 1000).
    """
    @spec inspect(pid(), Fixtures.t() | nil, keyword()) :: Kino.Layout.t()
    def inspect(session, fixtures \\ nil, opts \\ []) when is_pid(session) do
      snapshot = Statifier.Session.snapshot(session)

      frames = %{
        status: Kino.Frame.new(placeholder: false),
        diagram: Kino.Frame.new(placeholder: false),
        datamodel: Kino.Frame.new(placeholder: false),
        log: Kino.Frame.new(placeholder: false)
      }

      subscriber_opts =
        [machine: snapshot.machine] ++
          Keyword.take(opts, [:source, :capacity])

      sub = Kino.start_child!({Subscriber, subscriber_opts})

      updater =
        Kino.start_child!(
          {Updater,
           sub: sub,
           machine: snapshot.machine,
           frames: frames,
           initial_configuration: snapshot.configuration}
        )

      # Listener first, then attach: every message the attach folds in (the
      # replayed prefix included) also pings the updater, so there is no
      # messages/1-then-add_listener gap to fall into.
      :ok = Subscriber.add_listener(sub, updater)
      :ok = Subscriber.attach(sub, session, catch_up: true)
      Updater.refresh(updater)

      Kino.Layout.grid(
        [
          frames.status,
          Kino.Layout.grid([frames.diagram, frames.datamodel], columns: 2),
          injection_ui(session, fixtures),
          frames.log
        ],
        columns: 1
      )
    end

    # -- injection pane ------------------------------------------------------

    @spec injection_ui(pid(), Fixtures.t() | nil) :: Kino.Layout.t()
    defp injection_ui(session, fixtures) do
      feedback = Kino.Frame.new(placeholder: false)

      form =
        Kino.Control.form(
          [
            name: Kino.Input.text("Event name"),
            payload: Kino.Input.textarea("Payload (JSON, optional)", monospace: true)
          ],
          submit: "Send"
        )

      Kino.listen(form, fn %{data: %{name: name, payload: payload}} ->
        deliver(session, name, payload, feedback)
      end)

      children = palette_buttons(session, fixtures, feedback) ++ [form, feedback]
      Kino.Layout.grid(children, columns: 1)
    end

    @spec palette_buttons(pid(), Fixtures.t() | nil, Kino.Frame.t()) :: [Kino.Layout.t()]
    defp palette_buttons(session, fixtures, feedback) do
      case EventInjection.build(fixtures) do
        {:ok, pane} ->
          buttons =
            Enum.map(EventInjection.entries(pane), &palette_button(session, &1, feedback))

          if buttons == [], do: [], else: [Kino.Layout.grid(buttons, columns: 3)]

        {:error, reason} ->
          Kino.Frame.render(
            feedback,
            Kino.Markdown.new("**Palette unavailable:** `#{Kernel.inspect(reason)}`")
          )

          []
      end
    end

    @spec palette_button(pid(), EventInjection.Entry.t(), Kino.Frame.t()) :: Kino.Control.t()
    defp palette_button(session, entry, feedback) do
      button = Kino.Control.button(entry.name)

      Kino.listen(button, fn _event ->
        deliver(session, entry.name, entry.payload_text, feedback)
      end)

      button
    end

    @spec deliver(pid(), String.t(), String.t() | nil, Kino.Frame.t()) :: :ok
    defp deliver(session, name, payload_text, feedback) do
      payload =
        case payload_text && String.trim(payload_text) do
          nil -> nil
          "" -> nil
          trimmed -> trimmed
        end

      note =
        case EventInjection.send_draft(session, name, payload) do
          :ok -> "Sent `#{name}` - watch the event log for its macrostep."
          {:error, reason} -> "**Not sent:** `#{Kernel.inspect(reason)}`"
        end

      Kino.Frame.render(feedback, Kino.Markdown.new(note))
    end
  end

  defmodule StatifierUI.Kino.Updater do
    @moduledoc """
    The inspector's render loop: a `GenServer` registered as the shared
    subscriber's listener, re-rendering every frame from the subscriber's
    buffer on a coalesced tick (one render at most every 80 ms, however
    fast messages arrive). Started via
    `Kino.start_child/1` by `StatifierUI.Kino.inspect/3`, and terminated
    with the cell - which is what detaches the inspector.
    """

    use GenServer

    alias StatifierUI.Inspector
    alias StatifierUI.Trace.Subscriber

    @coalesce_ms 80

    @doc "Renders every pane now, skipping the coalescing delay."
    @spec refresh(GenServer.server()) :: :ok
    def refresh(server), do: GenServer.cast(server, :refresh)

    @doc false
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(opts) do
      state = %{
        sub: Keyword.fetch!(opts, :sub),
        machine: Keyword.fetch!(opts, :machine),
        frames: Keyword.fetch!(opts, :frames),
        initial_configuration: Keyword.fetch!(opts, :initial_configuration),
        timer: nil
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_cast(:refresh, state), do: {:noreply, render_panes(state)}

    @impl GenServer
    def handle_info({:statifier_ui, _session_id, _message}, %{timer: nil} = state) do
      {:noreply, %{state | timer: Process.send_after(self(), :render, @coalesce_ms)}}
    end

    def handle_info({:statifier_ui, _session_id, _message}, state), do: {:noreply, state}

    def handle_info(:render, state), do: {:noreply, render_panes(state)}

    def handle_info(_other, state), do: {:noreply, state}

    @spec render_panes(map()) :: map()
    defp render_panes(state) do
      if state.timer, do: Process.cancel_timer(state.timer)

      messages = Subscriber.messages(state.sub)
      stats = Subscriber.stats(state.sub)
      opts = [initial_configuration: state.initial_configuration]

      Kino.Frame.render(state.frames.status, Kino.Markdown.new(Inspector.status(stats)))

      Kino.Frame.render(
        state.frames.diagram,
        Kino.Mermaid.new(Inspector.diagram(state.machine, messages, opts))
      )

      Kino.Frame.render(
        state.frames.datamodel,
        Kino.Markdown.new(Inspector.datamodel(messages))
      )

      Kino.Frame.render(state.frames.log, Kino.Markdown.new(Inspector.event_log(messages)))

      %{state | timer: nil}
    end
  end
else
  defmodule StatifierUI.Kino do
    @moduledoc """
    Stub compiled when the optional `:kino` dependency is absent
    (ADR-0004). Add `{:kino, "~> 0.14"}` to the host's dependencies to
    get the real Livebook inspector.
    """

    @doc "Raises: the inspector needs the optional `:kino` dependency."
    @spec inspect(pid(), term(), keyword()) :: no_return()
    def inspect(_session, _fixtures \\ nil, _opts \\ []) do
      raise RuntimeError,
            "StatifierUI.Kino.inspect/3 needs the optional :kino dependency - " <>
              "add {:kino, \"~> 0.14\"} to your deps and restart"
    end
  end
end
