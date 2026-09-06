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

    ## The scrubber (sui-3gg)

    Four buttons above the diagram - **First**, **Prev**, **Next**,
    **Live** - move the diagram from the live tip to any macrostep in the
    log and back. Selecting a macrostep draws the configuration that
    macrostep settled in, opens its entry in the event log, and marks that
    entry `- selected`; the note above the diagram says which
    point is on screen. `StatifierUI.Inspector` decides all of it, so the
    whole behaviour is testable without Kino - this module only wires
    buttons to `Updater.scrub/2`.

    Buttons rather than a click target on the log entry itself: the log
    pane is `Kino.Markdown`, which renders text and cannot carry a click
    handler back to the runtime. A directly clickable entry is the
    ADR-0008 renderer's to give, not Mermaid-and-Markdown's.

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
    alias StatifierUI.Fixtures.Bundle
    alias StatifierUI.Inspector
    alias StatifierUI.Kino.TraceStepper
    alias StatifierUI.Kino.Updater
    alias StatifierUI.Trace.Capture
    alias StatifierUI.Trace.Message
    alias StatifierUI.Trace.Subscriber
    alias StatifierUI.TruthTable

    # Four static buttons, built once: a control rebuilt per render would
    # leak a listener per rebuild, and the moves are relative anyway, so
    # nothing here has to know how many macrosteps exist. The Updater asks
    # Inspector.step/3 where each move lands.
    @scrubber_moves [{:first, "|< First"}, {:prev, "< Prev"}, {:next, "Next >"}, {:live, "Live"}]

    @doc """
    Renders `fixtures`' truth table - every expression evaluated across every
    dataset (ADR-0006) - as a `Kino.Markdown` widget.

    Independent of `inspect/3` and of any session: a truth table is a fact
    about expressions and datasets, so this needs no running chart and no
    Phoenix. `opts` are split by owner - `:expressions`, `:datasets`,
    `:functions`, and `:providers` go to `StatifierUI.TruthTable.build/2`,
    and the rest to `StatifierUI.TruthTable.Markdown.render/2`.
    """
    @spec truth_table(Fixtures.t(), keyword()) :: Kino.Markdown.t()
    def truth_table(%Fixtures{} = fixtures, opts \\ []) do
      {build_opts, render_opts} =
        Keyword.split(opts, [:expressions, :datasets, :functions, :providers])

      fixtures
      |> TruthTable.build(build_opts)
      |> TruthTable.Markdown.render(render_opts)
      |> Kino.Markdown.new()
    end

    @doc """
    Renders one fragment's fixture bundle as its "test this step" panel - its
    truth table plus its expectation results (sui-13q) - as a
    `Kino.Markdown` widget.

    Like `truth_table/2`, independent of `inspect/3` and of any session: a
    bundle is a fact about one palette entry's examples, so this needs no
    running chart. `opts` go to
    `StatifierUI.Fixtures.Bundle.Markdown.render/2`, which forwards each one
    to the layer that owns it.
    """
    @spec test_panel(Bundle.t(), keyword()) :: Kino.Markdown.t()
    def test_panel(%Bundle{} = bundle, opts \\ []) do
      bundle
      |> Bundle.Markdown.render(opts)
      |> Kino.Markdown.new()
    end

    @doc """
    Renders every bundle a palette discovery found, one panel after another,
    as a single `Kino.Markdown` widget.

    `discovery` is what `StatifierUI.Fixtures.Bundle.discover/2` or
    `discover_dir/2` returned.
    """
    @spec palette_panel(Bundle.discovery(), keyword()) :: Kino.Markdown.t()
    def palette_panel(discovery, opts \\ []) when is_map(discovery) do
      discovery
      |> Bundle.Markdown.render_discovery(opts)
      |> Kino.Markdown.new()
    end

    @doc """
    Builds the inspector for `session` and returns the composed
    `Kino.Layout` for the cell to render.

    `fixtures` is a `t:StatifierUI.Fixtures.t/0` (or `nil`): it feeds the
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
        note: Kino.Frame.new(placeholder: false),
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
          scrubber_ui(updater),
          frames.note,
          Kino.Layout.grid([frames.diagram, frames.datamodel], columns: 2),
          injection_ui(session, fixtures),
          frames.log
        ],
        columns: 1
      )
    end

    @doc """
    Reopens a saved trace: the third leg of
    `StatifierUI.Trace.Capture`'s record / save / reload.

        StatifierUI.Kino.inspect_trace("run.jsonl")

    `trace` is a file path (read through
    `StatifierUI.Trace.Capture.load/1`) or an already-loaded
    `t:StatifierUI.Trace.Message.t/0` list. `fixtures` is accepted for
    symmetry with `inspect/3` and is currently unused - the palette it
    feeds is an injection affordance, and there is nothing to inject into.

    `opts`:

      * `:machine` - the compiled `%Statifier.Machine{}` to draw against.
        Optional: without it the machine is recompiled from the SCXML the
        trace carries in its own `session.start` message, which is what
        `StatifierUI.Trace.Capture.record/3`'s `:source` option puts
        there. A trace captured without `:source` and reopened without
        `:machine` has no chart to draw and returns a
        `Kino.Markdown` saying so rather than a diagram it cannot draw.

    ## Stepping it (sui-2uz)

    The layout carries the same **|< First / < Prev / Next > / Live**
    scrubber `inspect/3` has, plus a **jump to** select listing every
    macrostep by number and event, and a datamodel diff pane saying what
    the selected macrostep changed. A persisted stream has no tip that
    moves, so "Live" here means the end of the recording.

    Stepping a recording asks the engine for nothing: every configuration
    shown was stamped by the engine into the file, and a trace read back
    through `StatifierUI.Trace.Capture.load/1` got its contents from
    statifier ADR-0034 replay re-driving the core at capture time. The
    controls move a *selection* over messages already in hand.

    ## What this is still not

    **There is no injection form.** Injection drives a session, and a file
    has none. The `fixtures` argument stays accepted and unused for that
    reason.
    """
    @spec inspect_trace(Path.t() | [Message.t()], Fixtures.t() | nil, keyword()) ::
            Kino.Layout.t() | Kino.Markdown.t()
    def inspect_trace(trace, fixtures \\ nil, opts \\ [])

    def inspect_trace(path, fixtures, opts) when is_binary(path) do
      case Capture.load(path) do
        {:ok, messages} -> inspect_trace(messages, fixtures, opts)
        {:error, reason} -> Kino.Markdown.new(load_failure(path, reason))
      end
    end

    def inspect_trace(messages, _fixtures, opts) when is_list(messages) do
      case trace_machine(messages, opts) do
        {:ok, machine} -> trace_layout(machine, messages)
        {:error, reason} -> Kino.Markdown.new(reason)
      end
    end

    @spec trace_layout(Statifier.Machine.t(), [Message.t()]) :: Kino.Layout.t()
    defp trace_layout(machine, messages) do
      frames =
        Map.new([:note, :diagram, :datamodel, :diff, :log], fn key ->
          {key, Kino.Frame.new(placeholder: false)}
        end)

      stepper =
        Kino.start_child!({TraceStepper, machine: machine, messages: messages, frames: frames})

      TraceStepper.refresh(stepper)

      Kino.Layout.grid(
        [
          Kino.Markdown.new(Inspector.persisted_status(messages)),
          stepper_ui(stepper, messages),
          frames.note,
          Kino.Layout.grid([frames.diagram, frames.datamodel], columns: 2),
          frames.diff,
          frames.log
        ],
        columns: 1
      )
    end

    # The scrubber's four moves plus the jump-to-event select, over a list
    # that cannot grow: a persisted trace's macrosteps are all present when
    # the widget is built, so unlike the live scrubber the select can be
    # populated once and never rebuilt.
    @spec stepper_ui(pid(), [Message.t()]) :: Kino.Layout.t()
    defp stepper_ui(stepper, messages) do
      buttons =
        Enum.map(@scrubber_moves, fn {move, label} ->
          button = Kino.Control.button(label)
          Kino.listen(button, fn _event -> TraceStepper.scrub(stepper, move) end)
          button
        end)

      Kino.Layout.grid(buttons ++ jump_ui(stepper, messages), columns: length(buttons) + 1)
    end

    # `Kino.Input.select/3` raises on an empty option list, and a trace with
    # no macrostep in it is a real case (a session.start and nothing else),
    # so the control is omitted rather than fabricated.
    @spec jump_ui(pid(), [Message.t()]) :: [Kino.Input.t()]
    defp jump_ui(stepper, messages) do
      case Inspector.points(messages) do
        [] ->
          []

        points ->
          input = Kino.Input.select("Jump to", Enum.map(points, &jump_option/1))
          Kino.listen(input, fn %{value: n} -> TraceStepper.select(stepper, n) end)
          [input]
      end
    end

    @spec jump_option(Inspector.point()) :: {non_neg_integer(), String.t()}
    defp jump_option(%{macrostep: n, event: nil}), do: {n, "#{n} - initialize"}
    defp jump_option(%{macrostep: n, event: event}), do: {n, "#{n} - #{event}"}

    # The machine is the one thing a message list cannot always supply.
    # Preferring an explicit :machine over the embedded source matters for
    # a projected capture, where `allow_source: false` withholds the chart
    # text (ADR-0012) and the caller has to bring it.
    @spec trace_machine([Message.t()], keyword()) ::
            {:ok, Statifier.Machine.t()} | {:error, String.t()}
    defp trace_machine(messages, opts) do
      case {Keyword.get(opts, :machine), Capture.source(messages)} do
        {%Statifier.Machine{} = machine, _source} ->
          {:ok, machine}

        {nil, nil} ->
          {:error,
           "**No chart to draw.** This trace carries no `source` in its " <>
             "`session.start` message, so there is nothing to recompile. Pass " <>
             "`machine:` to `inspect_trace/3`, or re-capture with " <>
             "`StatifierUI.Trace.Capture.record/3`'s `:source` option."}

        {nil, source} ->
          case Statifier.compile(source) do
            {:ok, machine} ->
              {:ok, machine}

            {:error, reason} ->
              {:error,
               "**The chart this trace carries no longer compiles.** " <>
                 "`Statifier.compile/1` said: `#{Kernel.inspect(reason)}`."}
          end
      end
    end

    @spec load_failure(Path.t(), term()) :: String.t()
    defp load_failure(path, reason) do
      "**Could not read `#{path}`.** `StatifierUI.Trace.Capture.load/1` said: " <>
        "`#{Kernel.inspect(reason)}`."
    end

    # -- scrubber pane -------------------------------------------------------

    @spec scrubber_ui(pid()) :: Kino.Layout.t()
    defp scrubber_ui(updater) do
      buttons =
        Enum.map(@scrubber_moves, fn {move, label} ->
          button = Kino.Control.button(label)
          Kino.listen(button, fn _event -> Updater.scrub(updater, move) end)
          button
        end)

      Kino.Layout.grid(buttons, columns: length(buttons))
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

    @doc """
    Moves the scrubber one step (`:first`, `:prev`, `:next`, `:live`) and
    re-renders immediately - a click waiting out the coalescing delay would
    read as a dropped click.
    """
    @spec scrub(GenServer.server(), :live | :first | :prev | :next) :: :ok
    def scrub(server, move), do: GenServer.cast(server, {:scrub, move})

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
        selection: :live,
        timer: nil
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_cast(:refresh, state), do: {:noreply, render_panes(state)}

    def handle_cast({:scrub, move}, state) do
      points = Inspector.points(Subscriber.messages(state.sub))
      selection = Inspector.step(state.selection, points, move)
      {:noreply, render_panes(%{state | selection: selection})}
    end

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

      opts = [
        initial_configuration: state.initial_configuration,
        selection: state.selection
      ]

      Kino.Frame.render(state.frames.status, Kino.Markdown.new(Inspector.status(stats)))

      Kino.Frame.render(
        state.frames.note,
        Kino.Markdown.new(Inspector.selection_note(messages, opts))
      )

      Kino.Frame.render(
        state.frames.diagram,
        Kino.Mermaid.new(Inspector.diagram(state.machine, messages, opts))
      )

      Kino.Frame.render(
        state.frames.datamodel,
        Kino.Markdown.new(Inspector.datamodel(messages))
      )

      Kino.Frame.render(state.frames.log, Kino.Markdown.new(Inspector.event_log(messages, opts)))

      %{state | timer: nil}
    end
  end

  defmodule StatifierUI.Kino.TraceStepper do
    @moduledoc """
    The persisted inspector's render loop (`sui-2uz`): a `GenServer` holding
    one immutable message list and the point in it the panes are showing.

    `StatifierUI.Kino.Updater` is its live sibling. The two differ in
    exactly one thing - where the messages come from. The updater re-reads
    a `StatifierUI.Trace.Subscriber` on every render because the stream is
    still growing; a persisted trace is complete when the widget is built,
    so this holds the list and re-renders only when the selection moves.
    Both ask `StatifierUI.Inspector` where a move lands and what each pane
    should say, so the stepping vocabulary is one definition rather than
    two.

    Started via `Kino.start_child/1`, so re-evaluating the cell terminates
    it. There is nothing to detach: no session, no subscriber, no monitor.
    """

    use GenServer

    alias StatifierUI.Inspector

    @doc "Renders every pane now."
    @spec refresh(GenServer.server()) :: :ok
    def refresh(server), do: GenServer.cast(server, :refresh)

    @doc """
    Moves the selection one scrubber step (`:first`, `:prev`, `:next`,
    `:live`) and re-renders. On a persisted trace `:live` is the end of the
    recording rather than a tip that moves.
    """
    @spec scrub(GenServer.server(), :live | :first | :prev | :next) :: :ok
    def scrub(server, move), do: GenServer.cast(server, {:scrub, move})

    @doc """
    Jumps straight to macrostep `n` - what the "Jump to" select does, and
    what a scrubber alone cannot do on a long recording.
    """
    @spec select(GenServer.server(), non_neg_integer()) :: :ok
    def select(server, n) when is_integer(n) and n >= 0 do
      GenServer.cast(server, {:select, n})
    end

    @doc false
    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(opts) do
      state = %{
        machine: Keyword.fetch!(opts, :machine),
        messages: Keyword.fetch!(opts, :messages),
        frames: Keyword.fetch!(opts, :frames),
        selection: Keyword.get(opts, :selection, :live)
      }

      {:ok, state}
    end

    @impl GenServer
    def handle_cast(:refresh, state), do: {:noreply, render_panes(state)}

    def handle_cast({:scrub, move}, state) do
      selection = Inspector.step(state.selection, Inspector.points(state.messages), move)
      {:noreply, render_panes(%{state | selection: selection})}
    end

    def handle_cast({:select, n}, state) do
      {:noreply, render_panes(%{state | selection: {:macrostep, n}})}
    end

    @spec render_panes(map()) :: map()
    defp render_panes(state) do
      opts = [selection: state.selection]

      Kino.Frame.render(
        state.frames.note,
        Kino.Markdown.new(Inspector.selection_note(state.messages, opts))
      )

      Kino.Frame.render(
        state.frames.diagram,
        Kino.Mermaid.new(Inspector.diagram(state.machine, state.messages, opts))
      )

      Kino.Frame.render(
        state.frames.datamodel,
        Kino.Markdown.new(Inspector.datamodel(state.messages, opts))
      )

      Kino.Frame.render(
        state.frames.diff,
        Kino.Markdown.new(Inspector.datamodel_diff(state.messages, opts))
      )

      Kino.Frame.render(
        state.frames.log,
        Kino.Markdown.new(Inspector.event_log(state.messages, opts))
      )

      state
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

    @doc """
    Raises: the widget needs the optional `:kino` dependency.

    Reading the trace does not - `StatifierUI.Trace.Capture.load/1` and
    every `StatifierUI.Inspector` fold are pure and always compiled, so a
    host without Kino still gets the diagram source, the datamodel, and
    the event log to render its own way.
    """
    @spec inspect_trace(term(), term(), keyword()) :: no_return()
    def inspect_trace(_trace, _fixtures \\ nil, _opts \\ []) do
      raise RuntimeError,
            "StatifierUI.Kino.inspect_trace/3 needs the optional :kino dependency - " <>
              "add {:kino, \"~> 0.14\"} to your deps and restart, or call " <>
              "StatifierUI.Trace.Capture.load/1 and StatifierUI.Inspector directly"
    end

    @doc """
    Raises: the widget needs the optional `:kino` dependency.

    The table itself does not - `StatifierUI.TruthTable.build/2` and
    `StatifierUI.TruthTable.Markdown.render/2` are pure and always compiled,
    so a host without Kino still gets the Markdown to render its own way.
    """
    @spec truth_table(term(), keyword()) :: no_return()
    def truth_table(_fixtures, _opts \\ []) do
      raise RuntimeError,
            "StatifierUI.Kino.truth_table/2 needs the optional :kino dependency - " <>
              "add {:kino, \"~> 0.14\"} to your deps and restart, or call " <>
              "StatifierUI.TruthTable.Markdown.render/2 directly"
    end

    @doc """
    Raises: the widget needs the optional `:kino` dependency.

    The panel itself does not - `StatifierUI.Fixtures.Bundle.Markdown.render/2`
    is pure and always compiled, so a host without Kino still gets the
    Markdown to render its own way.
    """
    @spec test_panel(term(), keyword()) :: no_return()
    def test_panel(_bundle, _opts \\ []) do
      raise RuntimeError,
            "StatifierUI.Kino.test_panel/2 needs the optional :kino dependency - " <>
              "add {:kino, \"~> 0.14\"} to your deps and restart, or call " <>
              "StatifierUI.Fixtures.Bundle.Markdown.render/2 directly"
    end

    @doc """
    Raises: the widget needs the optional `:kino` dependency.

    `StatifierUI.Fixtures.Bundle.Markdown.render_discovery/2` is the pure
    equivalent.
    """
    @spec palette_panel(term(), keyword()) :: no_return()
    def palette_panel(_discovery, _opts \\ []) do
      raise RuntimeError,
            "StatifierUI.Kino.palette_panel/2 needs the optional :kino dependency - " <>
              "add {:kino, \"~> 0.14\"} to your deps and restart, or call " <>
              "StatifierUI.Fixtures.Bundle.Markdown.render_discovery/2 directly"
    end
  end
end
