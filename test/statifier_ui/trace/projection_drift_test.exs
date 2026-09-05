defmodule StatifierUI.Trace.ProjectionDriftTest do
  @moduledoc """
  The projection counterpart to `StatifierUI.Trace.WireFormatSpecTest`.

  ADR-0012 names one standing drift risk: a value position added to the
  format later with no projection rule would carry values through a projected
  stream silently, which is the worst failure available because it is
  invisible. The mitigation the record names is that the closed position set
  is defined by the spec's own value-typed rows, so the spec table is the
  checklist. These tests are that checklist, asserted in both directions.
  """

  use ExUnit.Case, async: true

  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Normalizer
  alias StatifierUI.Trace.Projection

  @wire_format Path.join([__DIR__, "..", "..", "..", "docs", "wire-format.md"])

  describe "the documented position table and the code agree" do
    test "every documented projected type has a rule, and every rule is documented" do
      documented = documented_projected_types()
      code = MapSet.new(Projection.projected_types())

      assert MapSet.difference(documented, code) |> MapSet.to_list() == [],
             "documented in the Projection position table but no rule in " <>
               "StatifierUI.Trace.Projection"

      assert MapSet.difference(code, documented) |> MapSet.to_list() == [],
             "has a projection rule but is missing from the Projection " <>
               "position table in docs/wire-format.md"

      assert documented == code
    end

    test "every projected type is a real type in the vocabulary" do
      vocabulary = MapSet.new(Normalizer.types())
      projected = MapSet.new(Projection.projected_types())

      assert MapSet.subset?(projected, vocabulary),
             "projection names a type the format does not define: " <>
               inspect(MapSet.to_list(MapSet.difference(projected, vocabulary)))
    end
  end

  describe "no value survives a deny-all profile" do
    setup do
      %{profile: Projection.profile!("deny_all")}
    end

    test "every value position in a fully-populated stream is a sentinel", %{profile: profile} do
      for message <- populated_messages() do
        projected = Projection.project(message, profile)

        refute leaks_secret?(projected.payload),
               "#{message.type} leaked a value through a deny-all projection: " <>
                 inspect(projected.payload)
      end
    end

    test "the marker really is detectable, so the assertion above can fail" do
      # A positive control for the check itself: without projection the same
      # walk must find the marker in every message that carries a value.
      for message <- populated_messages() do
        assert leaks_secret?(message.payload),
               "#{message.type} carries no detectable value, so its row in " <>
                 "the deny-all test proves nothing"
      end
    end
  end

  # -- helpers ---------------------------------------------------------------

  @secret "SENTINEL-VALUE-MUST-NOT-SURVIVE"

  # Walks an arbitrary projected payload looking for the marker string. A
  # structural field never carries it, so any hit is a value that survived.
  defp leaks_secret?(value) when is_binary(value), do: value == @secret
  defp leaks_secret?(value) when is_list(value), do: Enum.any?(value, &leaks_secret?/1)

  defp leaks_secret?(value) when is_map(value) do
    Enum.any?(value, fn {key, inner} -> leaks_secret?(key) or leaks_secret?(inner) end)
  end

  defp leaks_secret?(_value), do: false

  defp message(type, payload), do: %Message{type: type, session: "s", seq: 1, payload: payload}

  defp event_with_data, do: %{"name" => "go", "type" => "external", "data" => @secret}

  # ADR-0014's reason arm. `reason` is `inspect/1` of an engine reason term,
  # so a datamodel value reaches it verbatim - the marker stands in for one.
  defp event_with_error_reason do
    %{
      "name" => "error.execution",
      "type" => "platform",
      "error" => %{
        "class" => "reason",
        "kind" => "not_iterable",
        "reason" => @secret,
        "content_path" => [3]
      }
    }
  end

  defp populated_messages do
    [
      message("session.datamodel", %{"datamodel" => %{"account" => @secret}}),
      message("effect.datamodel_change", %{
        "location_path" => ["account"],
        "location_source" => "assign",
        "new_value" => @secret,
        "prior_value" => @secret
      }),
      message("trace.event_dequeued", %{"event" => event_with_data(), "from" => "external"}),
      message("trace.event_dequeued", %{
        "event" => event_with_error_reason(),
        "from" => "internal"
      }),
      message("trace.transitions_selected", %{
        "t_indexes" => [0],
        "event" => event_with_error_reason()
      }),
      message("trace.finalize_autoforward", %{
        "event" => event_with_error_reason(),
        "finalized" => true,
        "forwarded" => true
      }),
      message("effect.autoforward", %{
        "invoke_id" => "i1",
        "state_index" => 0,
        "event" => event_with_error_reason()
      }),
      message("trace.transitions_selected", %{"t_indexes" => [0], "event" => event_with_data()}),
      message("trace.finalize_autoforward", %{
        "event" => event_with_data(),
        "finalized" => true,
        "forwarded" => true
      }),
      message("trace.done", %{"configuration" => [0], "donedata" => @secret}),
      message("effect.done", %{"configuration" => [0], "donedata" => @secret}),
      message("effect.autoforward", %{
        "invoke_id" => "i1",
        "state_index" => 0,
        "event" => event_with_data()
      }),
      message("effect.budget_exhausted", %{
        "configuration" => [0],
        "budget" => 10,
        "pending_internal_events" => [event_with_data(), event_with_data()]
      }),
      message("effect.log", %{"label" => "note", "value" => @secret}),
      message("effect.invoke", %{
        "invoke_id" => "i1",
        "state_index" => 0,
        "invoke_index" => 0,
        "params" => @secret,
        "content" => @secret
      }),
      message("effect.send", %{"event" => "go", "send_id" => "s1", "data" => @secret}),
      message("effect.send_delayed", %{
        "event" => "go",
        "send_id" => "s1",
        "delay_ms" => 5,
        "data" => @secret
      }),
      message("session.unroutable", %{
        "effect" => %{"kind" => "effect.log", "label" => "note", "value" => @secret}
      }),
      message("session.start", %{"version" => 1, "fixtures" => %{"datamodel" => @secret}}),
      message("session.terminated", %{"reason" => @secret})
    ]
  end

  # Anchored on the section heading and stopped at the next top-level heading,
  # rather than scanning to end of file the way the type-index parser does -
  # so a later section growing a table of the same shape cannot leak into this
  # set.
  defp documented_projected_types do
    document = File.read!(@wire_format)

    [_before, after_heading] = String.split(document, "## Projection", parts: 2)

    section =
      case String.split(after_heading, "\n## ", parts: 2) do
        [only] -> only
        [section, _rest] -> section
      end

    ~r/^\|\s*`([a-z._]+)`\s*\|/m
    |> Regex.scan(section, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end
end
