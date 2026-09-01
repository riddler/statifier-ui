defmodule StatifierUI.Trace.Otel do
  @moduledoc """
  The producer half of ADR-0013: stamping a message's `otel` correlation key
  from a resolver the host supplies.

  This module calls no OpenTelemetry API and depends on no OTel package
  (ADR-0004, ADR-0013). The ids arrive as opaque strings from a
  `t:resolver/0` the host passes to
  `StatifierUI.Trace.Subscriber` as `:otel_context`; everything here is the
  arithmetic of deciding whether a given message may carry them and whether
  what came back is well-formed enough to write.

  ## The resolver

      otel_context: (session_id, macrostep ->
                       {:ok, %{trace_id: binary, span_id: binary}} | :none)

  It is keyed on `(session_id, macrostep)` rather than on "the currently open
  span" because the subscriber is its own process consuming messages
  asynchronously: by the time it stamps a message the session may have moved
  on, and "current" would silently stamp the wrong macrostep under lag.
  Making that lookup answerable is `opentelemetry_statifier`'s decision in
  its own repository - this package degrades correctly while it is open.

  ## When the key is written

  Only on `trace.*` and `effect.*` messages carrying a `macrostep` - exactly
  where `macrostep` is legal. No `session.*` message ever carries it, because
  upstream has no session-lifetime span and stamping one would assert a
  containment the engine's own bridge declines to claim.

  The object is written only when the resolver answers `{:ok, _}` with both
  ids present and well-formed W3C Trace Context hex: `trace_id` exactly 32
  lowercase hex digits, `span_id` exactly 16, no `0x` prefix, no dashes, no
  uppercase. It is never partial - half a pair cannot be looked up in any
  backend, so a half answer omits the key rather than degrading it.

  ## Failure is absence, never a crash

  On `:none`, on a malformed or partial pair, on any other return shape, or
  on a resolver that raises, exits, or throws, the key is simply omitted and
  the run continues. Correlation metadata is not worth failing a trace over,
  and ADR-0013 names this as the one place in this package where that trade
  is the right one.
  """

  alias StatifierUI.Trace.Message

  @typedoc """
  The host-supplied lookup from `(session_id, macrostep)` to the span
  covering that macrostep.
  """
  @type resolver ::
          (String.t(), non_neg_integer() ->
             {:ok, %{trace_id: String.t(), span_id: String.t()}} | :none)

  @trace_id ~r/\A[0-9a-f]{32}\z/
  @span_id ~r/\A[0-9a-f]{16}\z/

  @doc """
  Returns `message` with its `otel` key stamped from `resolver`, or unchanged.

  A `nil` resolver - the default, and every stream that predates a host
  attaching one - returns the message untouched, which is what keeps golden
  traces byte-comparable.

  ## Examples

      iex> resolver = fn _session, _macrostep ->
      ...>   {:ok, %{trace_id: "4bf92f3577b34da6a3ce929d0e0e4736", span_id: "00f067aa0ba902b7"}}
      ...> end
      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "sess_1", seq: 7, macrostep: 2
      ...> }
      iex> StatifierUI.Trace.Otel.stamp(message, resolver).otel
      %{"span_id" => "00f067aa0ba902b7", "trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736"}

      iex> resolver = fn _session, _macrostep -> :none end
      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "trace.entry_set", session: "sess_1", seq: 7, macrostep: 2
      ...> }
      iex> StatifierUI.Trace.Otel.stamp(message, resolver).otel
      nil

  """
  @spec stamp(Message.t(), resolver() | nil) :: Message.t()
  def stamp(%Message{} = message, nil), do: message

  def stamp(%Message{} = message, resolver) when is_function(resolver, 2) do
    if correlatable?(message) do
      case resolve(resolver, message.session, message.macrostep) do
        {:ok, otel} -> %{message | otel: otel}
        :none -> message
      end
    else
      message
    end
  end

  @doc """
  Whether `message` is one the `otel` key is legal on: a `trace.*` or
  `effect.*` message carrying a `macrostep`.

  ## Examples

      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "session.halted", session: "s", seq: 1
      ...> }
      iex> StatifierUI.Trace.Otel.correlatable?(message)
      false

  """
  @spec correlatable?(Message.t()) :: boolean()
  def correlatable?(%Message{type: type, macrostep: macrostep}) do
    is_integer(macrostep) and
      (String.starts_with?(type, "trace.") or String.starts_with?(type, "effect."))
  end

  # A resolver is host code running inside this subscriber's process. It is
  # given no license to take the trace down with it: every abnormal exit is
  # the same answer as `:none`, deliberately, per ADR-0013.
  @spec resolve(resolver(), String.t(), non_neg_integer()) ::
          {:ok, %{optional(String.t()) => String.t()}} | :none
  defp resolve(resolver, session, macrostep) do
    resolver.(session, macrostep)
  catch
    _kind, _reason -> :none
  else
    answer -> normalize(answer)
  end

  @spec normalize(term()) :: {:ok, %{optional(String.t()) => String.t()}} | :none
  defp normalize({:ok, %{trace_id: trace_id, span_id: span_id}})
       when is_binary(trace_id) and is_binary(span_id) do
    if Regex.match?(@trace_id, trace_id) and Regex.match?(@span_id, span_id) do
      {:ok, %{"span_id" => span_id, "trace_id" => trace_id}}
    else
      :none
    end
  end

  defp normalize(_other), do: :none
end
