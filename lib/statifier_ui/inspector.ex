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

  The active configuration is read from the newest
  `trace.macrostep_stable` message - the quiescent configuration of the
  last completed macrostep (`docs/wire-format.md`). Before any macrostep
  has completed in view, the caller-supplied initial configuration
  (typically `Statifier.Session.snapshot/1`'s) is used instead.
  """

  alias Statifier.Machine
  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.Diagram
  alias StatifierUI.EventLog
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  @typedoc "Options shared by the fold functions."
  @type opt :: {:initial_configuration, Enumerable.t()}

  @doc """
  The active configuration `messages` implies: the newest
  `trace.macrostep_stable`'s `configuration` payload, or
  `opts[:initial_configuration]` (default `[]`) when no macrostep has
  stabilized in view.
  """
  @spec active_configuration([Message.t()], [opt()]) :: [non_neg_integer()]
  def active_configuration(messages, opts \\ []) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{type: "trace.macrostep_stable", payload: %{"configuration" => configuration}} ->
        configuration

      _other ->
        nil
    end)
    |> case do
      nil -> Enum.to_list(Keyword.get(opts, :initial_configuration, []))
      configuration -> configuration
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
  collapsible with the last macrostep open. A build failure renders as a
  visible error line rather than raising - the inspector keeps showing
  the other panes.
  """
  @spec event_log([Message.t()]) :: String.t()
  def event_log(messages) do
    case EventLog.build(messages) do
      {:ok, log} -> EventLog.Markdown.render(log)
      {:error, reason} -> "**Event log unavailable:** `#{inspect(reason)}`"
    end
  end

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
