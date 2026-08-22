defmodule StatifierUI.EventLog.MarkdownTest do
  use ExUnit.Case, async: true

  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.Labels
  alias StatifierUI.EventLog.Markdown
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Manifest
  alias StatifierUI.Trace.Message

  # The worked example's chart (`docs/wire-format.md:755-761`), driven the
  # same way: one external "go" from `a` to `b`, after the initialize burst.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  setup do
    machine = SessionCase.compile!(@chart)
    {:ok, start_message} = Manifest.build(machine, "sess_golden")
    labels = Labels.from_manifest(start_message)

    states = start_message.payload["states"]
    state_a = Enum.find(states, &(&1["id"] == "a"))
    state_b = Enum.find(states, &(&1["id"] == "b"))
    root = Enum.find(states, &(&1["kind"] == "scxml"))

    transition =
      Enum.find(start_message.payload["transitions"], &(&1["source"] == state_a["index"]))

    messages = [
      start_message,
      %Message{type: "session.datamodel", session: "sess_golden", seq: 1, payload: %{}},
      %Message{
        type: "trace.entry_set",
        session: "sess_golden",
        seq: 2,
        macrostep: 1,
        microstep: 1,
        round: 0,
        payload: %{"indexes" => [root["index"], state_a["index"]]}
      },
      %Message{
        type: "trace.transitions_selected",
        session: "sess_golden",
        seq: 3,
        macrostep: 1,
        microstep: 1,
        round: 1,
        payload: %{"t_indexes" => []}
      },
      %Message{
        type: "trace.macrostep_stable",
        session: "sess_golden",
        seq: 4,
        macrostep: 1,
        microstep: 1,
        round: 1,
        payload: %{"configuration" => [root["index"], state_a["index"]]}
      },
      %Message{
        type: "trace.event_dequeued",
        session: "sess_golden",
        seq: 5,
        macrostep: 2,
        microstep: 0,
        round: 0,
        payload: %{"event" => %{"name" => "go", "type" => "external"}, "from" => "external"}
      },
      %Message{
        type: "trace.transitions_selected",
        session: "sess_golden",
        seq: 6,
        macrostep: 2,
        microstep: 0,
        round: 0,
        payload: %{
          "event" => %{"name" => "go", "type" => "external"},
          "t_indexes" => [transition["t_index"]]
        }
      },
      %Message{
        type: "trace.exit_set",
        session: "sess_golden",
        seq: 7,
        macrostep: 2,
        microstep: 1,
        round: 0,
        payload: %{"indexes" => [state_a["index"]]}
      },
      %Message{
        type: "trace.entry_set",
        session: "sess_golden",
        seq: 8,
        macrostep: 2,
        microstep: 1,
        round: 0,
        payload: %{"indexes" => [state_b["index"]]}
      },
      %Message{
        type: "trace.transitions_selected",
        session: "sess_golden",
        seq: 9,
        macrostep: 2,
        microstep: 1,
        round: 1,
        payload: %{"t_indexes" => []}
      },
      %Message{
        type: "trace.macrostep_stable",
        session: "sess_golden",
        seq: 10,
        macrostep: 2,
        microstep: 1,
        round: 1,
        payload: %{"configuration" => [root["index"], state_b["index"]]}
      }
    ]

    {:ok, log} = EventLog.build(messages)

    %{
      log: log,
      labels: labels,
      state_a: state_a,
      state_b: state_b,
      transition: transition
    }
  end

  @spec rendered_lines(EventLog.t(), keyword()) :: [String.t()]
  defp rendered_lines(log, opts \\ []) do
    log
    |> Markdown.render(opts)
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
  end

  describe "render/2 - the worked-example table row" do
    test "macrostep 2 round 0 carries go, the resolved transition label, and the exit/entry", %{
      log: log,
      labels: labels,
      state_a: state_a,
      state_b: state_b,
      transition: transition
    } do
      lines = rendered_lines(log)

      expected_row =
        "| 0 | go | #{Labels.transition(labels, transition["t_index"])} | " <>
          "#{state_a["id"]} | #{state_b["id"]} |"

      assert expected_row in lines
    end
  end

  describe "render/2 - exit order (ADR-0011)" do
    test "exit indexes render in list order, not sorted" do
      messages = [
        %Message{
          type: "trace.exit_set",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [3, 2, 1]}
        },
        %Message{
          type: "trace.entry_set",
          session: "s",
          seq: 1,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [9]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      lines = rendered_lines(log, labels: Labels.empty())

      assert "| 0 | - | - | #3, #2, #1 | #9 |" in lines
    end
  end

  describe "render/2 - collapsible: true" do
    test "emits <details>/</details> once per macrostep, and only the last is open", %{log: log} do
      lines = rendered_lines(log)

      assert Enum.count(lines, &(&1 == "</details>")) == 2
      assert "<details>" in lines
      assert "<details open>" in lines
      assert Enum.count(lines, &(&1 == "<details open>")) == 1
    end

    test "open: :all opens every macrostep", %{log: log} do
      lines = rendered_lines(log, open: :all)

      assert Enum.count(lines, &(&1 == "<details open>")) == 2
      refute "<details>" in lines
    end

    test "open: :none opens none", %{log: log} do
      lines = rendered_lines(log, open: :none)

      refute "<details open>" in lines
      assert Enum.count(lines, &(&1 == "<details>")) == 2
    end

    test "open: [1] opens only macrostep 1", %{log: log} do
      lines = rendered_lines(log, open: [1])

      summary_index = Enum.find_index(lines, &(&1 == "<details open>"))
      next_summary = Enum.at(lines, summary_index + 1)

      assert Enum.count(lines, &(&1 == "<details open>")) == 1
      assert next_summary =~ "Macrostep 1:"
    end
  end

  describe "render/2 - collapsible: false" do
    test "emits no <details> anywhere, and a plain heading instead", %{log: log} do
      lines = rendered_lines(log, collapsible: false)

      refute Enum.any?(lines, &String.starts_with?(&1, "<details"))
      refute Enum.any?(lines, &(&1 == "</details>"))
      assert "### Macrostep 1" in lines
      assert "### Macrostep 2" in lines
    end
  end

  describe "render/2 - no manifest" do
    test "degrades to bare indexes rather than crashing" do
      messages = [
        %Message{
          type: "trace.exit_set",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [1]}
        },
        %Message{
          type: "trace.entry_set",
          session: "s",
          seq: 1,
          macrostep: 1,
          microstep: 0,
          round: 0,
          payload: %{"indexes" => [2]}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      lines = rendered_lines(log)

      assert "| 0 | - | - | #1 | #2 |" in lines
    end
  end

  describe "render/2 - truncation" do
    test "a truncated log renders the drop warning" do
      messages = [
        %Message{type: "session.datamodel", session: "s", seq: 7, payload: %{}}
      ]

      {:ok, log} = EventLog.build(messages)
      lines = rendered_lines(log)

      assert log.truncated? == true
      assert "Earliest messages dropped; log starts at seq 7." in lines
    end

    test "a complete log renders no drop warning" do
      messages = [
        %Message{type: "session.datamodel", session: "s", seq: 0, payload: %{}}
      ]

      {:ok, log} = EventLog.build(messages)
      lines = rendered_lines(log)

      assert log.truncated? == false
      refute Enum.any?(lines, &String.contains?(&1, "dropped"))
    end
  end

  describe "render/2 - the raised-cause note" do
    test "renders the cause's own (macrostep, round), not the dequeue's", %{labels: labels} do
      cause = %{
        "origin" => %{"kind" => "state", "state_index" => 0},
        "macrostep" => 1,
        "microstep" => 0,
        "round" => 0
      }

      messages = [
        %Message{
          type: "trace.event_dequeued",
          session: "s",
          seq: 0,
          macrostep: 5,
          microstep: 0,
          round: 3,
          payload: %{
            "event" => %{"name" => "internal", "type" => "internal", "cause" => cause},
            "from" => "internal"
          }
        }
      ]

      {:ok, log} = EventLog.build(messages)
      lines = rendered_lines(log, labels: labels)

      expected =
        "- raised by #{Labels.origin(labels, cause["origin"])} at (macrostep 1, round 0)"

      assert expected in lines

      refute Enum.any?(
               lines,
               &(&1 ==
                   "- raised by #{Labels.origin(labels, cause["origin"])} at (macrostep 5, round 3)")
             )
    end
  end

  describe "render/2 - effect.log" do
    test "appears under the macrostep with its label and value" do
      messages = [
        %Message{
          type: "effect.log",
          session: "s",
          seq: 0,
          macrostep: 1,
          microstep: 0,
          payload: %{"label" => "checkpoint", "value" => 42}
        }
      ]

      {:ok, log} = EventLog.build(messages)
      lines = rendered_lines(log)

      assert "- effect.log: label=\"checkpoint\", value=42" in lines
      assert "Effects with no round (listed per macrostep):" in lines
    end
  end

  describe "render/2 - the initialize burst" do
    test "renders initialize in its summary and no event in its round rows", %{log: log} do
      lines = rendered_lines(log)

      # Macrostep 1 is the initialize burst: its summary names it "initialize"
      # rather than any dequeued event, and neither of its round rows (round
      # 0, entry only; round 1, the eventless quiescence probe) names one.
      assert Enum.any?(lines, &String.contains?(&1, "<summary>Macrostep 1: initialize,"))
      assert "| 0 | - | - | " <> _rest = Enum.find(lines, &String.starts_with?(&1, "| 0 | -"))
      assert "| 1 | (eventless) | none |  |  |" in lines
    end
  end
end
