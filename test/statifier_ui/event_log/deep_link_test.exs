defmodule StatifierUI.EventLog.DeepLinkTest do
  use ExUnit.Case, async: true

  doctest StatifierUI.EventLog.DeepLink

  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.DeepLink
  alias StatifierUI.Trace.Message

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @span_id "00f067aa0ba902b7"
  @other_trace_id "0af7651916cd43dd8448eb211c80319c"
  @other_span_id "b7ad6b7169203331"
  @template "https://apm.example.com/trace/{trace_id}?span={span_id}"

  defp otel(trace_id, span_id), do: %{"trace_id" => trace_id, "span_id" => span_id}

  defp message(fields) do
    struct!(
      %Message{type: "trace.entry_set", session: "sess_1", seq: 0, macrostep: 0, round: 0},
      fields
    )
  end

  # Builds the log the way a consumer gets one: from a flat message list,
  # through EventLog.build/1, so the bucketing under test is the real one.
  defp log(messages) do
    {:ok, log} = EventLog.build(messages)
    log
  end

  defp correlated_macrostep(macrostep, trace_id, span_id) do
    [
      message(
        type: "trace.entry_set",
        seq: macrostep * 2,
        macrostep: macrostep,
        round: 0,
        otel: otel(trace_id, span_id)
      ),
      message(
        type: "trace.macrostep_stable",
        seq: macrostep * 2 + 1,
        macrostep: macrostep,
        round: 0,
        otel: otel(trace_id, span_id)
      )
    ]
  end

  defp macrostep_of(log, number) do
    Enum.find(log.macrosteps, &(&1.macrostep == number))
  end

  describe "from_opts/1" do
    test "compiles a template string" do
      assert %StatifierUI.Trace.DeepLink{template: @template} =
               DeepLink.from_opts(deep_link: @template)
    end

    test "passes an already-compiled template through" do
      compiled = StatifierUI.Trace.DeepLink.new!(@template)

      assert DeepLink.from_opts(deep_link: compiled) == compiled
    end

    test "an absent or nil option is no template, not an error" do
      assert DeepLink.from_opts([]) == nil
      assert DeepLink.from_opts(deep_link: nil) == nil
      assert DeepLink.from_opts(labels: :whatever) == nil
    end

    test "raises on a malformed template, where the option is read" do
      assert_raise ArgumentError, fn -> DeepLink.from_opts(deep_link: "https://apm/{nope}") end
    end
  end

  describe "for_macrostep/2 - a macrostep carrying otel context" do
    setup do
      %{template: DeepLink.from_opts(deep_link: @template)}
    end

    test "renders the link from the host-configured template", %{template: template} do
      macrostep = macrostep_of(log(correlated_macrostep(0, @trace_id, @span_id)), 0)

      assert DeepLink.for_macrostep(macrostep, template) ==
               "https://apm.example.com/trace/#{@trace_id}?span=#{@span_id}"
    end

    test "each macrostep gets its own trace", %{template: template} do
      log =
        log(
          correlated_macrostep(0, @trace_id, @span_id) ++
            correlated_macrostep(1, @other_trace_id, @other_span_id)
        )

      assert DeepLink.for_macrostep(macrostep_of(log, 0), template) =~ @trace_id
      assert DeepLink.for_macrostep(macrostep_of(log, 1), template) =~ @other_trace_id
    end

    test "takes the ids from the first message that actually carries them", %{template: template} do
      macrostep =
        log([
          message(type: "trace.transitions", seq: 0, macrostep: 0, round: 0, otel: nil),
          message(
            type: "trace.entry_set",
            seq: 1,
            macrostep: 0,
            round: 0,
            otel: otel(@trace_id, @span_id)
          )
        ])
        |> macrostep_of(0)

      assert DeepLink.for_macrostep(macrostep, template) =~ @trace_id
    end

    test "finds correlation on a round-less effect message too", %{template: template} do
      macrostep =
        log([
          message(
            type: "effect.log",
            seq: 0,
            macrostep: 0,
            round: nil,
            otel: otel(@trace_id, @span_id)
          )
        ])
        |> macrostep_of(0)

      assert macrostep.effects != []
      assert DeepLink.for_macrostep(macrostep, template) =~ @trace_id
    end
  end

  describe "for_macrostep/2 - no link" do
    test "a macrostep with no otel context anywhere renders no link" do
      template = DeepLink.from_opts(deep_link: @template)

      macrostep =
        log([
          message(type: "trace.entry_set", seq: 0, macrostep: 0, round: 0),
          message(type: "trace.macrostep_stable", seq: 1, macrostep: 0, round: 0)
        ])
        |> macrostep_of(0)

      assert DeepLink.for_macrostep(macrostep, template) == nil
    end

    test "an unconfigured host renders no link even on a correlated macrostep" do
      macrostep = macrostep_of(log(correlated_macrostep(0, @trace_id, @span_id)), 0)

      assert DeepLink.for_macrostep(macrostep, nil) == nil
    end

    test "malformed correlation renders no link rather than a URL that resolves nowhere" do
      template = DeepLink.from_opts(deep_link: @template)

      macrostep =
        log([
          message(
            type: "trace.entry_set",
            seq: 0,
            macrostep: 0,
            round: 0,
            otel: otel("not-a-trace-id", @span_id)
          )
        ])
        |> macrostep_of(0)

      assert DeepLink.for_macrostep(macrostep, template) == nil
    end
  end

  describe "for_log/2" do
    test "maps only the macrosteps that have a link" do
      template = DeepLink.from_opts(deep_link: @template)

      log =
        log(
          correlated_macrostep(0, @trace_id, @span_id) ++
            [message(type: "trace.entry_set", seq: 10, macrostep: 1, round: 0)] ++
            correlated_macrostep(2, @other_trace_id, @other_span_id)
        )

      links = DeepLink.for_log(log, template)

      assert Map.keys(links) == [0, 2]
      assert links[0] =~ @trace_id
      assert links[2] =~ @other_trace_id
    end

    test "an unconfigured host maps nothing" do
      log = log(correlated_macrostep(0, @trace_id, @span_id))

      assert DeepLink.for_log(log, nil) == %{}
    end
  end

  describe "markdown/3" do
    setup do
      macrostep = macrostep_of(log(correlated_macrostep(0, @trace_id, @span_id)), 0)

      %{macrostep: macrostep, template: DeepLink.from_opts(deep_link: @template)}
    end

    test "renders an inline Markdown link", %{macrostep: macrostep, template: template} do
      assert DeepLink.markdown(macrostep, template) ==
               "[trace](https://apm.example.com/trace/#{@trace_id}?span=#{@span_id})"
    end

    test "takes a host-supplied label", %{macrostep: macrostep, template: template} do
      assert DeepLink.markdown(macrostep, template, label: "open in APM") =~ "[open in APM]("
    end

    test "wraps a destination containing parentheses in angle brackets", %{macrostep: macrostep} do
      template = DeepLink.from_opts(deep_link: "https://apm/q(trace={trace_id})")

      assert DeepLink.markdown(macrostep, template) ==
               "[trace](<https://apm/q(trace=#{@trace_id})>)"
    end

    test "renders nothing when there is no link", %{macrostep: macrostep, template: template} do
      assert DeepLink.markdown(macrostep, nil) == nil
      assert DeepLink.markdown(macrostep_of(log(uncorrelated()), 0), template) == nil
    end
  end

  defp uncorrelated do
    [message(type: "trace.entry_set", seq: 0, macrostep: 0, round: 0)]
  end
end
