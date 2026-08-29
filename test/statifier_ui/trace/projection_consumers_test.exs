defmodule StatifierUI.Trace.ProjectionConsumersTest do
  @moduledoc """
  ADR-0012's flow-through clause: the shipped consumers read projected
  `%Message{}` structs without opting in, and what the record still requires
  of them is that a redacted position renders as an explicit redaction
  affordance - never as unbound, null, empty, or a literal one-key map.

  The `session.terminated` case is the sharpest, because before this bead it
  did not mis-render, it raised.
  """

  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.EventLog
  alias StatifierUI.Inspector
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Projection
  alias StatifierUI.Trace.Subscriber

  @chart """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="authorizing" version="1.0">
      <datamodel>
          <data id="amount_cents" expr="1999"/>
      </datamodel>
      <state id="authorizing">
          <transition event="go" target="settled">
              <assign location="amount_cents" expr="2500"/>
              <log label="audit" expr="amount_cents"/>
          </transition>
      </state>
      <state id="settled"/>
  </scxml>
  """

  # EventLog.Markdown builds its labels from the session.start tables, so a
  # hand-made stream still needs a well-formed manifest payload.
  defp manifest do
    %Message{
      type: "session.start",
      session: "s",
      seq: 0,
      payload: %{
        "version" => 1,
        "states" => [],
        "transitions" => [],
        "contents" => [],
        "data" => []
      }
    }
  end

  defp projected_messages do
    machine = SessionCase.compile!(@chart)
    profile = Projection.profile!("end_user_run_history")

    {sub, session} =
      SessionCase.start_early!(machine, "sess_consumers", projection: profile)

    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, 8)
    Subscriber.messages(sub)
  end

  describe "the datamodel explorer" do
    setup do
      assert {:ok, pane} = DatamodelExplorer.build_live(projected_messages())
      %{pane: pane, rendered: DatamodelExplorer.Markdown.render(pane)}
    end

    test "a redacted slot is :redacted, not :undefined", %{pane: pane} do
      entry = Enum.find(pane.entries, &(&1.name == "amount_cents"))

      assert entry.value == :redacted
      refute entry.value == :undefined
    end

    test "the shape column says redacted rather than unknown", %{pane: pane} do
      entry = Enum.find(pane.entries, &(&1.name == "amount_cents"))

      assert entry.shape == :redacted
    end

    test "the fold produces no undecodable-value diagnostic", %{pane: pane} do
      # Before this bead Value.decode/1 rejected the sentinel, and the
      # explorer substituted :undefined plus a diagnostic - reporting a live
      # datamodel as permanently unbound.
      refute Enum.any?(
               DatamodelExplorer.diagnostics(pane),
               &(&1.kind == :undecodable_datamodel_value)
             )
    end

    test "the rendered pane shows an explicit affordance", %{rendered: rendered} do
      assert rendered =~ "(redacted)"
      refute rendered =~ "$redacted"
      # The data tier is what projection touches. The function tier's
      # :undefined rows are unrelated built-ins and stay as they were.
      assert rendered =~ "| amount_cents | redacted | (redacted) |"
    end

    test "a structural field survives the render", %{rendered: rendered} do
      assert rendered =~ "amount_cents"
    end
  end

  describe "the event log" do
    setup do
      # payload_suffix/2 is reached by the round-less effect path, which is
      # where effect.log's value is rendered with inspect/1.
      messages = [
        manifest(),
        %Message{
          type: "effect.log",
          session: "s",
          seq: 1,
          macrostep: 1,
          payload: %{"label" => "audit", "value" => %{"$redacted" => true}}
        }
      ]

      assert {:ok, log} = EventLog.build(messages)
      %{rendered: EventLog.Markdown.render(log)}
    end

    test "effect.log's value renders as an affordance, not a literal map", %{rendered: rendered} do
      assert rendered =~ "value=(redacted)"
      refute rendered =~ "$redacted"
    end

    test "the label beside it survives", %{rendered: rendered} do
      assert rendered =~ "label=\"audit\""
    end
  end

  describe "session.terminated's sentinel reason" do
    test "renders instead of raising Protocol.UndefinedError" do
      # The reason field is the one position where projection changes a JSON
      # type, from string to object. The renderer interpolated it directly,
      # and String.Chars is not implemented for Map.
      messages = [
        manifest(),
        %Message{
          type: "session.terminated",
          session: "s",
          seq: 1,
          payload: %{"reason" => %{"$redacted" => true}}
        }
      ]

      assert {:ok, log} = EventLog.build(messages)
      rendered = EventLog.Markdown.render(log)

      assert rendered =~ "Session terminated: (redacted)"
    end

    test "an ordinary string reason still renders unchanged" do
      messages = [
        manifest(),
        %Message{
          type: "session.terminated",
          session: "s",
          seq: 1,
          payload: %{"reason" => ":normal"}
        }
      ]

      assert {:ok, log} = EventLog.build(messages)

      assert EventLog.Markdown.render(log) =~ "Session terminated: :normal"
    end
  end

  describe "the status pane surfaces the mode" do
    test "names the profile so a user has something to quote" do
      stats = %{
        session: "s",
        status: :attached,
        seq: 3,
        buffered: 3,
        dropped: 0,
        errors: 0,
        foreign: 0,
        diagnostics: [],
        projection: %{mode: "projected", profile: "end_user_run_history"}
      }

      rendered = Inspector.status(stats)

      assert rendered =~ "Projected"
      assert rendered =~ "end_user_run_history"
    end

    test "says nothing extra for an unprojected stream" do
      stats = %{
        session: "s",
        status: :attached,
        seq: 3,
        buffered: 3,
        dropped: 0,
        errors: 0,
        foreign: 0,
        diagnostics: [],
        projection: nil
      }

      refute Inspector.status(stats) =~ "Projected"
    end
  end
end
