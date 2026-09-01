defmodule StatifierUI.EventLog.Markdown do
  @moduledoc """
  Renders a `StatifierUI.EventLog.t()` as Markdown a host hands to
  `Kino.Markdown.new/1`, per the sui-t36.5 plan's Phase 3.

  `render/2` is a pure function over the log and the `StatifierUI.EventLog.Labels.t()`
  that resolves its indexes - it names `Kino` only in this moduledoc and
  calls nothing under `Kino.*`. `sui-t36.8` owns wrapping the returned string
  in an actual `Kino.Markdown` widget.

  ## Structure

  A header line naming the session (and a drop warning when the log's
  `truncated?` is `true`), then one block per macrostep - a collapsible
  `<details>`/`<summary>` by default, or a plain `### Macrostep <n>` heading
  with `collapsible: false` - each holding a Markdown table with one row per
  round, that round's notes (a raised-cause line, its executed content, a
  budget-exhausted line), and the macrostep's round-less `effect.*` messages
  listed last under their own heading. A footer names `session.halted`/
  `session.terminated`/`session.unroutable` when the log carries one.

  `exited` and `entered` render through `Labels.states/2` **in list order**
  (ADR-0011): this module never re-sorts either list.
  """

  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.Labels
  alias StatifierUI.EventLog.Macrostep
  alias StatifierUI.EventLog.Round
  alias StatifierUI.Trace.Message

  @type open_selector :: :last | :all | :none | [non_neg_integer()]
  @type opt ::
          {:labels, Labels.t()}
          | {:collapsible, boolean()}
          | {:open, open_selector()}
          | {:selected, non_neg_integer() | nil}

  @doc """
  Renders `log` as a Markdown string.

  Options:

    * `:labels` - a `Labels.t()` to resolve indexes with. Defaults to
      `Labels.from_log(log)`.
    * `:collapsible` - wraps each macrostep in `<details>`/`<summary>` when
      `true` (the default), or renders a plain `### Macrostep <n>` heading
      with no HTML when `false`.
    * `:open` - which macrosteps start open when `:collapsible` is `true`:
      `:last` (the default, opens the highest-numbered macrostep), `:all`,
      `:none`, or a list of macrostep numbers.
    * `:selected` - the macrostep number the diagram beside this log is
      currently showing (sui-3gg), or `nil` (the default) when the diagram
      is on the live tip. The selected macrostep's summary is suffixed
      `- shown in the diagram`, which is the whole of the link between the
      two panes: the log says which entry the picture belongs to. It is
      only a marker - use `:open` to open that entry as well.
  """
  @spec render(EventLog.t(), [opt()]) :: String.t()
  def render(%EventLog{} = log, opts \\ []) do
    labels = Keyword.get(opts, :labels, Labels.from_log(log))
    collapsible? = Keyword.get(opts, :collapsible, true)
    open = Keyword.get(opts, :open, :last)
    selected = Keyword.get(opts, :selected)

    ([header(log)] ++
       macrostep_blocks(log.macrosteps, labels, collapsible?, open, selected) ++
       footer_blocks(log))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  # -- Header and footer ---------------------------------------------------

  @spec header(EventLog.t()) :: String.t()
  defp header(%EventLog{session: session} = log) do
    lines = ["# Event log: #{session || "(no session)"}"]

    if log.truncated? do
      Enum.join(lines ++ [truncation_line(log)], "\n")
    else
      Enum.join(lines, "\n")
    end
  end

  @spec truncation_line(EventLog.t()) :: String.t()
  defp truncation_line(log) do
    "Earliest messages dropped; log starts at seq #{earliest_seq(log)}."
  end

  @spec earliest_seq(EventLog.t()) :: non_neg_integer()
  defp earliest_seq(log) do
    log
    |> all_messages()
    |> Enum.map(& &1.seq)
    |> Enum.min(fn -> 0 end)
  end

  @spec all_messages(EventLog.t()) :: [Message.t()]
  defp all_messages(%EventLog{session_messages: session_messages, macrosteps: macrosteps}) do
    session_messages ++
      Enum.flat_map(macrosteps, fn %Macrostep{effects: effects, rounds: rounds} ->
        effects ++ Enum.flat_map(rounds, & &1.messages)
      end)
  end

  @spec footer_blocks(EventLog.t()) :: [String.t()]
  defp footer_blocks(%EventLog{session_messages: session_messages}) do
    session_messages
    |> Enum.filter(&(&1.type in ["session.halted", "session.terminated", "session.unroutable"]))
    |> Enum.map(&footer_line/1)
    |> case do
      [] -> []
      lines -> [Enum.join(lines, "\n")]
    end
  end

  @spec footer_line(Message.t()) :: String.t()
  defp footer_line(%Message{type: "session.halted", payload: %{"reason" => reason}}) do
    "Session halted: #{reason}"
  end

  # Projection replaces this reason with the sentinel object, which is the one
  # position where a field's JSON type changes (ADR-0012). Interpolating a map
  # raises Protocol.UndefinedError, so the sentinel is matched ahead of the
  # string clause rather than relying on String.Chars.
  defp footer_line(%Message{type: "session.terminated", payload: %{"reason" => reason}})
       when is_map(reason) do
    "Session terminated: #{redaction_label(reason)}"
  end

  defp footer_line(%Message{type: "session.terminated", payload: %{"reason" => reason}}) do
    "Session terminated: #{reason}"
  end

  defp footer_line(%Message{type: "session.unroutable", payload: %{"effect" => effect}}) do
    "Session unroutable: #{inspect(effect)}"
  end

  # -- Macrostep blocks -----------------------------------------------------

  @spec macrostep_blocks(
          [Macrostep.t()],
          Labels.t(),
          boolean(),
          open_selector(),
          non_neg_integer() | nil
        ) :: [String.t()]
  defp macrostep_blocks(macrosteps, labels, collapsible?, open, selected) do
    Enum.map(macrosteps, fn macrostep ->
      open? = macrostep_open?(macrosteps, open, macrostep)
      selected? = macrostep.macrostep == selected
      macrostep_block(macrostep, labels, collapsible?, open?, selected?)
    end)
  end

  @spec macrostep_open?([Macrostep.t()], open_selector(), Macrostep.t()) :: boolean()
  defp macrostep_open?(_macrosteps, :all, _macrostep), do: true
  defp macrostep_open?(_macrosteps, :none, _macrostep), do: false

  defp macrostep_open?(macrosteps, :last, macrostep) do
    case List.last(macrosteps) do
      %Macrostep{macrostep: number} -> number == macrostep.macrostep
      nil -> false
    end
  end

  defp macrostep_open?(_macrosteps, indexes, macrostep) when is_list(indexes) do
    macrostep.macrostep in indexes
  end

  @spec macrostep_block(Macrostep.t(), Labels.t(), boolean(), boolean(), boolean()) ::
          String.t()
  defp macrostep_block(%Macrostep{} = macrostep, labels, true, open?, selected?) do
    open_attr = if open?, do: " open", else: ""
    summary = summary_text(macrostep, labels, selected?)

    lines =
      ["<details#{open_attr}>", "<summary>#{summary}</summary>", ""] ++
        macrostep_body(macrostep, labels) ++
        ["</details>"]

    Enum.join(lines, "\n")
  end

  defp macrostep_block(%Macrostep{} = macrostep, labels, false, _open?, selected?) do
    summary = summary_text(macrostep, labels, selected?)

    lines =
      ["### Macrostep #{macrostep.macrostep}", "", summary, ""] ++
        macrostep_body(macrostep, labels)

    Enum.join(lines, "\n")
  end

  @spec macrostep_body(Macrostep.t(), Labels.t()) :: [String.t()]
  defp macrostep_body(%Macrostep{rounds: rounds, effects: effects}, labels) do
    round_table_lines(rounds, labels) ++
      round_note_lines(rounds, labels) ++ effects_lines(effects)
  end

  @spec summary_text(Macrostep.t(), Labels.t(), boolean()) :: String.t()
  defp summary_text(%Macrostep{} = macrostep, labels, selected?) do
    round_count = length(macrostep.rounds)

    "Macrostep #{macrostep.macrostep}: #{event_summary(macrostep.event)}, " <>
      "#{round_count} #{pluralize(round_count, "round")}, " <>
      quiescence_summary(macrostep.configuration, labels) <>
      selection_suffix(selected?)
  end

  @spec selection_suffix(boolean()) :: String.t()
  defp selection_suffix(true), do: " - shown in the diagram"
  defp selection_suffix(false), do: ""

  @spec event_summary(map() | nil) :: String.t()
  defp event_summary(nil), do: "initialize"
  defp event_summary(%{"name" => name}), do: name

  @spec quiescence_summary([non_neg_integer()] | nil, Labels.t()) :: String.t()
  defp quiescence_summary(nil, _labels), do: "not yet quiescent"

  defp quiescence_summary(configuration, labels) do
    "quiescent at #{Labels.states(labels, configuration)}"
  end

  @spec pluralize(non_neg_integer(), String.t()) :: String.t()
  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # -- The round table ------------------------------------------------------

  @spec round_table_lines([Round.t()], Labels.t()) :: [String.t()]
  defp round_table_lines(rounds, labels) do
    header = [
      "| round | event | selected | exited | entered |",
      "| --- | --- | --- | --- | --- |"
    ]

    header ++ Enum.map(rounds, &round_row(&1, labels))
  end

  @spec round_row(Round.t(), Labels.t()) :: String.t()
  defp round_row(%Round{} = round, labels) do
    "| #{round.round} | #{event_cell(round)} | #{selected_cell(round, labels)} | " <>
      "#{Labels.states(labels, round.exited)} | #{Labels.states(labels, round.entered)} |"
  end

  @spec event_cell(Round.t()) :: String.t()
  defp event_cell(%Round{event: nil, eventless?: true}), do: "(eventless)"
  defp event_cell(%Round{event: nil, eventless?: false}), do: "-"
  defp event_cell(%Round{event: %{"name" => name}}), do: name

  @spec selected_cell(Round.t(), Labels.t()) :: String.t()
  defp selected_cell(%Round{t_indexes: nil}, _labels), do: "-"
  defp selected_cell(%Round{t_indexes: []}, _labels), do: "none"

  defp selected_cell(%Round{t_indexes: t_indexes}, labels) do
    Enum.map_join(t_indexes, ", ", &Labels.transition(labels, &1))
  end

  # -- Per-round notes: raised cause, executed content, budget exhaustion --

  @spec round_note_lines([Round.t()], Labels.t()) :: [String.t()]
  defp round_note_lines(rounds, labels) do
    Enum.flat_map(rounds, fn round ->
      cause_lines(round, labels) ++ content_lines(round, labels) ++ budget_lines(round)
    end)
  end

  @spec cause_lines(Round.t(), Labels.t()) :: [String.t()]
  defp cause_lines(%Round{cause: nil}, _labels), do: []

  defp cause_lines(%Round{cause: cause}, labels) do
    origin = Labels.origin(labels, cause["origin"])
    ["- raised by #{origin} at (macrostep #{cause["macrostep"]}, round #{cause["round"]})"]
  end

  @spec content_lines(Round.t(), Labels.t()) :: [String.t()]
  defp content_lines(%Round{content: []}, _labels), do: []

  defp content_lines(%Round{content: content}, labels) do
    Enum.map(content, &content_line(&1, labels))
  end

  @spec content_line(%{owner: map(), c_indexes: [non_neg_integer()]}, Labels.t()) :: String.t()
  defp content_line(%{owner: owner, c_indexes: c_indexes}, labels) do
    contents = Enum.map_join(c_indexes, ", ", &Labels.content(labels, &1))
    "- #{Labels.owner(labels, owner)}: #{contents}"
  end

  @spec budget_lines(Round.t()) :: [String.t()]
  defp budget_lines(%Round{budget_exhausted: nil}), do: []

  defp budget_lines(%Round{budget_exhausted: payload}) do
    pending = length(payload["pending_internal_events"])

    [
      "- budget exhausted after #{payload["budget"]} rounds; #{pending} internal events still pending"
    ]
  end

  # -- The macrostep's round-less effects -----------------------------------

  @spec effects_lines([Message.t()]) :: [String.t()]
  defp effects_lines([]), do: []

  defp effects_lines(effects) do
    ["", "Effects with no round (listed per macrostep):"] ++ Enum.map(effects, &effect_line/1)
  end

  @spec effect_line(Message.t()) :: String.t()
  defp effect_line(%Message{type: "effect.log", payload: payload}) do
    "- effect.log#{payload_suffix(payload, ~w(label value))}"
  end

  defp effect_line(%Message{type: type, payload: payload})
       when type in ["effect.send", "effect.send_delayed"] do
    "- #{type}#{payload_suffix(payload, ~w(event target))}"
  end

  defp effect_line(%Message{type: type, payload: payload})
       when type in ["effect.invoke", "effect.cancel_invoke", "effect.autoforward"] do
    "- #{type}#{payload_suffix(payload, ["invoke_id"])}"
  end

  defp effect_line(%Message{type: "effect.cancel", payload: payload}) do
    "- effect.cancel#{payload_suffix(payload, ["send_id"])}"
  end

  defp effect_line(%Message{type: type}), do: "- #{type}"

  @spec payload_suffix(map(), [String.t()]) :: String.t()
  defp payload_suffix(payload, keys) do
    case Enum.filter(keys, &Map.has_key?(payload, &1)) do
      [] ->
        ""

      present ->
        ": " <> Enum.map_join(present, ", ", &"#{&1}=#{value_cell(Map.get(payload, &1))}")
    end
  end

  # A redacted value renders as an explicit affordance, never as the literal
  # one-key sentinel map (ADR-0012's flow-through clause).
  @spec value_cell(term()) :: String.t()
  defp value_cell(%{"$redacted" => true} = value) when map_size(value) == 1,
    do: redaction_label(value)

  defp value_cell(value), do: inspect(value)

  @spec redaction_label(term()) :: String.t()
  defp redaction_label(%{"$redacted" => true} = value) when map_size(value) == 1, do: "(redacted)"
  defp redaction_label(value), do: inspect(value)
end
