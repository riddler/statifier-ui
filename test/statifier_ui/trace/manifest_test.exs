defmodule StatifierUI.Trace.ManifestTest do
  use ExUnit.Case, async: true

  alias Statifier.Machine
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Manifest
  alias StatifierUI.Trace.Message

  @two_state """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <state id="a">
          <transition event="go" target="b" cond="1 == 1" />
      </state>
      <state id="b" />
  </scxml>
  """

  @all_content_kinds """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <datamodel>
          <data id="items" expr="[1, 2, 3]" />
          <data id="x" expr="0" />
      </datamodel>
      <state id="a">
          <onentry>
              <script>x = 1</script>
              <log label="hi" expr="x" />
              <assign location="x" expr="2" />
              <raise event="internal.go" />
              <if cond="x == 2">
                  <log label="yes" />
              </if>
              <foreach item="i" array="items">
                  <log expr="i" />
              </foreach>
              <send event="ping" id="s1" />
              <cancel sendid="s1" />
          </onentry>
          <transition event="go" target="b" />
      </state>
      <state id="b" />
  </scxml>
  """

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  describe "build/3 - states table" do
    test "covers every index including the synthesized root at 0" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      states = message.payload["states"]
      assert length(states) == 3

      root = Enum.find(states, &(&1["index"] == 0))
      assert root["kind"] == "scxml"
      refute Map.has_key?(root, "id")
      refute Map.has_key?(root, "parent")
      assert root["children"] == [1, 2]

      state_a = Enum.find(states, &(&1["id"] == "a"))
      assert state_a["kind"] == "state"
      assert state_a["parent"] == 0
      assert state_a["transitions"] == [0]

      assert %{
               "start_line" => _,
               "start_column" => _,
               "start_offset" => _,
               "end_line" => _,
               "end_column" => _,
               "end_offset" => _
             } = state_a["location"]
    end

    test "omits id for a state with no id" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      root = Enum.find(message.payload["states"], &(&1["index"] == 0))
      refute Map.has_key?(root, "id")
    end
  end

  describe "build/3 - transitions table" do
    test "events is a list of lists and a guarded transition carries cond_location" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      [transition] = message.payload["transitions"]
      assert transition["t_index"] == 0
      assert transition["source"] == 1
      assert transition["targets"] == [2]
      assert transition["events"] == [["go"]]
      assert transition["type"] == "external"
      assert transition["content"] == []
      assert Map.has_key?(transition, "cond_location")
      assert Map.has_key?(transition, "location")
    end
  end

  describe "build/3 - contents table" do
    test "every one of the eight executable-content kinds resolves a location and a kind" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      contents = message.payload["contents"]
      assert contents != []

      kinds = contents |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()

      assert kinds ==
               Enum.sort(~w(raise log assign if foreach script send cancel))

      for content <- contents do
        assert %{
                 "start_line" => start_line,
                 "start_column" => start_column,
                 "start_offset" => start_offset,
                 "end_line" => _,
                 "end_column" => _,
                 "end_offset" => end_offset
               } = content["location"]

        assert is_integer(start_line)
        assert is_integer(start_column)
        assert is_integer(start_offset)
        assert is_integer(end_offset)
        assert end_offset >= start_offset
      end
    end

    test "the assign node's location is a span, never its raw location-attribute string" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      assign = Enum.find(message.payload["contents"], &(&1["kind"] == "assign"))
      assert is_map(assign["location"])
      assert is_integer(assign["location"]["start_offset"])
    end
  end

  describe "build/3 - index round-trip" do
    test "every published index, t_index, and c_index resolves through Machine.at/2, transition/2, and content/2" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      for state <- message.payload["states"] do
        resolved = Machine.at(machine, state["index"])
        assert resolved.index == state["index"]
      end

      for transition <- message.payload["transitions"] do
        resolved = Machine.transition(machine, transition["t_index"])
        assert resolved.t_index == transition["t_index"]
      end

      for content <- message.payload["contents"] do
        resolved = Machine.content(machine, content["c_index"])
        assert resolved.c_index == content["c_index"]
      end
    end
  end

  describe "build/3 - source" do
    test "present when supplied" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1", source: @two_state)
      assert message.payload["source"] == @two_state
    end

    test "absent when not supplied" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")
      refute Map.has_key?(message.payload, "source")
    end

    test "rejected when not a binary" do
      machine = compile!(@two_state)
      assert {:error, {:invalid_source, 123}} = Manifest.build(machine, "sess_1", source: 123)
    end
  end

  describe "build/3 - fixtures" do
    test "survives build/3 and Trace.Json.encode_message/1 byte-identically" do
      machine = compile!(@two_state)
      fixtures = %{"version" => 1, "cases" => [%{"id" => "one", "value" => %{"a" => 1}}]}

      {:ok, message} = Manifest.build(machine, "sess_1", fixtures: fixtures)
      assert message.payload["fixtures"] == fixtures

      encoded = Json.encode_message(message)
      assert encoded =~ Json.encode_to_string(fixtures)
    end

    test "absent when not supplied" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")
      refute Map.has_key?(message.payload, "fixtures")
    end

    test "rejected when not a map" do
      machine = compile!(@two_state)

      assert {:error, {:invalid_fixtures, "nope"}} =
               Manifest.build(machine, "sess_1", fixtures: "nope")
    end
  end

  describe "build/3 - parent_session and invokeid" do
    test "present when supplied" do
      machine = compile!(@two_state)

      {:ok, message} =
        Manifest.build(machine, "sess_child", parent_session: "sess_parent", invokeid: "inv_1")

      assert message.payload["parent_session"] == "sess_parent"
      assert message.payload["invokeid"] == "inv_1"
    end

    test "absent when not supplied" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")
      refute Map.has_key?(message.payload, "parent_session")
      refute Map.has_key?(message.payload, "invokeid")
    end
  end

  describe "build/3 - envelope and version" do
    test "produces %Message{type: \"session.start\", seq: 0}" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      assert %Message{type: "session.start", session: "sess_1", seq: 0} = message
      assert message.macrostep == nil
      assert message.microstep == nil
      assert message.round == nil
    end

    test "version is 1" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")
      assert message.payload["version"] == 1
      assert Manifest.version() == 1
    end
  end

  describe "build/3 - payload key set" do
    test "keys are exactly the subset the options supplied, always including version/states/transitions/contents" do
      machine = compile!(@two_state)

      {:ok, minimal} = Manifest.build(machine, "sess_1")

      assert MapSet.new(Map.keys(minimal.payload)) ==
               MapSet.new(~w(version states transitions contents))

      {:ok, full} =
        Manifest.build(machine, "sess_1",
          source: @two_state,
          fixtures: %{"version" => 1},
          parent_session: "sess_parent",
          invokeid: "inv_1"
        )

      assert MapSet.new(Map.keys(full.payload)) ==
               MapSet.new(
                 ~w(version states transitions contents source fixtures parent_session invokeid)
               )
    end
  end
end
