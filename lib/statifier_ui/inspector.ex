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

  ## The configuration as state ids (sui-hq0)

  `active_configuration_ids/2` answers the same configuration as
  `active_configuration/2`, resolved through the stream's own
  `session.start` manifest into the chart's ids, and `active_invokes/2`
  does the same for the invocations live at that point. Both are pure
  reads a host can call from a `render/1` to drive a diagram of its own
  without parsing the manifest itself; both refuse with
  `{:error, :no_manifest}` on a stream that carries none.

  ## Stepping a persisted trace (sui-2uz)

  `datamodel/2` takes the same `:selection` every other fold here does, so
  the datamodel pane can show the values as they stood at a selected
  macrostep rather than only at the live tip, and `datamodel_diff/2`
  renders what one macrostep changed. Both are the same stream cut short
  and folded again by `StatifierUI.DatamodelExplorer.build_live/2`; the
  comparison itself is `StatifierUI.DatamodelExplorer.Diff`. Nothing
  re-runs the chart and nothing re-implements an assignment - a persisted
  stream is a recording, and stepping it is a read of a shorter prefix.

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
  alias StatifierUI.DatamodelExplorer.Diff
  alias StatifierUI.Diagram
  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.DeepLink
  alias StatifierUI.EventLog.Labels
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
          | {:active_style, StatifierUI.Diagram.active_style()}

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
  The configuration `active_configuration/2` answers, as state IDs.

  The indexes that function returns are the wire format's own document-order
  positions, which mean nothing outside the stream that produced them. A host
  that draws its own diagram - the debugger canvas in a block editor, say -
  works in the chart's ids, so this resolves them through the stream's own
  `session.start` manifest and hands back the names.

  The resolution rule is `StatifierUI.EventLog.Labels.state/2`, the one the
  event log already renders indexes with: a state's `"id"`, `"<scxml>"` for
  the synthesized root, and `"#<index>"` for a state the document left
  anonymous. There is no second answer to what an index is called.

  A stream carrying no `session.start` returns `{:error, :no_manifest}`
  rather than a list of `"#<index>"` strings. That is the late-attach case
  (`StatifierUI.Trace.Subscriber` emits no manifest when it joins a session
  that already has one), and a caller marking a canvas needs to know it got
  no names rather than to mark nothing and call it an empty configuration.
  `active_configuration/2` still answers the indexes there.

  Nothing here re-derives a configuration or parses the manifest itself:
  both halves are reads of what the engine already stamped.

  ## Examples

      iex> {:ok, machine} =
      ...>   Statifier.compile(~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending"><state id="pending"/><state id="authorized"/></scxml>))
      iex> {:ok, manifest} = StatifierUI.Trace.Manifest.build(machine, "sess_ops")
      iex> StatifierUI.Inspector.active_configuration_ids([manifest], initial_configuration: [1])
      {:ok, ["pending"]}

      iex> StatifierUI.Inspector.active_configuration_ids([], initial_configuration: [1])
      {:error, :no_manifest}
  """
  @spec active_configuration_ids([Message.t()], [opt()]) ::
          {:ok, [String.t()]} | {:error, :no_manifest}
  def active_configuration_ids(messages, opts \\ []) do
    with {:ok, labels} <- manifest_labels(messages) do
      {:ok, Enum.map(active_configuration(messages, opts), &Labels.state(labels, &1))}
    end
  end

  @doc """
  The invocations live at the point `opts[:selection]` names, as
  `{state_id, invoke_type | nil}` - the invoke half of
  `active_configuration_ids/2`.

  An invocation is live from the `effect.invoke` that started it until the
  `effect.cancel_invoke` that ends it, both of which the engine stamps with
  the owning `state_index` (`docs/wire-format.md`). Nothing else is inferred:
  a stream that never reached the `<invoke>` seam answers `{:ok, []}`, and
  the pairing is by `invoke_id`, the format's own identity for an
  invocation. The list is in start order.

  ## What the second element is, and is not

  The wire format defines **no outcome field for an invocation** - its only
  `outcome` is `trace.conds_evaluated`'s guard discriminator - so this pair's
  second element is the `invoke_type` an `effect.invoke` carries, `nil` when
  the `<invoke>` element set neither `type` nor `typeexpr`. A caller wanting
  to know how an invocation *ended* reads the `done.invoke.*` event in the
  event log; answering that here would mean this module deciding what
  "finished" means, which is the engine's call and not a read (ADR-0002's
  inherited clause).

  `{:error, :no_manifest}` for the same reason and in the same case as
  `active_configuration_ids/2`.

  ## Examples

      iex> {:ok, machine} =
      ...>   Statifier.compile(~s(<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending"><state id="pending"/></scxml>))
      iex> {:ok, manifest} = StatifierUI.Trace.Manifest.build(machine, "sess_ops")
      iex> StatifierUI.Inspector.active_invokes([manifest])
      {:ok, []}
  """
  @spec active_invokes([Message.t()], [opt()]) ::
          {:ok, [{String.t(), String.t() | nil}]} | {:error, :no_manifest}
  def active_invokes(messages, opts \\ []) do
    with {:ok, labels} <- manifest_labels(messages) do
      invocations =
        messages
        |> in_view(opts)
        |> live_invocations()
        |> Enum.map(fn {state_index, invoke_type} ->
          {Labels.state(labels, state_index), invoke_type}
        end)

      {:ok, invocations}
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
  `StatifierUI.Diagram.render/3` over `active_configuration/2`.

  `opts[:active_style]` is passed through unchanged, so a host under a dark
  theme can drop the shipped `classDef` and style the `active` class from
  its own stylesheet - see `StatifierUI.Diagram`.
  """
  @spec diagram(Machine.t(), [Message.t()], [opt()]) :: String.t()
  def diagram(machine, messages, opts \\ []) do
    Diagram.render(machine, active_configuration(messages, opts),
      active_style: Keyword.get(opts, :active_style, :default)
    )
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

  # -- Manifest-resolved reads (sui-hq0) -----------------------------------

  # One `session.start` is all a stream ever carries, and `EventLog.Labels`
  # already knows how to read its tables; the only thing added here is the
  # refusal, which `Labels.from_log/1` deliberately does not have (it
  # degrades to bare indexes for the event log's own rendering).
  @spec manifest_labels([Message.t()]) :: {:ok, Labels.t()} | {:error, :no_manifest}
  defp manifest_labels(messages) do
    case Enum.find(messages, &(&1.type == "session.start")) do
      nil -> {:error, :no_manifest}
      manifest -> {:ok, Labels.from_manifest(manifest)}
    end
  end

  # A selection cuts the stream at the end of macrostep `n`, exactly as the
  # configuration reads do. A message with no `macrostep` stamp - the
  # manifest, `session.datamodel` - is session-level and stays in view.
  @spec in_view([Message.t()], [opt()]) :: [Message.t()]
  defp in_view(messages, opts) do
    case Keyword.get(opts, :selection, :live) do
      {:macrostep, n} -> Enum.filter(messages, &(is_nil(&1.macrostep) or &1.macrostep <= n))
      _live -> messages
    end
  end

  # Start order preserved, so a caller rendering two spinners renders them in
  # the order the engine started them. `effect.invoke` and
  # `effect.cancel_invoke` are the only two messages that open and close an
  # invocation's life.
  @spec live_invocations([Message.t()]) :: [{non_neg_integer(), String.t() | nil}]
  defp live_invocations(messages) do
    messages
    |> Enum.reduce([], fn
      %Message{type: "effect.invoke", payload: payload}, live ->
        live ++
          [{payload["invoke_id"], {payload["state_index"], payload["invoke_type"]}}]

      %Message{type: "effect.cancel_invoke", payload: payload}, live ->
        List.keydelete(live, payload["invoke_id"], 0)

      _other, live ->
        live
    end)
    |> Enum.map(fn {_invoke_id, invocation} -> invocation end)
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

  Under `opts[:selection]` of `{:macrostep, n}` the pane folds the stream
  as it stood at the end of macrostep `n` rather than at the live tip
  (`sui-2uz`) - the same cut every other selection-aware read here takes,
  so the datamodel a caller shows beside a selected configuration is the
  one that configuration was reached with. On `:live` (the default) the
  whole list folds, byte-identical to what `datamodel/1` always rendered.

  Nothing is re-derived: the cut is a shorter prefix of the same messages,
  folded by the same `build_live/2`.
  """
  @spec datamodel([Message.t()], [opt()]) :: String.t()
  def datamodel(messages, opts \\ []) do
    case DatamodelExplorer.build_live(in_view(messages, opts)) do
      {:ok, pane} -> DatamodelExplorer.Markdown.render(pane)
      {:error, reason} -> "**Datamodel explorer unavailable:** `#{inspect(reason)}`"
    end
  end

  @doc """
  Markdown for the datamodel diff pane: what macrostep `n` changed in the
  datamodel, as a table (`sui-2uz`).

  The two sides are the same stream cut twice - everything below macrostep
  `n`, and everything through it - folded by
  `StatifierUI.DatamodelExplorer.build_live/2` and compared by
  `StatifierUI.DatamodelExplorer.Diff.between/2`. "Adjacent" is therefore
  the cut, not a pair of buckets: a macrostep the log holds no entry for
  still diffs correctly against whatever precedes it, and macrostep `n`'s
  own diff against the session's seeded datamodel is what the first
  macrostep shows.

  `opts[:selection]` picks `n`. On `:live` the newest macrostep in view is
  diffed, so a pane following the tip answers "what did the step that just
  happened change". A stream with no macrostep at all has nothing to diff
  and says so.

  Options are `t:opt/0`'s, plus `StatifierUI.DatamodelExplorer.Diff.Markdown`'s
  `:title` and `:empty_note`, which are forwarded.
  """
  @spec datamodel_diff([Message.t()], [opt()]) :: String.t()
  def datamodel_diff(messages, opts \\ []) do
    case diff_macrostep(messages, opts) do
      nil ->
        "_No macrostep in view, so there is nothing to diff._"

      n ->
        render_opts =
          opts
          |> Keyword.take([:title, :empty_note])
          |> Keyword.put_new(:title, "#### Datamodel changes in macrostep #{n}")

        diff_table(messages, n, render_opts)
    end
  end

  # Both panes have to build for the comparison to mean anything; one that
  # refuses (a message list naming more than one session) reports the
  # refusal rather than rendering a diff against an empty pane, which would
  # read as "everything was added".
  @spec diff_table([Message.t()], non_neg_integer(), keyword()) :: String.t()
  defp diff_table(messages, n, render_opts) do
    earlier = DatamodelExplorer.build_live(cut_below(messages, n))
    later = DatamodelExplorer.build_live(in_view(messages, selection: {:macrostep, n}))

    case {earlier, later} do
      {{:ok, earlier_pane}, {:ok, later_pane}} ->
        earlier_pane
        |> Diff.between(later_pane)
        |> Diff.Markdown.render(render_opts)

      {{:error, reason}, _later} ->
        "**Datamodel diff unavailable:** `#{inspect(reason)}`"

      {_earlier, {:error, reason}} ->
        "**Datamodel diff unavailable:** `#{inspect(reason)}`"
    end
  end

  # The macrostep the diff is about: the selected one, or - following the
  # tip - the newest one that exists. `points/1` rather than the raw stamps,
  # so "newest" means the same thing here as it does to the scrubber.
  @spec diff_macrostep([Message.t()], [opt()]) :: non_neg_integer() | nil
  defp diff_macrostep(messages, opts) do
    case Keyword.get(opts, :selection, :live) do
      {:macrostep, n} ->
        n

      _live ->
        case points(messages) do
          [] -> nil
          points -> List.last(points).macrostep
        end
    end
  end

  # The other half of `in_view/2`'s cut: strictly below macrostep `n`.
  # Session-level messages (the manifest, `session.datamodel`) carry no
  # macrostep stamp and stay on both sides - the seeded datamodel is not
  # something macrostep 1 added.
  @spec cut_below([Message.t()], non_neg_integer()) :: [Message.t()]
  defp cut_below(messages, n) do
    Enum.filter(messages, &(is_nil(&1.macrostep) or &1.macrostep < n))
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

  @doc """
  The status header for a stream read back from storage rather than
  watched live.

  A persisted stream has no `StatifierUI.Trace.Subscriber` behind it, so
  there is no status, no buffered or dropped count, and no diagnostics -
  and this says `persisted` rather than inventing them.
  `StatifierUI.Live`'s status pane takes the same position for the same
  reason (`status_kind(nil)`), so both surfaces describe a reloaded trace
  the same way.

  What a persisted stream *can* still say is whether it is projected: the
  `projection` header rides on its own `session.start` message (ADR-0012),
  so a reloaded capture that withholds values still announces that it
  does.
  """
  @spec persisted_status([Message.t()]) :: String.t()
  def persisted_status(messages) do
    session =
      Enum.find_value(messages, "(no session.start)", fn
        %Message{type: "session.start", session: session} -> session
        _other -> nil
      end)

    header =
      "**Session** `#{session}` - persisted - #{length(messages)} messages " <>
        "(read from storage; a persisted stream has no subscriber counts)"

    Enum.join([header | persisted_projection_note(messages)], "\n\n")
  end

  # The header rides on the stream's own `session.start` rather than on
  # subscriber stats, so it is read from the messages and handed to the
  # same note renderer the live status uses - one wording for both
  # surfaces rather than two that can drift apart.
  @spec persisted_projection_note([Message.t()]) :: [String.t()]
  defp persisted_projection_note(messages) do
    messages
    |> Enum.find_value(fn
      %Message{type: "session.start", payload: %{"projection" => %{"profile" => profile}}} ->
        profile

      _other ->
        nil
    end)
    |> case do
      nil -> []
      profile -> [profile_note(profile)]
    end
  end

  # The profile name is surfaced wherever the mode is, so a user asking "why
  # can't I see this" has something to quote (ADR-0012). A stream with no
  # projection says nothing extra, which keeps the unprojected status line
  # byte-identical to what it was.
  @spec projection_note(Subscriber.stats()) :: [String.t()]
  defp projection_note(%{projection: %{profile: profile}}), do: [profile_note(profile)]
  defp projection_note(_stats), do: []

  @spec profile_note(String.t()) :: String.t()
  defp profile_note(profile) do
    "> **Projected:** datamodel and payload values are withheld from this " <>
      "stream under profile `#{profile}`. Redacted slots render as " <>
      "`(redacted)`, which is not the same as unbound."
  end

  @spec label(atom()) :: String.t()
  defp label(:not_recorded), do: "Live-only"
  defp label(:catch_up_failed), do: "Live-only"
  defp label(:late_attach), do: "Late attach"
  defp label(kind), do: kind |> Atom.to_string() |> String.capitalize()
end
