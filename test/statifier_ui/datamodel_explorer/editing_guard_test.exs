defmodule StatifierUI.DatamodelExplorer.EditingGuardTest do
  use ExUnit.Case, async: true

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.DatamodelExplorer.Entry
  alias StatifierUI.DatamodelExplorer.Markdown
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Projection

  # ADR-0012's flow-through clause, the half `sui-8hg` owns: no value-editing
  # affordance over a projected stream, and never over a redacted slot.
  #
  # The stream is the `live_test.exs` worked example, run through the real
  # `Projection.project/2` rather than hand-stamped, so the header this guard
  # keys on is the one the producer actually writes.
  @session_start %Message{
    type: "session.start",
    session: "sess_dm",
    seq: 0,
    payload: %{
      "version" => 1,
      "data" => [%{"d_index" => 0, "id" => "count", "location" => %{}}]
    }
  }

  @session_datamodel %Message{
    type: "session.datamodel",
    session: "sess_dm",
    seq: 1,
    payload: %{"datamodel" => %{"count" => %{"$undefined" => true}}}
  }

  @count_bound %Message{
    type: "effect.datamodel_change",
    session: "sess_dm",
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

  defp projected(opts \\ []) do
    profile = Projection.profile!("tenant-safe", opts)
    Enum.map(@worked_example, &Projection.project(&1, profile))
  end

  defp entry(pane, name) do
    Enum.find(DatamodelExplorer.entries(pane), &(&1.name == name))
  end

  describe "the projection header" do
    test "an unprojected live pane carries no header and is not projected" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      assert pane.projection == nil
      refute DatamodelExplorer.projected?(pane)
      assert DatamodelExplorer.projection_profile(pane) == nil
    end

    test "a projected live pane carries session.start's header verbatim" do
      assert {:ok, pane} = projected() |> DatamodelExplorer.build_live()

      assert pane.projection == %{"mode" => "projected", "profile" => "tenant-safe"}
      assert DatamodelExplorer.projected?(pane)
      assert DatamodelExplorer.projection_profile(pane) == "tenant-safe"
    end

    test "an authoring pane and an empty live pane are never projected" do
      assert {:ok, empty} = DatamodelExplorer.build_live([])
      refute DatamodelExplorer.projected?(empty)
      refute DatamodelExplorer.projected?(%DatamodelExplorer{mode: :authoring})
    end
  end

  describe "edit_disabled_reason/1 - the pane-level guard" do
    test "an unprojected pane forbids nothing" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      assert DatamodelExplorer.edit_disabled_reason(pane) == nil
      assert DatamodelExplorer.editable?(pane)
    end

    test "a projected pane disables editing and says why, naming the profile" do
      assert {:ok, pane} = projected() |> DatamodelExplorer.build_live()

      reason = DatamodelExplorer.edit_disabled_reason(pane)

      refute DatamodelExplorer.editable?(pane)
      assert reason =~ "Editing is disabled"
      assert reason =~ "tenant-safe"
    end

    test "the header, not the presence of a sentinel, is what closes the door" do
      # Every value this stream carries is allowed back by the profile, so
      # nothing in the fold is redacted - and the pane is still projected.
      assert {:ok, pane} =
               [allow_paths: [["count"]]] |> projected() |> DatamodelExplorer.build_live()

      assert entry(pane, "count").value == 42
      refute DatamodelExplorer.editable?(pane)
    end
  end

  describe "edit_disabled_reason/2 - the per-entry guard" do
    test "a redacted slot is never editable, and its reason names the slot" do
      assert {:ok, pane} = projected() |> DatamodelExplorer.build_live()

      count = entry(pane, "count")
      assert count.value == :redacted

      refute DatamodelExplorer.editable?(pane, count)
      assert DatamodelExplorer.edit_disabled_reason(pane, count) =~ "Editing is disabled"
    end

    test "a redacted slot on an unprojected pane still carries its own reason" do
      # The defensive case: a redaction that reached a consumer without the
      # header (a single message pulled out of a log). The sentinel alone is
      # enough to refuse.
      pane = %DatamodelExplorer{mode: :live}

      redacted = %Entry{
        name: "count",
        tier: :data,
        value: :redacted,
        shape: :redacted,
        label: "redacted"
      }

      assert DatamodelExplorer.edit_disabled_reason(pane) == nil
      refute DatamodelExplorer.editable?(pane, redacted)
      assert DatamodelExplorer.edit_disabled_reason(pane, redacted) =~ "count"
    end

    test "an ordinary entry on an unprojected pane is editable" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      count = entry(pane, "count")
      assert count.value == 42
      assert DatamodelExplorer.editable?(pane, count)
    end

    test "the pane-level reason wins over the entry-level one" do
      assert {:ok, pane} = projected() |> DatamodelExplorer.build_live()

      count = entry(pane, "count")

      assert DatamodelExplorer.edit_disabled_reason(pane, count) ==
               DatamodelExplorer.edit_disabled_reason(pane)
    end
  end

  describe "the rendered pane says why" do
    test "a projected pane's Markdown header names the profile and the refusal" do
      assert {:ok, pane} = projected() |> DatamodelExplorer.build_live()

      markdown = Markdown.render(pane)

      assert markdown =~ "# Datamodel: live"
      assert markdown =~ "tenant-safe"
      assert markdown =~ "Editing is disabled"
      assert markdown =~ "(redacted)"
    end

    test "an unprojected pane's Markdown says nothing about editing" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      refute Markdown.render(pane) =~ "Editing is disabled"
    end
  end
end
