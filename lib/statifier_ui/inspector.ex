defmodule StatifierUI.Inspector do
  @moduledoc """
  Pure pane assembly for the Livebook inspector: folds a compiled
  `Statifier.Machine` and a `StatifierUI.Trace.Subscriber` message list
  into the render source each pane displays - Mermaid source for the
  configuration diagram, Markdown for the event log and the datamodel
  explorer, and a status line from the subscriber's `stats/1` snapshot.

  No Kino, no process, no session: everything here is testable from a
  message list, exactly like the pane modules it composes. The Kino shell
  (`StatifierUI.Kino`) maps these strings into widgets and owns nothing
  else.

  The active configuration is read from the newest message that stamped
  one - a `trace.macrostep_stable`, the quiescent configuration of the
  last completed macrostep, or a `trace.done`, the configuration a halted
  run exited in (`docs/wire-format.md`). Before either has arrived in
  view, the caller-supplied initial configuration (typically
  `Statifier.Session.snapshot/1`'s) is used instead.

  ## A halted chart's final configuration (sui-dc7)

  A run that ends by entering a top-level `<final>` never stabilizes in
  its last macrostep: quiescence is never reached, so no
  `trace.macrostep_stable` is emitted for it and the engine stamps the
  configuration on `trace.done` instead. Reading only
  `macrostep_stable` therefore left the diagram highlighting the state the
  chart *left*, while the datamodel pane showed the assignment that moved
  it out.

  Both stamps are read, and the wire format is what settles that they may
  be: its `trace.done` row defines `configuration` as "the full
  configuration as it stood at exit, a genuine set, sorted ascending" -
  the same field, shape, and authority as a `macrostep_stable` payload.
  Nothing here re-derives an exit configuration from the exit sets that
  precede `trace.done`; that would be re-implementing Appendix D, which
  this repo does not do (ADR-0002, `StatifierUI.EventLog`). The two
  readings stay labelled apart, so a configuration the chart *exited* in
  is never presented as one it *settled* in.

  ## Selecting a past macrostep (sui-3gg)

  Every fold function takes a `:selection`, which is `:live` (the default,
  the behaviour above) or `{:macrostep, n}`. Under a selection the diagram
  shows the configuration macrostep `n` settled in, the event log marks
  that macrostep's entry `- shown in the diagram` and opens it, and
  `selection_note/2` renders the line that says which point is on screen.
  That is the whole of the link between the two panes.

  Nothing here re-derives a configuration. Every configuration this module
  can show was stamped by the engine on a `trace.macrostep_stable` or a
  `trace.done`, and a
  stream reconstructed by catch-up got there through statifier ADR-0034
  replay, which re-drives the core in a pure fold rather than rewinding a
  live session. Time travel is a read of replay output as data (ADR-0002's
  inherited clause), so selecting a macrostep neither touches the session
  nor asks the engine for anything new.

  A selected macrostep that stamped no configuration of its own - in
  flight, or its stamp dropped - has none to draw. Rather than draw
  nothing, the newest configuration at or below it is shown and
  `selection_note/2` says which macrostep it was carried from - a carried
  configuration is never presented as a measured one.

  ## Linking out to a trace (sui-4w2)

  Every fold function also takes `:deep_link`, the host's APM URL template
  (ADR-0013). With one configured, the event log's macrostep summaries and
  `selection_note/2` gain an `[open trace](...)` link for each macrostep
  whose messages carry the wire format's `otel` key. Without the option, or
  on a macrostep carrying no correlation, every pane renders exactly as it
  did - including the carried-forward wording above, which the link is
  appended to rather than replacing.
  """

  alias Statifier.Machine
  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.Diagram
  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.DeepLink
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  @typedoc """
  Which point in the run the panes show: the live tip, or one macrostep.
  """
  @type selection :: :live | {:macrostep, non_neg_integer()}

  @typedoc """
  One selectable point, for a caller building a scrubber.

  `quiescent?` says the macrostep settled, `final?` that it halted the run
  (sui-dc7). They are never both true, and a macrostep with a
  configuration to draw is one where either is - which is why `final?` was
  added beside `quiescent?` rather than widening it: a halting macrostep
  is not quiescent, and a scrubber saying so is not the same as one saying
  it has nothing to show.
  """
  @type point :: %{
          macrostep: non_neg_integer(),
          event: String.t() | nil,
          quiescent?: boolean(),
          final?: boolean()
        }

  @typedoc "Options shared by the fold functions."
  @type opt ::
          {:initial_configuration, Enumerable.t()}
          | {:selection, selection()}
          | {:deep_link, String.t() | StatifierUI.Trace.DeepLink.t() | nil}

  @doc """
  The configuration `messages` and `opts[:selection]` imply.

  On `:live` (the default): the `configuration` payload of the newest
  `trace.macrostep_stable` or `trace.done`, whichever arrived last, or
  `opts[:initial_configuration]` (default `[]`) when neither is in view.

  On `{:macrostep, n}`: the configuration macrostep `n` settled in - or,
  for the macrostep that halted the run, exited in - per
  `StatifierUI.EventLog.configuration_at/2`, falling back to the newest
  one below it when `n` stamped neither, and to
  `opts[:initial_configuration]` when nothing at or below `n` stamped one.
  A message list the log refuses (mixed sessions) degrades to the live
  reading rather than raising, same policy as `event_log/2`.
  """
  @spec active_configuration([Message.t()], [opt()]) :: [non_neg_integer()]
  def active_configuration(messages, opts \\ []) do
    case Keyword.get(opts, :selection, :live) do
      {:macrostep, n} -> selected_configuration(messages, n, opts)
      _live -> live_configuration(messages, opts)
    end
  end

  @doc """
  How the selection resolved, for a caller that needs to say so: `:live`,
  `{:quiescent, n}`, `{:final, n}` (macrostep `n` halted the run, so the
  configuration it exited in is shown), `{:carried, n, from}` (macrostep
  `n` stamped no configuration, so macrostep `from`'s is shown), or
  `{:before_first, n}` (nothing at or below `n` stamped a configuration,
  so the initial configuration is shown).
  """
  @spec resolution([Message.t()], [opt()]) ::
          :live
          | {:quiescent, non_neg_integer()}
          | {:final, non_neg_integer()}
          | {:carried, non_neg_integer(), non_neg_integer()}
          | {:before_first, non_neg_integer()}
  def resolution(messages, opts \\ []) do
    case Keyword.get(opts, :selection, :live) do
      {:macrostep, n} -> resolve_macrostep(messages, n)
      _live -> :live
    end
  end

  @doc """
  The macrosteps a caller can select, oldest first - the scrubber's own
  vocabulary, so a UI never has to fold the log itself. A log that refuses
  to build yields `[]`.
  """
  @spec points([Message.t()]) :: [point()]
  def points(messages) do
    case EventLog.build(messages) do
      {:ok, log} -> Enum.map(log.macrosteps, &point/1)
      {:error, _reason} -> []
    end
  end

  @doc """
  Moves a selection one scrubber step over `points`, purely - the widget
  layer holds the selection, this decides where a move lands.

    * `:live` returns `:live` from anywhere.
    * `:first` selects the oldest macrostep in view.
    * `:prev` from `:live` *pins* the newest macrostep (the same picture,
      no longer following the tip); from a macrostep it selects the
      newest one below it, staying put at the oldest.
    * `:next` selects the oldest macrostep above the current one, and
      returns to `:live` once there is none - so a run driven forward
      while the scrubber sits at the tip keeps following it.

  With no points at all every move returns `:live`: there is nothing else
  to show.
  """
  @spec step(selection(), [point()], :live | :first | :prev | :next) :: selection()
  def step(selection, points, move)
  def step(_selection, _points, :live), do: :live
  def step(_selection, [], _move), do: :live
  def step(_selection, [%{macrostep: first} | _rest], :first), do: {:macrostep, first}

  def step(:live, points, :prev), do: {:macrostep, List.last(points).macrostep}
  def step(:live, _points, :next), do: :live

  def step({:macrostep, n}, points, :prev) do
    points
    |> Enum.filter(&(&1.macrostep < n))
    |> List.last()
    |> case do
      nil -> {:macrostep, n}
      %{macrostep: previous} -> {:macrostep, previous}
    end
  end

  def step({:macrostep, n}, points, :next) do
    case Enum.find(points, &(&1.macrostep > n)) do
      nil -> :live
      %{macrostep: next} -> {:macrostep, next}
    end
  end

  @doc """
  The one-line note naming the point on screen, for display above the
  diagram: which macrostep and its event, whether the configuration was
  measured there or carried from an earlier macrostep, and - on `:live` -
  that the diagram is following the tip.
  """
  @spec selection_note([Message.t()], [opt()]) :: String.t()
  def selection_note(messages, opts \\ []) do
    case Keyword.get(opts, :selection, :live) do
      {:macrostep, n} -> selected_note(messages, n, DeepLink.from_opts(opts))
      _live -> "**Showing** the live tip."
    end
  end

  @doc """
  Mermaid `stateDiagram-v2` source for the configuration pane:
  `StatifierUI.Diagram.render/2` over `active_configuration/2`.
  """
  @spec diagram(Machine.t(), [Message.t()], [opt()]) :: String.t()
  def diagram(machine, messages, opts \\ []) do
    Diagram.render(machine, active_configuration(messages, opts))
  end

  @doc """
  Markdown for the event log pane: `StatifierUI.EventLog.build/1` rendered
  collapsible. The selected macrostep is opened and marked `- shown in the
  diagram`; with no selection the last macrostep is opened, as before. A
  build failure renders as a visible error line rather than raising - the
  inspector keeps showing the other panes.
  """
  @spec event_log([Message.t()], [opt()]) :: String.t()
  def event_log(messages, opts \\ []) do
    case EventLog.build(messages) do
      {:ok, log} -> EventLog.Markdown.render(log, markdown_opts(opts))
      {:error, reason} -> "**Event log unavailable:** `#{inspect(reason)}`"
    end
  end

  # -- Selection plumbing --------------------------------------------------

  @spec markdown_opts([opt()]) :: [EventLog.Markdown.opt()]
  defp markdown_opts(opts) do
    selection =
      case Keyword.get(opts, :selection, :live) do
        {:macrostep, n} -> [open: [n], selected: n]
        _live -> []
      end

    case DeepLink.from_opts(opts) do
      nil -> selection
      template -> [{:deep_link, template} | selection]
    end
  end

  # Newest-first over both stamping types, so a `trace.done` arriving after
  # the last `trace.macrostep_stable` wins on order rather than on type -
  # there is no precedence rule to get wrong. `effect.done` carries the same
  # configuration at the same moment (`docs/wire-format.md`, the
  # `trace.done`/`effect.done` note) and is deliberately not read here: one
  # source per fact.
  @stamps_configuration ["trace.macrostep_stable", "trace.done"]

  @spec live_configuration([Message.t()], [opt()]) :: [non_neg_integer()]
  defp live_configuration(messages, opts) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{type: type, payload: %{"configuration" => configuration}}
      when type in @stamps_configuration ->
        configuration

      _other ->
        nil
    end)
    |> case do
      nil -> initial_configuration(opts)
      configuration -> configuration
    end
  end

  @spec selected_configuration([Message.t()], non_neg_integer(), [opt()]) :: [
          non_neg_integer()
        ]
  defp selected_configuration(messages, n, opts) do
    case EventLog.build(messages) do
      {:ok, log} ->
        case EventLog.configuration_at(log, n) do
          {:quiescent, configuration} -> configuration
          {:final, configuration} -> configuration
          {:carried, _from, configuration} -> configuration
          :before_first -> initial_configuration(opts)
        end

      {:error, _reason} ->
        live_configuration(messages, opts)
    end
  end

  @spec resolve_macrostep([Message.t()], non_neg_integer()) ::
          :live
          | {:quiescent, non_neg_integer()}
          | {:final, non_neg_integer()}
          | {:carried, non_neg_integer(), non_neg_integer()}
          | {:before_first, non_neg_integer()}
  defp resolve_macrostep(messages, n) do
    case EventLog.build(messages) do
      {:ok, log} ->
        case EventLog.configuration_at(log, n) do
          {:quiescent, _configuration} -> {:quiescent, n}
          {:final, _configuration} -> {:final, n}
          {:carried, from, _configuration} -> {:carried, n, from}
          :before_first -> {:before_first, n}
        end

      {:error, _reason} ->
        :live
    end
  end

  @spec initial_configuration([opt()]) :: [non_neg_integer()]
  defp initial_configuration(opts) do
    opts
    |> Keyword.get(:initial_configuration, [])
    |> Enum.to_list()
  end

  @spec point(EventLog.Macrostep.t()) :: point()
  defp point(macrostep) do
    %{
      macrostep: macrostep.macrostep,
      event: event_name(macrostep.event),
      quiescent?: macrostep.configuration != nil,
      final?: macrostep.final_configuration != nil
    }
  end

  # One fold, four readings: the note names the macrostep, its event, and
  # how the drawn configuration was arrived at. The trace link, when the host
  # configured a template and the macrostep carries `otel`, is appended to
  # all four without changing any of them.
  @spec selected_note([Message.t()], non_neg_integer(), StatifierUI.Trace.DeepLink.t() | nil) ::
          String.t()
  defp selected_note(messages, n, deep_link) do
    case EventLog.build(messages) do
      {:ok, log} ->
        suffix = event_suffix(log, n)

        note =
          case EventLog.configuration_at(log, n) do
            {:quiescent, _configuration} ->
              "**Showing** macrostep #{n}#{suffix}, at its quiescent configuration."

            {:final, _configuration} ->
              "**Showing** macrostep #{n}#{suffix}, at the final configuration the " <>
                "run halted in."

            {:carried, from, _configuration} ->
              "**Showing** macrostep #{n}#{suffix}, which is not quiescent; the " <>
                "configuration drawn is macrostep #{from}'s, carried forward."

            :before_first ->
              "**Showing** macrostep #{n}#{suffix}; no configuration was stamped at or " <>
                "below it, so the session's initial configuration is drawn."
          end

        note <> trace_suffix(log, n, deep_link)

      {:error, reason} ->
        "**Showing** the live tip - selection unavailable: `#{inspect(reason)}`"
    end
  end

  # `nil` for no template, no `otel` key, or ids that are not W3C Trace
  # Context hex - in every one of those the note is byte-identical to what it
  # was before sui-4w2.
  @spec trace_suffix(EventLog.t(), non_neg_integer(), StatifierUI.Trace.DeepLink.t() | nil) ::
          String.t()
  defp trace_suffix(log, n, deep_link) do
    with %EventLog.Macrostep{} = macrostep <- Enum.find(log.macrosteps, &(&1.macrostep == n)),
         link when is_binary(link) <- DeepLink.markdown(macrostep, deep_link, label: "open trace") do
      " #{link}"
    else
      _absent -> ""
    end
  end

  @spec event_suffix(EventLog.t(), non_neg_integer()) :: String.t()
  defp event_suffix(log, n) do
    case Enum.find(log.macrosteps, &(&1.macrostep == n)) do
      nil -> ""
      macrostep -> event_suffix_for(event_name(macrostep.event))
    end
  end

  @spec event_suffix_for(String.t() | nil) :: String.t()
  defp event_suffix_for(nil), do: " (initialize)"
  defp event_suffix_for(name), do: " (`#{name}`)"

  @spec event_name(map() | nil) :: String.t() | nil
  defp event_name(nil), do: nil
  defp event_name(%{"name" => name}), do: name
  defp event_name(_other), do: nil

  @doc """
  Markdown for the datamodel explorer pane:
  `StatifierUI.DatamodelExplorer.build_live/1` over `messages`, rendered
  with the default markers. A build failure renders as a visible error
  line, same policy as `event_log/1`.
  """
  @spec datamodel([Message.t()]) :: String.t()
  def datamodel(messages) do
    case DatamodelExplorer.build_live(messages) do
      {:ok, pane} -> DatamodelExplorer.Markdown.render(pane)
      {:error, reason} -> "**Datamodel explorer unavailable:** `#{inspect(reason)}`"
    end
  end

  @doc """
  The one-line (plus warnings) status header: session id, subscriber
  status, message and drop counts, and one blockquote line per diagnostic.
  A `:not_recorded` or `:catch_up_failed` diagnostic is what labels the
  whole inspector live-only - a partial stream is never presented as
  whole (statifier ADR-0049; this bead's precondition note).
  """
  @spec status(Subscriber.stats()) :: String.t()
  def status(stats) do
    session = stats.session || "(awaiting first message)"

    header =
      "**Session** `#{session}` - #{stats.status} - " <>
        "#{stats.buffered} messages buffered (#{stats.dropped} dropped, #{stats.errors} errors)"

    warnings =
      Enum.map(stats.diagnostics, fn diagnostic ->
        "> **#{label(diagnostic.kind)}:** #{diagnostic.message}"
      end)

    Enum.join([header | projection_note(stats) ++ warnings], "\n\n")
  end

  # The profile name is surfaced wherever the mode is, so a user asking "why
  # can't I see this" has something to quote (ADR-0012). A stream with no
  # projection says nothing extra, which keeps the unprojected status line
  # byte-identical to what it was.
  @spec projection_note(Subscriber.stats()) :: [String.t()]
  defp projection_note(%{projection: %{profile: profile}}) do
    [
      "> **Projected:** datamodel and payload values are withheld from this " <>
        "stream under profile `#{profile}`. Redacted slots render as " <>
        "`(redacted)`, which is not the same as unbound."
    ]
  end

  defp projection_note(_stats), do: []

  @spec label(atom()) :: String.t()
  defp label(:not_recorded), do: "Live-only"
  defp label(:catch_up_failed), do: "Live-only"
  defp label(:late_attach), do: "Late attach"
  defp label(kind), do: kind |> Atom.to_string() |> String.capitalize()
end
