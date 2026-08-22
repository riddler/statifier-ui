defmodule StatifierUI.DatamodelExplorer.MarkdownTest do
  use ExUnit.Case, async: true

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.DatamodelExplorer.Markdown
  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Message

  @chart """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <datamodel>
          <data id="tier"/>
      </datamodel>
      <state id="a"/>
  </scxml>
  """

  # The `sui-t36.7` live_test.exs `@worked_example` idiom, transcribed the
  # same way from `docs/wire-format.md:737-762` and `:629-681`: a
  # `session.start` naming one `<data id="count">`, its `session.datamodel`
  # snapshot, and one binding write.
  @session_start %Message{
    type: "session.start",
    session: "sess_md",
    seq: 0,
    payload: %{
      "version" => 1,
      "data" => [%{"d_index" => 0, "id" => "count", "location" => %{}}]
    }
  }

  @session_datamodel %Message{
    type: "session.datamodel",
    session: "sess_md",
    seq: 1,
    payload: %{
      "datamodel" => %{
        "count" => %{"$undefined" => true},
        "_sessionid" => "sess_md",
        "_name" => %{"$undefined" => true},
        "_event" => %{"$undefined" => true},
        "_ioprocessors" => %{
          "http://www.w3.org/TR/scxml/#SCXMLEventProcessor" => %{"location" => "#_scxml_sess_md"}
        }
      }
    }
  }

  @count_bound %Message{
    type: "effect.datamodel_change",
    session: "sess_md",
    seq: 2,
    macrostep: 0,
    microstep: 0,
    payload: %{
      "location_path" => ["count"],
      "location_source" => "count",
      "new_value" => 42,
      "d_index" => 0
    }
  }

  @worked_example [@session_start, @session_datamodel, @count_bound]

  @spec rendered_lines(DatamodelExplorer.t(), keyword()) :: [String.t()]
  defp rendered_lines(pane, opts \\ []) do
    pane
    |> Markdown.render(opts)
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
  end

  describe "render/2 - authoring mode" do
    test "names the selected scenario" do
      machine = SessionCase.compile!(@chart)
      {:ok, fixtures} = Fixtures.new(scenarios: %{"gold" => %{"tier" => "gold"}})
      {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      lines = rendered_lines(pane)

      assert "# Datamodel: authoring (scenario: gold)" in lines
      assert Enum.any?(lines, &(&1 == "| tier | string | \"gold\" |"))
    end

    test "no fixtures names no scenario" do
      machine = SessionCase.compile!(@chart)
      {:ok, pane} = DatamodelExplorer.build_authoring(machine, nil)

      lines = rendered_lines(pane)

      assert "# Datamodel: authoring (scenario: (none))" in lines
    end
  end

  describe "render/2 - live mode" do
    test "names the session and macrostep" do
      {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      lines = rendered_lines(pane)

      assert "# Datamodel: live (session: sess_md, macrostep: 0)" in lines
    end

    test "no writes yet names no macrostep" do
      {:ok, pane} = DatamodelExplorer.build_live([@session_start, @session_datamodel])

      lines = rendered_lines(pane)

      assert "# Datamodel: live (session: sess_md, macrostep: (none))" in lines
    end
  end

  describe "render/2 - the changed marker" do
    test "a changed? entry's name carries the marker, an unchanged one does not" do
      {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      lines = rendered_lines(pane)

      assert "| count* | integer | 42 |" in lines
      refute Enum.any?(lines, &String.starts_with?(&1, "| count |"))
      assert "| _sessionid | string | \"sess_md\" |" in lines
    end

    test "a custom :changed_marker replaces the default" do
      {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      lines = rendered_lines(pane, changed_marker: " (changed)")

      assert "| count (changed) | integer | 42 |" in lines
    end
  end

  describe "render/2 - :tiers filtering" do
    test "omits a section entirely rather than rendering it empty" do
      {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      lines = rendered_lines(pane, tiers: [:system])

      refute Enum.any?(lines, &(&1 == "### data"))
      assert "### system" in lines
      refute Enum.any?(lines, &(&1 == "### function"))
    end
  end

  describe "render/2 - truncated?" do
    test "produces the drop-warning line" do
      dropped_head = %Message{@session_datamodel | seq: 5}
      {:ok, pane} = DatamodelExplorer.build_live([dropped_head])

      lines = rendered_lines(pane)

      assert pane.truncated? == true

      assert "Earliest entries dropped; this fold does not start at the session's beginning." in lines
    end

    test "a complete fold renders no drop warning" do
      {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      lines = rendered_lines(pane)

      refute Enum.any?(lines, &String.contains?(&1, "dropped"))
    end
  end

  describe "render/2 - diagnostics" do
    test "a diagnostics section appears only when the pane carries diagnostics" do
      bad_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_md",
        seq: 3,
        macrostep: 0,
        microstep: 1,
        payload: %{
          "location_path" => ["count", "nested"],
          "location_source" => "count.nested",
          "new_value" => "oops"
        }
      }

      {:ok, with_diagnostics} = DatamodelExplorer.build_live(@worked_example ++ [bad_write])
      {:ok, without_diagnostics} = DatamodelExplorer.build_live(@worked_example)

      with_lines = rendered_lines(with_diagnostics)
      without_lines = rendered_lines(without_diagnostics)

      assert "### Diagnostics" in with_lines
      assert Enum.any?(with_lines, &String.starts_with?(&1, "- unresolvable_location_path:"))
      refute "### Diagnostics" in without_lines
    end
  end

  describe "render/2 - :max_keys pass-through" do
    test "max_keys: 1 truncates a map label" do
      machine = SessionCase.compile!(@chart)

      {:ok, fixtures} =
        Fixtures.new(scenarios: %{"gold" => %{"tier" => %{"a" => 1, "b" => 2}}})

      {:ok, pane} = DatamodelExplorer.build_authoring(machine, fixtures)

      default_lines = rendered_lines(pane)
      truncated_lines = rendered_lines(pane, max_keys: 1)

      assert Enum.any?(
               default_lines,
               &(&1 == "| tier | map{a: integer, b: integer} | %{\"a\" => 1, \"b\" => 2} |")
             )

      assert Enum.any?(
               truncated_lines,
               &(&1 == "| tier | map{a: integer, ...} | %{\"a\" => 1, \"b\" => 2} |")
             )
    end
  end
end
