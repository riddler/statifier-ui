if Code.ensure_loaded?(Phoenix.Component) do
  defmodule StatifierUI.Live do
    @moduledoc """
    Read-only LiveView components for a host application's ops views: the
    current-state diagram and the run-history event log, side by side over
    one trace stream in wire format v1 (`docs/wire-format.md`), live or
    persisted.

    Compiled only when the optional `:phoenix_live_view` dependency is
    present (ADR-0004); a host without it gets a stub whose every component
    raises with instructions. Nothing else in this package touches
    `Phoenix.Component`.

    Every component is a **function component over
    `StatifierUI.Live.State`** - there is no LiveComponent, no process, and
    no `mount/3` here. The host owns the socket, the subscription, and the
    events; this module owns markup. That is what makes these embeddable in
    a page the host already has rather than a page it has to give up.

    ## Full fidelity

    These are dev/ops surfaces and they render what the stream carries. If
    the stream was produced under an ADR-0012 projection profile, `status/1`
    says so in a banner and redacted slots render as the stream's own
    sentinel - the redacted tenant-facing story is a different component
    (sui-hmn), not a flag on this one.

    ## Embedding

    Full worked example: `docs/ops-embedding.md`. The short version, for a
    live stream:

        # mount/3
        {:ok, subscriber} = Subscriber.start_link(machine: machine, source: source)
        :ok = Subscriber.attach(subscriber, session, catch_up: true)
        :ok = Subscriber.add_listener(subscriber, self())

        socket =
          assign(socket, :trace, State.new(machine) |> State.sync(subscriber))

        # handle_info/2 - the subscriber's fan-out shape
        def handle_info({:statifier_ui, _session, message}, socket) do
          {:noreply, update(socket, :trace, &State.push(&1, message))}
        end

        # handle_event/3 - the two events the components emit
        def handle_event("statifier_ui_scrub", %{"move" => move}, socket) do
          {:noreply, update(socket, :trace, &State.scrub(&1, String.to_existing_atom(move)))}
        end

        def handle_event("statifier_ui_select", %{"macrostep" => n}, socket) do
          {:noreply, update(socket, :trace, &State.select(&1, String.to_integer(n)))}
        end

        # render/1
        <StatifierUI.Live.ops_view id="ops" state={@trace} />

    A persisted stream drops the subscriber and the `handle_info/2` clause:
    `State.new(machine, messages: messages)` is the whole difference.

    ## The diagram is Mermaid source, and no Mermaid client ships

    `diagram/1` emits `StatifierUI.Diagram`'s `stateDiagram-v2` source into
    a `<pre class="mermaid">`, the shape a Mermaid client renders in place.
    Attaching that client is the host's - pass `hook={"MyMermaid"}` and the
    element carries `phx-hook`. The JavaScript this package does ship is the
    expression field's hooks under `assets/js`, as source for the host's own
    bundler to compile (ADR-0009); nothing here renders the diagram for you.
    ADR-0008's client-side elkjs SVG renderer is the eventual full-fidelity
    diagram and is not built yet; when it is, it replaces this pane's body
    and not its contract.

    ## Class names, not styles

    Every element carries a `statifier-ui-*` class and the engine's own
    document-order identities as `data-*` attributes (`data-macrostep`,
    `data-round`, `data-configuration`), per ADR-0007's sync contract. No CSS
    ships: a host page styles these with its own design system, and the
    `data-*` stamps are what tests assert on.
    """

    use Phoenix.Component

    alias StatifierUI.EventLog
    alias StatifierUI.EventLog.Labels
    alias StatifierUI.EventLog.Macrostep
    alias StatifierUI.EventLog.Round
    alias StatifierUI.Live.State
    alias StatifierUI.Trace.Message

    @scrub_event "statifier_ui_scrub"
    @select_event "statifier_ui_select"

    attr(:id, :string, required: true, doc: "DOM id root; panes derive theirs from it.")
    attr(:state, State, required: true, doc: "the read model - see `StatifierUI.Live.State`.")

    attr(:target, :any,
      default: nil,
      doc: "`phx-target` for the emitted events, when mounted inside a LiveComponent."
    )

    attr(:scrub_event, :string, default: @scrub_event)
    attr(:select_event, :string, default: @select_event)
    attr(:hook, :string, default: nil, doc: "`phx-hook` for the diagram element.")
    attr(:class, :string, default: nil)

    @doc """
    The composed ops view: status, scrubber, diagram, and event log.

    A host that wants a different layout composes `status/1`, `scrubber/1`,
    `diagram/1`, and `event_log/1` itself - this component adds nothing but
    an arrangement.
    """
    @spec ops_view(map()) :: Phoenix.LiveView.Rendered.t()
    def ops_view(assigns) do
      ~H"""
      <div class={["statifier-ui-ops-view", @class]} id={@id}>
        <.status id={"#{@id}-status"} state={@state} />
        <.scrubber
          id={"#{@id}-scrubber"}
          state={@state}
          target={@target}
          scrub_event={@scrub_event}
        />
        <div class="statifier-ui-panes">
          <.diagram id={"#{@id}-diagram"} state={@state} hook={@hook} />
          <.event_log
            id={"#{@id}-event-log"}
            state={@state}
            target={@target}
            select_event={@select_event}
          />
        </div>
      </div>
      """
    end

    attr(:id, :string, required: true)
    attr(:state, State, required: true)

    @doc """
    The stream's own header: session id, subscriber status and counts, one
    line per diagnostic, and the ADR-0012 projection banner when the stream
    carries one.

    A persisted stream has no `StatifierUI.Trace.Subscriber` stats, and the
    pane says "persisted" rather than inventing a status.
    """
    @spec status(map()) :: Phoenix.LiveView.Rendered.t()
    def status(assigns) do
      assigns = assign(assigns, :stats, assigns.state.stats)

      ~H"""
      <div class="statifier-ui-status" id={@id} data-status={status_kind(@stats)}>
        <p class="statifier-ui-status-line">
          <span class="statifier-ui-session">{session_label(@stats)}</span>
          <span class="statifier-ui-status-kind">{status_kind(@stats)}</span>
          <span :if={@stats} class="statifier-ui-counts">
            {@stats.buffered} buffered, {@stats.dropped} dropped, {@stats.errors} errors
          </span>
        </p>
        <p
          :for={diagnostic <- diagnostics(@stats)}
          class="statifier-ui-diagnostic"
          data-kind={diagnostic.kind}
        >
          <strong>{diagnostic_label(diagnostic.kind)}:</strong> {diagnostic.message}
        </p>
        <p :if={projection_profile(@stats)} class="statifier-ui-projection">
          Datamodel and payload values are withheld from this stream under profile
          <code>{projection_profile(@stats)}</code>. Redacted slots are not unbound.
        </p>
      </div>
      """
    end

    attr(:id, :string, required: true)
    attr(:state, State, required: true)
    attr(:target, :any, default: nil)
    attr(:scrub_event, :string, default: @scrub_event)

    @doc """
    The four scrubber controls - First, Prev, Next, Live - and the note
    saying which point is on screen.

    Each button sends `scrub_event` with `move` set to `first`, `prev`,
    `next`, or `live`; `StatifierUI.Live.State.scrub/2` takes it from there.
    The buttons are always enabled: with nothing to select every move
    resolves to `:live`, which is where the view already is.
    """
    @spec scrubber(map()) :: Phoenix.LiveView.Rendered.t()
    def scrubber(assigns) do
      assigns =
        assigns
        |> assign(:resolution, State.resolution(assigns.state))
        |> assign(:selected, State.selected_macrostep(assigns.state))

      ~H"""
      <div class="statifier-ui-scrubber" id={@id} data-selection={selection_label(@selected)}>
        <button
          :for={{move, label} <- [{"first", "First"}, {"prev", "Prev"}, {"next", "Next"}, {"live", "Live"}]}
          type="button"
          class="statifier-ui-scrub-button"
          data-move={move}
          phx-click={@scrub_event}
          phx-value-move={move}
          phx-target={@target}
        >
          {label}
        </button>
        <p class="statifier-ui-selection-note" data-resolution={resolution_kind(@resolution)}>
          {resolution_note(@resolution, @state)}
        </p>
      </div>
      """
    end

    attr(:id, :string, required: true)
    attr(:state, State, required: true)
    attr(:hook, :string, default: nil)

    @doc """
    The current-state diagram: `StatifierUI.Diagram`'s Mermaid source for
    the configuration the selection implies, in a `<pre class="mermaid">`
    for the host's Mermaid client to render in place.

    The active configuration is also stamped on the element as
    `data-configuration` (a space-separated index list), so a test - or a
    host's own renderer - can read what is highlighted without parsing
    Mermaid.
    """
    @spec diagram(map()) :: Phoenix.LiveView.Rendered.t()
    def diagram(assigns) do
      assigns =
        assigns
        |> assign(:source, State.diagram_source(assigns.state))
        |> assign(:configuration, State.configuration(assigns.state))

      ~H"""
      <div class="statifier-ui-diagram" id={@id}>
        <pre
          class="mermaid statifier-ui-diagram-source"
          id={"#{@id}-source"}
          phx-hook={@hook}
          data-configuration={Enum.join(@configuration, " ")}
        >{@source}</pre>
      </div>
      """
    end

    attr(:id, :string, required: true)
    attr(:state, State, required: true)
    attr(:target, :any, default: nil)
    attr(:select_event, :string, default: @select_event)

    @doc """
    The run history: one collapsible entry per macrostep, each holding its
    rounds and the effects that carry no round.

    Clicking an entry sends `select_event` with `macrostep`, which is the
    link `StatifierUI.Kino`'s Markdown pane cannot have - a Markdown
    document has no click target to send back. The selected entry is open
    and marked, and its configuration is what the diagram is drawing.

    A message list the log refuses - more than one session on one timeline,
    which `docs/wire-format.md` forbids - renders as a visible error rather
    than raising, so the rest of the ops view keeps working.
    """
    @spec event_log(map()) :: Phoenix.LiveView.Rendered.t()
    def event_log(assigns) do
      assigns = assign(assigns, :log, State.log(assigns.state))

      ~H"""
      <div class="statifier-ui-event-log" id={@id}>
        <.log_body
          log={@log}
          selected={State.selected_macrostep(@state)}
          target={@target}
          select_event={@select_event}
        />
      </div>
      """
    end

    # -- Event log body -----------------------------------------------------
    #
    # Private components carry no `attr` declarations: the pair below is
    # multi-clause, which is how the refused-log case stays a pattern match
    # rather than a conditional inside the markup.

    @spec log_body(map()) :: Phoenix.LiveView.Rendered.t()
    defp log_body(%{log: {:error, reason}} = assigns) do
      assigns = assign(assigns, :reason, inspect(reason))

      ~H"""
      <p class="statifier-ui-log-error">Event log unavailable: <code>{@reason}</code></p>
      """
    end

    defp log_body(%{log: {:ok, log}} = assigns) do
      assigns =
        assigns
        |> assign(:log, log)
        |> assign(:labels, Labels.from_log(log))
        |> assign(:open, assigns.selected || last_macrostep(log))

      ~H"""
      <p class="statifier-ui-log-session">
        Event log: <code>{@log.session || "(no session)"}</code>
      </p>
      <p :if={@log.truncated?} class="statifier-ui-log-truncated">
        Earliest messages were dropped from the buffer; this log starts mid-run.
      </p>
      <ol class="statifier-ui-macrosteps">
        <li :for={macrostep <- @log.macrosteps} class="statifier-ui-macrostep">
          <details
            data-macrostep={macrostep.macrostep}
            data-selected={to_string(macrostep.macrostep == @selected)}
            open={macrostep.macrostep == @open}
          >
            <summary
              class="statifier-ui-macrostep-summary"
              phx-click={@select_event}
              phx-value-macrostep={macrostep.macrostep}
              phx-target={@target}
            >
              Macrostep {macrostep.macrostep} - {macrostep_event(macrostep)}
              <span :if={macrostep.configuration == nil} class="statifier-ui-not-quiescent">
                (not quiescent)
              </span>
              <span :if={macrostep.macrostep == @selected} class="statifier-ui-shown">
                - shown in the diagram
              </span>
            </summary>
            <ol class="statifier-ui-rounds">
              <.round_item :for={round <- macrostep.rounds} round={round} labels={@labels} />
            </ol>
            <ul :if={macrostep.effects != []} class="statifier-ui-effects">
              <li :for={effect <- macrostep.effects} class="statifier-ui-effect" data-type={effect.type}>
                <code>{effect.type}</code>{effect_summary(effect)}
              </li>
            </ul>
          </details>
        </li>
      </ol>
      <ul :if={footer_messages(@log) != []} class="statifier-ui-log-footer">
        <li :for={message <- footer_messages(@log)} data-type={message.type}>
          <code>{message.type}</code>{effect_summary(message)}
        </li>
      </ul>
      """
    end

    @spec round_item(map()) :: Phoenix.LiveView.Rendered.t()
    defp round_item(assigns) do
      ~H"""
      <li class="statifier-ui-round" data-round={@round.round}>
        <p class="statifier-ui-round-header">
          Round {@round.round} - {round_event(@round)}
        </p>
        <dl class="statifier-ui-round-fields">
          <div :if={@round.t_indexes} class="statifier-ui-field" data-field="selected">
            <dt>Selected</dt>
            <dd>{transitions(@labels, @round.t_indexes)}</dd>
          </div>
          <div :if={@round.exited != []} class="statifier-ui-field" data-field="exited">
            <dt>Exited</dt>
            <dd>{Labels.states(@labels, @round.exited)}</dd>
          </div>
          <div :if={@round.entered != []} class="statifier-ui-field" data-field="entered">
            <dt>Entered</dt>
            <dd>{Labels.states(@labels, @round.entered)}</dd>
          </div>
          <div :if={@round.cause} class="statifier-ui-field" data-field="cause">
            <dt>Raised by</dt>
            <dd>{cause_text(@labels, @round.cause)}</dd>
          </div>
          <div :if={@round.content != []} class="statifier-ui-field" data-field="content">
            <dt>Executed</dt>
            <dd>
              <ul>
                <li :for={item <- @round.content}>{content_text(@labels, item)}</li>
              </ul>
            </dd>
          </div>
          <div :if={@round.configuration} class="statifier-ui-field" data-field="configuration">
            <dt>Configuration</dt>
            <dd data-configuration={Enum.join(@round.configuration, " ")}>
              {Labels.states(@labels, @round.configuration)}
            </dd>
          </div>
          <div :if={@round.budget_exhausted} class="statifier-ui-field" data-field="budget">
            <dt>Budget exhausted</dt>
            <dd>{budget_text(@round.budget_exhausted)}</dd>
          </div>
        </dl>
      </li>
      """
    end

    # -- Presentation helpers ------------------------------------------------

    @spec status_kind(map() | nil) :: String.t()
    defp status_kind(nil), do: "persisted"
    defp status_kind(%{status: status}), do: to_string(status)

    @spec session_label(map() | nil) :: String.t()
    defp session_label(%{session: session}) when is_binary(session), do: session
    defp session_label(_stats), do: "(no session)"

    @spec diagnostics(map() | nil) :: [map()]
    defp diagnostics(%{diagnostics: diagnostics}), do: diagnostics
    defp diagnostics(_stats), do: []

    @spec diagnostic_label(atom()) :: String.t()
    defp diagnostic_label(kind) when kind in [:not_recorded, :catch_up_failed], do: "Live-only"
    defp diagnostic_label(:late_attach), do: "Late attach"
    defp diagnostic_label(kind), do: kind |> Atom.to_string() |> String.capitalize()

    @spec projection_profile(map() | nil) :: String.t() | nil
    defp projection_profile(%{projection: %{profile: profile}}), do: to_string(profile)
    defp projection_profile(_stats), do: nil

    @spec selection_label(non_neg_integer() | nil) :: String.t()
    defp selection_label(nil), do: "live"
    defp selection_label(n), do: "macrostep-#{n}"

    @spec resolution_kind(term()) :: String.t()
    defp resolution_kind(:live), do: "live"
    defp resolution_kind({kind, _n}), do: to_string(kind)
    defp resolution_kind({kind, _n, _from}), do: to_string(kind)

    # The wording is the inspector's, minus its Markdown emphasis: a LiveView
    # host renders elements, and the note's `**Showing**` would arrive as
    # literal asterisks.
    @spec resolution_note(term(), State.t()) :: String.t()
    defp resolution_note(:live, _state), do: "Showing the live tip."

    defp resolution_note({:quiescent, n}, state) do
      "Showing macrostep #{n}#{event_suffix(state, n)}, at its quiescent configuration."
    end

    defp resolution_note({:carried, n, from}, state) do
      "Showing macrostep #{n}#{event_suffix(state, n)}, which is not quiescent; the " <>
        "configuration drawn is macrostep #{from}'s, carried forward."
    end

    defp resolution_note({:before_first, n}, state) do
      "Showing macrostep #{n}#{event_suffix(state, n)}; no configuration was stamped at " <>
        "or below it, so the session's initial configuration is drawn."
    end

    @spec event_suffix(State.t(), non_neg_integer()) :: String.t()
    defp event_suffix(state, n) do
      case Enum.find(State.points(state), &(&1.macrostep == n)) do
        nil -> ""
        %{event: nil} -> " (initialize)"
        %{event: name} -> " (#{name})"
      end
    end

    # With nothing selected the newest macrostep is the one left open, which is
    # what `StatifierUI.EventLog.Markdown`'s `open: :last` default does.
    @spec last_macrostep(EventLog.t()) :: non_neg_integer() | nil
    defp last_macrostep(%EventLog{macrosteps: []}), do: nil
    defp last_macrostep(%EventLog{macrosteps: macrosteps}), do: List.last(macrosteps).macrostep

    @spec macrostep_event(Macrostep.t()) :: String.t()
    defp macrostep_event(%Macrostep{event: %{"name" => name}}), do: name
    defp macrostep_event(%Macrostep{}), do: "initialize"

    @spec round_event(Round.t()) :: String.t()
    defp round_event(%Round{event: %{"name" => name}}), do: name
    defp round_event(%Round{eventless?: true}), do: "(eventless)"
    defp round_event(%Round{}), do: "-"

    @spec transitions(Labels.t(), [non_neg_integer()]) :: String.t()
    defp transitions(_labels, []), do: "none"

    defp transitions(labels, t_indexes) do
      Enum.map_join(t_indexes, ", ", &Labels.transition(labels, &1))
    end

    @spec cause_text(Labels.t(), map()) :: String.t()
    defp cause_text(labels, cause) do
      "#{Labels.origin(labels, cause["origin"])} at " <>
        "(macrostep #{cause["macrostep"]}, round #{cause["round"]})"
    end

    @spec content_text(Labels.t(), %{owner: map(), c_indexes: [non_neg_integer()]}) :: String.t()
    defp content_text(labels, %{owner: owner, c_indexes: c_indexes}) do
      contents = Enum.map_join(c_indexes, ", ", &Labels.content(labels, &1))
      "#{Labels.owner(labels, owner)}: #{contents}"
    end

    @spec budget_text(map()) :: String.t()
    defp budget_text(payload) do
      pending = length(payload["pending_internal_events"] || [])
      "after #{payload["budget"]} rounds; #{pending} internal events still pending"
    end

    @spec footer_messages(EventLog.t()) :: [Message.t()]
    defp footer_messages(%EventLog{session_messages: session_messages}) do
      Enum.filter(
        session_messages,
        &(&1.type in ["session.halted", "session.terminated", "session.unroutable"])
      )
    end

    # The key subsets mirror `StatifierUI.EventLog.Markdown`'s effect lines
    # deliberately: the same message should read the same in a notebook and in
    # an ops page. They are a display convention, not a second reading of the
    # wire format - a type this does not name still renders, by its type.
    @spec effect_summary(Message.t()) :: String.t()
    defp effect_summary(%Message{type: "effect.log", payload: payload}) do
      payload_suffix(payload, ["label", "value"])
    end

    defp effect_summary(%Message{type: type, payload: payload})
         when type in ["effect.send", "effect.send_delayed"] do
      payload_suffix(payload, ["event", "target"])
    end

    defp effect_summary(%Message{type: type, payload: payload})
         when type in ["effect.invoke", "effect.cancel_invoke", "effect.autoforward"] do
      payload_suffix(payload, ["invoke_id"])
    end

    defp effect_summary(%Message{type: "effect.cancel", payload: payload}) do
      payload_suffix(payload, ["send_id"])
    end

    defp effect_summary(%Message{type: "session.halted", payload: payload}) do
      payload_suffix(payload, ["reason"])
    end

    defp effect_summary(%Message{type: "session.terminated", payload: payload}) do
      payload_suffix(payload, ["reason"])
    end

    defp effect_summary(%Message{type: "session.unroutable", payload: payload}) do
      payload_suffix(payload, ["event", "reason"])
    end

    defp effect_summary(%Message{}), do: ""

    @spec payload_suffix(map(), [String.t()]) :: String.t()
    defp payload_suffix(payload, keys) do
      keys
      |> Enum.filter(&Map.has_key?(payload, &1))
      |> Enum.map_join(", ", &"#{&1}: #{display(payload[&1])}")
      |> case do
        "" -> ""
        text -> " - " <> text
      end
    end

    @spec display(term()) :: String.t()
    defp display(value) when is_binary(value), do: value
    defp display(value) when is_number(value) or is_atom(value), do: to_string(value)
    defp display(value), do: inspect(value)
  end
