defmodule StatifierUI.Trace.DeepLinkTest do
  use ExUnit.Case, async: true

  doctest StatifierUI.Trace.DeepLink

  alias StatifierUI.Trace.DeepLink
  alias StatifierUI.Trace.Message

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @span_id "00f067aa0ba902b7"
  @template "https://apm.example.com/trace/{trace_id}?span={span_id}"

  defp otel(trace_id \\ @trace_id, span_id \\ @span_id) do
    %{"trace_id" => trace_id, "span_id" => span_id}
  end

  defp message(fields \\ []) do
    struct!(
      %Message{
        type: "trace.entry_set",
        session: "sess_1",
        seq: 7,
        macrostep: 2,
        microstep: 1,
        round: 0,
        otel: otel()
      },
      fields
    )
  end

  defp compiled(template \\ @template) do
    {:ok, compiled} = DeepLink.new(template)
    compiled
  end

  describe "new/1 - accepting a template" do
    test "keeps the template string on the compiled struct" do
      assert %DeepLink{template: @template} = compiled()
    end

    test "accepts every documented variable" do
      assert {:ok, _compiled} =
               DeepLink.new("https://apm/{session}/{macrostep}/{trace_id}/{span_id}")
    end

    test "accepts a template naming only span_id" do
      assert {:ok, _compiled} = DeepLink.new("https://apm/span/{span_id}")
    end
  end

  describe "new/1 - rejecting a template" do
    test "rejects an unknown variable rather than passing it through" do
      assert DeepLink.new("https://apm/{traceid}") == {:error, {:unknown_variable, "traceid"}}
      assert DeepLink.new("https://apm/{trace-id}") == {:error, {:unknown_variable, "trace-id"}}
      assert DeepLink.new("https://apm/{}") == {:error, {:unknown_variable, ""}}
    end

    test "rejects an unclosed or stray brace" do
      assert {:error, {:unbalanced_braces, _near}} = DeepLink.new("https://apm/{trace_id")
      assert {:error, {:unbalanced_braces, _near}} = DeepLink.new("https://apm/{trace_id}}")
    end

    test "rejects a template that would render one URL for every step" do
      assert DeepLink.new("https://apm/session/{session}") == {:error, :no_correlation_variable}
      assert DeepLink.new("https://apm/home") == {:error, :no_correlation_variable}
    end

    test "rejects a non-string" do
      assert DeepLink.new(nil) == {:error, {:not_a_string, nil}}
      assert DeepLink.new(:apm) == {:error, {:not_a_string, :apm}}
    end
  end

  describe "new!/1" do
    test "returns the compiled template" do
      assert %DeepLink{} = DeepLink.new!(@template)
    end

    test "raises with the reason spelled out, at configuration time" do
      assert_raise ArgumentError, ~r/unknown deep-link template variable \{traceid\}/, fn ->
        DeepLink.new!("https://apm/{traceid}")
      end

      assert_raise ArgumentError, ~r/neither \{trace_id\} nor \{span_id\}/, fn ->
        DeepLink.new!("https://apm/home")
      end
    end
  end

  describe "url/2 - a message carrying correlation" do
    test "substitutes both ids" do
      assert DeepLink.url(compiled(), message()) ==
               "https://apm.example.com/trace/#{@trace_id}?span=#{@span_id}"
    end

    test "substitutes the session and macrostep" do
      template = compiled("https://apm/{session}/{macrostep}/{trace_id}")

      assert DeepLink.url(template, message()) == "https://apm/sess_1/2/#{@trace_id}"
    end

    test "renders a repeated variable at every position" do
      template = compiled("https://apm/{trace_id}/{trace_id}")

      assert DeepLink.url(template, message()) == "https://apm/#{@trace_id}/#{@trace_id}"
    end

    test "percent-encodes a substituted session id" do
      template = compiled("https://apm/{trace_id}?service={session}")

      assert DeepLink.url(template, message(session: "tenant a/b?c")) ==
               "https://apm/#{@trace_id}?service=tenant%20a%2Fb%3Fc"
    end

    test "accepts a bare context map as well as a message" do
      context = %{otel: otel(), session: "sess_1", macrostep: 2}

      assert DeepLink.url(compiled(), context) == DeepLink.url(compiled(), message())
    end
  end

  describe "url/2 - no link to build" do
    test "a nil template is a valid argument and yields no link" do
      assert DeepLink.url(nil, message()) == nil
    end

    test "a message with no otel key yields no link" do
      assert DeepLink.url(compiled(), message(otel: nil)) == nil
    end

    test "a session.* message - never correlatable - yields no link" do
      assert DeepLink.url(compiled(), message(type: "session.halted", macrostep: nil, otel: nil)) ==
               nil
    end

    test "a half pair yields no link" do
      assert DeepLink.url(compiled(), message(otel: %{"trace_id" => @trace_id})) == nil
      assert DeepLink.url(compiled(), message(otel: %{"span_id" => @span_id})) == nil
    end

    test "ids that are not W3C Trace Context hex yield no link" do
      for bad <- [
            otel(String.upcase(@trace_id), @span_id),
            otel("0x" <> @trace_id, @span_id),
            otel(String.slice(@trace_id, 0, 31), @span_id),
            otel(@trace_id, String.slice(@span_id, 0, 15)),
            otel(@trace_id, @trace_id),
            otel(@span_id, @span_id)
          ] do
        assert DeepLink.url(compiled(), message(otel: bad)) == nil
      end
    end

    test "a template asking for a value this context cannot supply yields no link" do
      template = compiled("https://apm/{trace_id}/{macrostep}")

      assert DeepLink.url(template, %{otel: otel(), session: "s", macrostep: nil}) == nil
    end
  end

  describe "correlation/1" do
    test "returns the well-formed pair" do
      assert DeepLink.correlation(message()) == otel()
    end

    test "returns nil for absent or malformed correlation" do
      assert DeepLink.correlation(message(otel: nil)) == nil
      assert DeepLink.correlation(message(otel: %{"trace_id" => @trace_id})) == nil
      assert DeepLink.correlation(message(otel: otel("nope", @span_id))) == nil
      assert DeepLink.correlation(%{}) == nil
    end
  end
end
