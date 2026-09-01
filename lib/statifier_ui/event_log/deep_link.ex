defmodule StatifierUI.EventLog.DeepLink do
  @moduledoc """
  The rendering seam for ADR-0013 correlation: from a macrostep in an
  `StatifierUI.EventLog.t()` to a link into the host's APM backend.

  `StatifierUI.Trace.DeepLink` owns the template and the URL; this module
  owns the question a renderer actually asks, which is not about a message
  but about *a macrostep* - the unit an operator sees in the log and the
  unit upstream opens one span for (ADR-0013, "the value is per macrostep").

  ## The option

  Every renderer that grows a link takes the same option, read through
  `from_opts/1`:

      deep_link: "https://apm.example.com/trace/{trace_id}?span={span_id}"

  It is host configuration and has no default: this package does not know
  which backend the host's spans went to. Omit the option and every function
  here returns `nil`, which is the same answer the option gives on a stream
  carrying no correlation at all - a renderer therefore needs no branch for
  "is correlation configured" separate from "does this step have a trace".

  A malformed template raises from `from_opts/1`, at the point the option is
  read, rather than silently rendering no links.

  ## Which message the ids come from

  Every message of one macrostep carries the same `otel` value, so this
  module takes the first well-formed one it finds, scanning the macrostep's
  rounds in order and then its round-less effects. It does not assume the
  key is present on any particular message: a stream may have been captured
  across the moment a host attached correlation, or projected, or written by
  another implementation of the format entirely (ADR-0005), and "the first
  message that actually carries it" is true in all of those cases while
  "the first message" is not.

  A macrostep whose messages carry no correlation - the default for every
  stream captured with no bridge attached - has no link, and that is not an
  error anywhere in this module.
  """

  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.Macrostep
  alias StatifierUI.EventLog.Round
  alias StatifierUI.Trace.DeepLink, as: Template
  alias StatifierUI.Trace.Message

  @type opt :: {:deep_link, String.t() | Template.t() | nil}

  @default_label "trace"

  @doc """
  Reads the `:deep_link` option into a compiled template, or `nil`.

  Accepts a template string, an already-compiled
  `StatifierUI.Trace.DeepLink.t()`, `nil`, or the option being absent.
  Raises `ArgumentError` on a string that is not a usable template.

  ## Examples

      iex> StatifierUI.EventLog.DeepLink.from_opts([])
      nil

      iex> template = StatifierUI.EventLog.DeepLink.from_opts(deep_link: "https://apm.example.com/t/{trace_id}")
      iex> template.template
      "https://apm.example.com/t/{trace_id}"

  """
  @spec from_opts(keyword()) :: Template.t() | nil
  def from_opts(opts) do
    case Keyword.get(opts, :deep_link) do
      nil -> nil
      %Template{} = template -> template
      other -> Template.new!(other)
    end
  end

  @doc """
  The URL for `macrostep`, or `nil` when there is no link to build.

  ## Examples

      iex> template = StatifierUI.EventLog.DeepLink.from_opts(deep_link: "https://apm.example.com/t/{trace_id}/{span_id}")
      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "sess_1", seq: 7, macrostep: 2, round: 0,
      ...>   otel: %{"trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736", "span_id" => "00f067aa0ba902b7"}
      ...> }
      iex> round = %StatifierUI.EventLog.Round{macrostep: 2, round: 0, messages: [message]}
      iex> macrostep = StatifierUI.EventLog.Macrostep.new(2, [round], [])
      iex> StatifierUI.EventLog.DeepLink.for_macrostep(macrostep, template)
      "https://apm.example.com/t/4bf92f3577b34da6a3ce929d0e0e4736/00f067aa0ba902b7"

  """
  @spec for_macrostep(Macrostep.t(), Template.t() | nil) :: String.t() | nil
  def for_macrostep(_macrostep, nil), do: nil

  def for_macrostep(%Macrostep{} = macrostep, %Template{} = template) do
    case correlated_message(macrostep) do
      nil -> nil
      message -> Template.url(template, message)
    end
  end

  @doc """
  Every macrostep of `log` that has a link, as
  `%{macrostep_number => url}`.

  Macrosteps with no correlation are absent from the map rather than mapped
  to `nil`, so `Map.get/2` at the render site is the whole branch.
  """
  @spec for_log(EventLog.t(), Template.t() | nil) :: %{non_neg_integer() => String.t()}
  def for_log(_log, nil), do: %{}

  def for_log(%EventLog{macrosteps: macrosteps}, %Template{} = template) do
    for macrostep <- macrosteps,
        url = for_macrostep(macrostep, template),
        into: %{},
        do: {macrostep.macrostep, url}
  end

  @doc """
  `macrostep`'s link as a Markdown inline link, or `nil`.

  Options:

    * `:label` - the link text, `"trace"` by default.

  The destination is wrapped in `<...>` when it contains a parenthesis or
  whitespace, which is the CommonMark form for exactly that case; a plain
  URL renders plainly, so the common output stays readable in a diff.

  ## Examples

      iex> template = StatifierUI.EventLog.DeepLink.from_opts(deep_link: "https://apm.example.com/t/{trace_id}")
      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "sess_1", seq: 7, macrostep: 2, round: 0,
      ...>   otel: %{"trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736", "span_id" => "00f067aa0ba902b7"}
      ...> }
      iex> round = %StatifierUI.EventLog.Round{macrostep: 2, round: 0, messages: [message]}
      iex> macrostep = StatifierUI.EventLog.Macrostep.new(2, [round], [])
      iex> StatifierUI.EventLog.DeepLink.markdown(macrostep, template)
      "[trace](https://apm.example.com/t/4bf92f3577b34da6a3ce929d0e0e4736)"

      iex> macrostep = StatifierUI.EventLog.Macrostep.new(2, [], [])
      iex> StatifierUI.EventLog.DeepLink.markdown(macrostep, nil)
      nil

  """
  @spec markdown(Macrostep.t(), Template.t() | nil, keyword()) :: String.t() | nil
  def markdown(macrostep, template, opts \\ [])

  def markdown(%Macrostep{} = macrostep, template, opts) do
    case for_macrostep(macrostep, template) do
      nil -> nil
      url -> "[#{Keyword.get(opts, :label, @default_label)}](#{destination(url)})"
    end
  end

  @spec correlated_message(Macrostep.t()) :: Message.t() | nil
  defp correlated_message(%Macrostep{rounds: rounds, effects: effects}) do
    rounds
    |> Enum.flat_map(fn %Round{messages: messages} -> messages end)
    |> Stream.concat(effects)
    |> Enum.find(&(Template.correlation(&1) != nil))
  end

  @spec destination(String.t()) :: String.t()
  defp destination(url) do
    if String.contains?(url, ["(", ")", " ", "\t"]) do
      "<#{url}>"
    else
      url
    end
  end
end