else
  defmodule StatifierUI.Live do
    @moduledoc """
    Stub: the read-only ops components need the optional
    `:phoenix_live_view` dependency (ADR-0004).

    The read model behind them does not - `StatifierUI.Live.State` and
    `StatifierUI.Inspector` are pure and always compiled, so a host without
    LiveView can still fold a trace stream and render it its own way.
    """

    @missing "needs the optional :phoenix_live_view dependency - add " <>
               "{:phoenix_live_view, \"~> 1.0\"} to your deps and recompile, or read the " <>
               "panes from StatifierUI.Live.State directly"

    @doc "Raises: the composed ops view needs `:phoenix_live_view`."
    @spec ops_view(map()) :: no_return()
    def ops_view(_assigns), do: raise(RuntimeError, "StatifierUI.Live.ops_view/1 " <> @missing)

    @doc "Raises: the status pane needs `:phoenix_live_view`."
    @spec status(map()) :: no_return()
    def status(_assigns), do: raise(RuntimeError, "StatifierUI.Live.status/1 " <> @missing)

    @doc "Raises: the scrubber needs `:phoenix_live_view`."
    @spec scrubber(map()) :: no_return()
    def scrubber(_assigns), do: raise(RuntimeError, "StatifierUI.Live.scrubber/1 " <> @missing)

    @doc "Raises: the diagram pane needs `:phoenix_live_view`."
    @spec diagram(map()) :: no_return()
    def diagram(_assigns), do: raise(RuntimeError, "StatifierUI.Live.diagram/1 " <> @missing)

    @doc "Raises: the event-log pane needs `:phoenix_live_view`."
    @spec event_log(map()) :: no_return()
    def event_log(_assigns), do: raise(RuntimeError, "StatifierUI.Live.event_log/1 " <> @missing)
  end
end
