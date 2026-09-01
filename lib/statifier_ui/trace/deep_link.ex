defmodule StatifierUI.Trace.DeepLink do
  @moduledoc """
  Builds a URL into a host's APM backend from the wire format's `otel`
  correlation key (ADR-0013), so a rendered step can be followed to the
  trace that covers it.

  This module is the consuming half of the correlation story
  (`StatifierUI.Trace.Otel` is the producing half). It calls no
  OpenTelemetry API, knows no backend, and holds no default URL: **the
  template is host configuration**, because only the host knows which
  backend its spans went to and what that backend's trace URLs look like.
  A package-supplied default would be a guess that silently sends operators
  to a URL that does not exist.

  ## The template

  A template is a string with `{...}` variables substituted from the message
  being rendered:

      "https://apm.example.com/trace/{trace_id}?span={span_id}"

  | Variable | From |
  |---|---|
  | `trace_id` | the message's `otel.trace_id` - 32 lowercase hex digits |
  | `span_id` | the message's `otel.span_id` - 16 lowercase hex digits |
  | `session` | the message's `session` |
  | `macrostep` | the message's `macrostep` |

  A template naming neither `trace_id` nor `span_id` is rejected: it would
  render the same URL for every step, which is a configuration mistake and
  not a deep link. Any other `{name}` is rejected too, rather than being
  passed through as a literal - a typo (`{traceid}`, `{trace-id}`) that
  survived into production would produce a plausible-looking URL that never
  resolves.

  Substituted values are percent-encoded to the unreserved set, so a
  template is safe to write with the variable in a path segment or in a
  query value. The two ids are hex and pass through unchanged; a session id
  is arbitrary host text and does not.

  ## Compile once, at configuration time

  `new/1` returns `{:error, reason}` for a bad template and `new!/1` raises,
  matching `StatifierUI.Trace.Subscriber`'s treatment of its `:otel_context`
  option: a host misconfiguration is loud, immediately, at the point the
  option is read. What is never loud is a *message* with no correlation on
  it - see below.

  ## Absence is not an error

  `url/2` returns `nil` when the message carries no `otel` key, when the key
  is present but malformed, or when the template asks for a value this
  context cannot supply. Absence is the documented normal case: the wire
  format omits `otel` whenever no bridge is attached (ADR-0013), so most
  streams a consumer renders carry none, and a renderer asks for a link and
  gets `nil` rather than branching on the stream's provenance first.

  Malformed is folded into absent deliberately. The wire format is
  language-neutral (ADR-0005), so an `otel` object may have been written by
  a producer this repository never saw; ids that are not W3C Trace Context
  hex cannot be looked up in any backend, and linking to them would send an
  operator somewhere worse than nowhere.

  ## Examples

      iex> {:ok, template} = StatifierUI.Trace.DeepLink.new("https://apm.example.com/trace/{trace_id}?span={span_id}")
      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "sess_1", seq: 7, macrostep: 2,
      ...>   otel: %{"trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736", "span_id" => "00f067aa0ba902b7"}
      ...> }
      iex> StatifierUI.Trace.DeepLink.url(template, message)
      "https://apm.example.com/trace/4bf92f3577b34da6a3ce929d0e0e4736?span=00f067aa0ba902b7"

      iex> {:ok, template} = StatifierUI.Trace.DeepLink.new("https://apm.example.com/trace/{trace_id}")
      iex> message = %StatifierUI.Trace.Message{type: "trace.entry_set", session: "sess_1", seq: 7, macrostep: 2}
      iex> StatifierUI.Trace.DeepLink.url(template, message)
      nil

  """

  alias StatifierUI.Trace.Message

  @typedoc "A compiled template, built by `new/1` and reused per message."
  @type t :: %__MODULE__{template: String.t(), segments: [String.t() | atom()]}

  @typedoc """
  What a URL is built from: a wire message, or the same three values pulled
  out of one. `:otel` is the message's `otel` object, string-keyed as the
  wire format writes it.
  """
  @type context ::
          Message.t()
          | %{
              optional(:otel) => %{optional(String.t()) => String.t()} | nil,
              optional(:session) => String.t() | nil,
              optional(:macrostep) => non_neg_integer() | nil
            }

  @type error ::
          {:not_a_string, term()}
          | {:unknown_variable, String.t()}
          | {:unbalanced_braces, String.t()}
          | :no_correlation_variable

  @enforce_keys [:template, :segments]
  defstruct [:template, :segments]

  @variables ~w(trace_id span_id session macrostep)a
  @correlation ~w(trace_id span_id)a
  @placeholder ~r/\{[^{}]*\}/
  @trace_id ~r/\A[0-9a-f]{32}\z/
  @span_id ~r/\A[0-9a-f]{16}\z/

  @doc """
  Compiles `template` into a `t:t/0`.

  Returns `{:error, reason}` rather than a template that renders wrongly:

    * `{:not_a_string, term}` - the option was not a string
    * `{:unknown_variable, name}` - `{name}` is not one of `trace_id`,
      `span_id`, `session`, `macrostep`
    * `{:unbalanced_braces, template}` - a `{` or `}` outside a variable
    * `:no_correlation_variable` - neither `trace_id` nor `span_id` appears

  ## Examples

      iex> {:ok, template} = StatifierUI.Trace.DeepLink.new("https://apm.example.com/t/{trace_id}")
      iex> template.template
      "https://apm.example.com/t/{trace_id}"

      iex> StatifierUI.Trace.DeepLink.new("https://apm.example.com/t/{traceid}")
      {:error, {:unknown_variable, "traceid"}}

      iex> StatifierUI.Trace.DeepLink.new("https://apm.example.com/session/{session}")
      {:error, :no_correlation_variable}

  """
  @spec new(term()) :: {:ok, t()} | {:error, error()}
  def new(template) when is_binary(template) do
    with {:ok, segments} <- parse(template),
         :ok <- correlating?(segments) do
      {:ok, %__MODULE__{template: template, segments: segments}}
    end
  end

  def new(other), do: {:error, {:not_a_string, other}}

  @doc """
  Compiles `template`, raising `ArgumentError` on a bad one.

  For the option-reading path, where a misconfigured host should hear about
  it at configuration time rather than by getting no links at render time.
  """
  @spec new!(term()) :: t()
  def new!(template) do
    case new(template) do
      {:ok, compiled} -> compiled
      {:error, reason} -> raise ArgumentError, message(reason)
    end
  end

  @doc """
  Builds the URL for `context`, or `nil` when there is no link to build.

  `nil` in place of a template is itself a valid argument and returns `nil`,
  so a renderer holding an unconfigured option calls this unconditionally
  instead of branching around it.

  ## Examples

      iex> message = %StatifierUI.Trace.Message{type: "trace.entry_set", session: "s", seq: 1}
      iex> StatifierUI.Trace.DeepLink.url(nil, message)
      nil

  """
  @spec url(t() | nil, context()) :: String.t() | nil
  def url(nil, _context), do: nil

  def url(%__MODULE__{segments: segments}, context) do
    bindings = bindings(context)

    if valid_correlation?(bindings) do
      render(segments, bindings)
    end
  end

  @doc """
  The `otel` object of `context` when it is well-formed, `nil` otherwise.

  Exposed because "does this step have a trace at all" is a question a
  renderer asks (to decide whether to draw an affordance) separately from
  "what is its URL".

  ## Examples

      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "s", seq: 1,
      ...>   otel: %{"trace_id" => "0123456789abcdef0123456789abcdef", "span_id" => "0123456789abcdef"}
      ...> }
      iex> StatifierUI.Trace.DeepLink.correlation(message)
      %{"trace_id" => "0123456789abcdef0123456789abcdef", "span_id" => "0123456789abcdef"}

      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "s", seq: 1,
      ...>   otel: %{"trace_id" => "TOO-SHORT", "span_id" => "0123456789abcdef"}
      ...> }
      iex> StatifierUI.Trace.DeepLink.correlation(message)
      nil

  """
  @spec correlation(context()) :: %{optional(String.t()) => String.t()} | nil
  def correlation(context) do
    bindings = bindings(context)

    if valid_correlation?(bindings) do
      %{"trace_id" => bindings.trace_id, "span_id" => bindings.span_id}
    end
  end

  # -- Compilation ---------------------------------------------------------

  @spec parse(String.t()) :: {:ok, [String.t() | atom()]} | {:error, error()}
  defp parse(template) do
    @placeholder
    |> Regex.split(template, include_captures: true)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case segment(part) do
        {:ok, segment} -> {:cont, {:ok, [segment | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, segments} -> {:ok, Enum.reverse(segments)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec segment(String.t()) :: {:ok, String.t() | atom()} | {:error, error()}
  defp segment("{" <> rest) do
    name = String.trim_trailing(rest, "}")

    case Enum.find(@variables, &(Atom.to_string(&1) == name)) do
      nil -> {:error, {:unknown_variable, name}}
      variable -> {:ok, variable}
    end
  end

  defp segment(literal) do
    if String.contains?(literal, "{") or String.contains?(literal, "}") do
      {:error, {:unbalanced_braces, literal}}
    else
      {:ok, literal}
    end
  end

  @spec correlating?([String.t() | atom()]) :: :ok | {:error, error()}
  defp correlating?(segments) do
    if Enum.any?(segments, &(&1 in @correlation)) do
      :ok
    else
      {:error, :no_correlation_variable}
    end
  end

  @spec message(error()) :: String.t()
  defp message({:not_a_string, other}) do
    "deep-link template must be a string, got: #{inspect(other)}"
  end

  defp message({:unknown_variable, name}) do
    "unknown deep-link template variable {#{name}}; " <>
      "known variables are #{Enum.map_join(@variables, ", ", &"{#{&1}}")}"
  end

  defp message({:unbalanced_braces, literal}) do
    "unbalanced braces in deep-link template near: #{inspect(literal)}"
  end

  defp message(:no_correlation_variable) do
    "deep-link template names neither {trace_id} nor {span_id}, " <>
      "so every step would link to the same URL"
  end

  # -- Rendering -----------------------------------------------------------

  @spec bindings(context()) :: map()
  defp bindings(%Message{} = message) do
    bindings(%{otel: message.otel, session: message.session, macrostep: message.macrostep})
  end

  defp bindings(context) when is_map(context) do
    otel = Map.get(context, :otel) || %{}

    %{
      trace_id: Map.get(otel, "trace_id"),
      span_id: Map.get(otel, "span_id"),
      session: Map.get(context, :session),
      macrostep: Map.get(context, :macrostep)
    }
  end

  @spec valid_correlation?(map()) :: boolean()
  defp valid_correlation?(%{trace_id: trace_id, span_id: span_id})
       when is_binary(trace_id) and is_binary(span_id) do
    Regex.match?(@trace_id, trace_id) and Regex.match?(@span_id, span_id)
  end

  defp valid_correlation?(_bindings), do: false

  @spec render([String.t() | atom()], map()) :: String.t() | nil
  defp render(segments, bindings) do
    Enum.reduce_while(segments, "", fn segment, acc ->
      case rendered(segment, bindings) do
        nil -> {:halt, nil}
        text -> {:cont, acc <> text}
      end
    end)
  end

  @spec rendered(String.t() | atom(), map()) :: String.t() | nil
  defp rendered(segment, _bindings) when is_binary(segment), do: segment

  defp rendered(variable, bindings) do
    case Map.fetch!(bindings, variable) do
      nil -> nil
      value -> escape(value)
    end
  end

  @spec escape(String.t() | non_neg_integer()) :: String.t()
  defp escape(value) when is_integer(value), do: Integer.to_string(value)
  defp escape(value) when is_binary(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
