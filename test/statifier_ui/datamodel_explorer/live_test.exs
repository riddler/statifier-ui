defmodule StatifierUI.DatamodelExplorer.LiveTest do
  use ExUnit.Case, async: true

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.DatamodelExplorer.Entry
  alias StatifierUI.Trace.Message

  # Transcribed from `docs/wire-format.md:737-762` (`session.datamodel`) and
  # `:629-681` (`effect.datamodel_change`), the `event_log_test.exs`
  # `@worked_example` idiom. A chart with a document `<data id="count">`
  # (tier 1, bound during the binding fold), the four spec 5.10 system
  # variables (tier 2a, seeded at session start), and one runtime-only write
  # (`user`, never named by the snapshot).
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
    payload: %{
      "datamodel" => %{
        "count" => %{"$undefined" => true},
        "_sessionid" => "sess_dm",
        "_name" => %{"$undefined" => true},
        "_event" => %{"$undefined" => true},
        "_ioprocessors" => %{
          "http://www.w3.org/TR/scxml/#SCXMLEventProcessor" => %{
            "location" => "#_scxml_sess_dm"
          }
        }
      }
    }
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

  describe "build_live/1 - the session.datamodel snapshot alone" do
    test "the tier-1 <data> entry is :undefined, none changed?, data names sorted" do
      assert {:ok, pane} = DatamodelExplorer.build_live([@session_start, @session_datamodel])

      assert %DatamodelExplorer{mode: :live, session: "sess_dm", macrostep: nil} = pane
      # `_sessionid` and `_ioprocessors` are the two system variables bound
      # at init (`docs/wire-format.md:746-750`); every tier-1 <data>
      # element still reads :undefined, since the snapshot precedes the
      # binding fold.
      assert Enum.all?(DatamodelExplorer.entries(pane, :data), &(&1.value == :undefined))
      assert Enum.all?(pane.entries, &(&1.changed? == false))

      names = pane |> DatamodelExplorer.entries(:system) |> Enum.map(& &1.name)
      assert names == Enum.sort(names)
    end

    test "a {\"$undefined\": true} snapshot value infers :undefined, not a map shape" do
      assert {:ok, pane} = DatamodelExplorer.build_live([@session_start, @session_datamodel])

      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.shape == :undefined
      refute match?({:map, %{"$undefined" => :boolean}}, count.shape)
    end

    test "tier attribution: count is :data, system names are :system" do
      assert {:ok, pane} = DatamodelExplorer.build_live([@session_start, @session_datamodel])

      assert [%Entry{tier: :data, d_index: 0}] =
               Enum.filter(pane.entries, &(&1.name == "count"))

      assert [%Entry{tier: :system}] =
               Enum.filter(pane.entries, &(&1.name == "_sessionid"))
    end
  end

  describe "build_live/1 - one <data> binding write" do
    test "value present, changed? true, macrostep set" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      assert pane.macrostep == 0
      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.value == 42
      assert count.changed? == true
      assert count.tier == :data
    end
  end

  describe "build_live/1 - new_value absent (the unbinding case)" do
    test "the entry becomes :undefined and is marked changed?" do
      unbind = %Message{
        @count_bound
        | payload: %{
            "location_path" => ["count"],
            "location_source" => "count",
            "prior_value" => 42,
            "d_index" => 0
          }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live([@session_start, @session_datamodel, unbind])

      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.value == :undefined
      assert count.changed? == true
    end
  end

  describe "build_live/1 - new_value null" do
    test "the entry becomes nil, distinctly from the absent case" do
      nulled = %Message{
        @count_bound
        | payload: %{
            "location_path" => ["count"],
            "location_source" => "count",
            "new_value" => nil,
            "d_index" => 0
          }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live([@session_start, @session_datamodel, nulled])

      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.value == nil
      assert count.changed? == true
    end
  end

  describe "build_live/1 - two macrosteps of writes" do
    test "only the later macrostep's entries are changed?" do
      second_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 3,
        macrostep: 1,
        microstep: 0,
        payload: %{
          "location_path" => ["count"],
          "location_source" => "count",
          "new_value" => 43,
          "prior_value" => 42,
          "d_index" => 0
        }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live(@worked_example ++ [second_write])

      assert pane.macrostep == 1
      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.value == 43
      assert count.changed? == true
    end

    test "an entry only written at the earlier macrostep is not changed?" do
      # A second variable, "other", is written only at macrostep 0; "count"
      # is written again at macrostep 1. Only "count" should read changed?.
      other_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 3,
        macrostep: 0,
        microstep: 1,
        payload: %{
          "location_path" => ["other"],
          "location_source" => "other",
          "new_value" => "x"
        }
      }

      later_count_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 4,
        macrostep: 1,
        microstep: 0,
        payload: %{
          "location_path" => ["count"],
          "location_source" => "count",
          "new_value" => 99,
          "prior_value" => 42,
          "d_index" => 0
        }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live(@worked_example ++ [other_write, later_count_write])

      assert pane.macrostep == 1
      [other] = Enum.filter(pane.entries, &(&1.name == "other"))
      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert other.changed? == false
      assert other.value == "x"
      assert count.changed? == true
    end
  end

  describe "build_live/1 - a deep location_path into a $undefined root" do
    test "containers are materialized, final value sits at the leaf" do
      deep_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 2,
        macrostep: 0,
        microstep: 0,
        payload: %{
          "location_path" => ["user", "items", 0, "name"],
          "location_source" => "user.items[0].name",
          "new_value" => "Alice"
        }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live([@session_start, @session_datamodel, deep_write])

      [user] = Enum.filter(pane.entries, &(&1.name == "user"))
      assert user.value == %{"items" => [%{"name" => "Alice"}]}
      assert user.tier == :runtime
    end
  end

  describe "build_live/1 - malformed writes" do
    test "an integer segment into a map yields one diagnostic, siblings intact" do
      # "user" is first written as a map (root-level write), then a second
      # write tries to index into it as though it were a list.
      root_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 2,
        macrostep: 0,
        microstep: 0,
        payload: %{
          "location_path" => ["user"],
          "location_source" => "user",
          "new_value" => %{"name" => "Alice"}
        }
      }

      bad_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 3,
        macrostep: 0,
        microstep: 1,
        payload: %{
          "location_path" => ["user", 0],
          "location_source" => "user[0]",
          "new_value" => "oops"
        }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live([
                 @session_start,
                 @session_datamodel,
                 root_write,
                 bad_write,
                 @count_bound
               ])

      assert [%{kind: :unresolvable_location_path}] = pane.diagnostics
      [user] = Enum.filter(pane.entries, &(&1.name == "user"))
      assert user.value == %{"name" => "Alice"}
      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.value == 42
    end

    test "a string segment into a list yields one diagnostic, siblings intact" do
      root_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 2,
        macrostep: 0,
        microstep: 0,
        payload: %{
          "location_path" => ["items"],
          "location_source" => "items",
          "new_value" => [1, 2]
        }
      }

      bad_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 3,
        macrostep: 0,
        microstep: 1,
        payload: %{
          "location_path" => ["items", "name"],
          "location_source" => "items.name",
          "new_value" => "oops"
        }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live([
                 @session_start,
                 @session_datamodel,
                 root_write,
                 bad_write,
                 @count_bound
               ])

      assert [%{kind: :unresolvable_location_path}] = pane.diagnostics
      [items] = Enum.filter(pane.entries, &(&1.name == "items"))
      assert items.value == [1, 2]
      [count] = Enum.filter(pane.entries, &(&1.name == "count"))
      assert count.value == 42
    end
  end

  describe "build_live/1 - a name the snapshot never carried" do
    test "gets tier: :runtime" do
      invoke_write = %Message{
        type: "effect.datamodel_change",
        session: "sess_dm",
        seq: 2,
        macrostep: 0,
        microstep: 0,
        payload: %{
          "location_path" => ["result"],
          "location_source" => "result",
          "new_value" => "ok",
          "owner" => %{"kind" => "invoke", "state_index" => 0, "invoke_index" => 0}
        }
      }

      assert {:ok, pane} =
               DatamodelExplorer.build_live([@session_start, @session_datamodel, invoke_write])

      assert [%Entry{tier: :runtime, value: "ok"}] =
               Enum.filter(pane.entries, &(&1.name == "result"))
    end
  end

  describe "build_live/1 - shuffle invariance" do
    test "five shuffles of the same messages fold to identical structs" do
      {:ok, expected} = DatamodelExplorer.build_live(@worked_example)

      for seed <- 1..5 do
        :rand.seed(:exsss, {seed, seed, seed})
        shuffled = Enum.shuffle(@worked_example)
        assert {:ok, ^expected} = DatamodelExplorer.build_live(shuffled)
      end
    end
  end

  describe "build_live/1 - mixed sessions" do
    test "returns {:error, {:mixed_sessions, ids}} rather than merging timelines" do
      other = %Message{@session_start | session: "sess_other"}

      assert {:error, {:mixed_sessions, ["sess_dm", "sess_other"]}} =
               DatamodelExplorer.build_live([@session_start, other])
    end
  end

  describe "build_live/1 - truncated?" do
    test "true when the lowest seq is greater than 0" do
      dropped_head = %Message{@session_datamodel | seq: 5}

      assert {:ok, pane} = DatamodelExplorer.build_live([dropped_head])
      assert pane.truncated? == true
    end

    test "false when seq starts at 0" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)
      assert pane.truncated? == false
    end
  end

  describe "build_live/1 - empty input" do
    test "returns an empty :live pane" do
      assert {:ok, %DatamodelExplorer{mode: :live, session: nil, entries: []}} =
               DatamodelExplorer.build_live([])
    end
  end

  describe "build_live/1 - tier 2b" do
    test "provider functions appear unchanged from Scope's tier-2b source" do
      assert {:ok, pane} = DatamodelExplorer.build_live(@worked_example)

      functions = DatamodelExplorer.entries(pane, :function)
      refute functions == []
      assert Enum.all?(functions, &(&1.tier == :function))
    end
  end
end
