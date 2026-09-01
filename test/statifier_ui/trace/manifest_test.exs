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

  @written_type """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <state id="a">
          <transition event="go" target="b" type="external" />
      </state>
      <state id="b" />
  </scxml>
  """

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  # Stands in for a Machine compiled by an engine that does not populate
  # `attribute_locations` - the field defaults to `%{}` upstream, so
  # emptying it here reproduces that producer input exactly.
  defp strip_attribute_locations(%Machine{} = machine) do
    states =
      machine.states
      |> Tuple.to_list()
      |> Enum.map(&%{&1 | attribute_locations: %{}})
      |> List.to_tuple()

    transitions =
      machine.transitions
      |> Tuple.to_list()
      |> Enum.map(&%{&1 | attribute_locations: %{}})
      |> List.to_tuple()

    %{machine | states: states, transitions: transitions}
  end

  defp slice(source, %{"start_offset" => start_offset, "end_offset" => end_offset}) do
    binary_part(source, start_offset, end_offset - start_offset)
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

  describe "build/3 - attribute_locations" do
    test "a transition row's entries are exactly the attributes the author wrote, each spanning its own value" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1", source: @two_state)

      [transition] = message.payload["transitions"]
      spans = transition["attribute_locations"]

      assert MapSet.new(Map.keys(spans)) == MapSet.new(~w(event target cond))

      assert slice(@two_state, spans["event"]) == "go"
      assert slice(@two_state, spans["target"]) == "b"
      assert slice(@two_state, spans["cond"]) == "1 == 1"
    end

    test "key presence answers 'was type written', which the lowered value cannot" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      [transition] = message.payload["transitions"]

      # The compiler lowered the unwritten `type` to the `:external` default,
      # so the value says "external" either way. Only key absence separates
      # a defaulted transition from one written `type="external"`.
      assert transition["type"] == "external"
      refute Map.has_key?(transition["attribute_locations"], "type")

      written = compile!(@written_type)
      {:ok, written_message} = Manifest.build(written, "sess_1")

      [written_transition] = written_message.payload["transitions"]
      assert written_transition["type"] == "external"
      assert Map.has_key?(written_transition["attribute_locations"], "type")
    end

    test "a state row carries its own written attributes, and the root carries the scxml element's" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1", source: @two_state)

      state_a = Enum.find(message.payload["states"], &(&1["id"] == "a"))
      assert MapSet.new(Map.keys(state_a["attribute_locations"])) == MapSet.new(~w(id))
      assert slice(@two_state, state_a["attribute_locations"]["id"]) == "a"

      root = Enum.find(message.payload["states"], &(&1["index"] == 0))
      root_attributes = MapSet.new(Map.keys(root["attribute_locations"]))
      assert MapSet.subset?(MapSet.new(~w(initial version datamodel)), root_attributes)
      assert slice(@two_state, root["attribute_locations"]["initial"]) == "a"
    end

    test "every entry is a whole six-field location object, the same shape as `location`" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      [transition] = message.payload["transitions"]

      for {_attribute, span} <- transition["attribute_locations"] do
        assert %{
                 "start_line" => _,
                 "start_column" => _,
                 "start_offset" => _,
                 "end_line" => _,
                 "end_column" => _,
                 "end_offset" => _
               } = span

        assert map_size(span) == 6
      end
    end

    test "cond_location is retained alongside the map rather than replaced by it" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1", source: @two_state)

      [transition] = message.payload["transitions"]

      assert slice(@two_state, transition["cond_location"]) ==
               slice(@two_state, transition["attribute_locations"]["cond"])

      assert Map.has_key?(transition, "cond_location")
    end

    test "an empty map degrades to the element-level location and changes nothing else" do
      machine = compile!(@two_state)
      {:ok, rich} = Manifest.build(machine, "sess_1")

      # A Machine compiled by an engine that does not populate the field, or
      # an element that wrote no attributes at all: the map is `%{}` and a
      # consumer falls back to the row's own `location`.
      stripped = strip_attribute_locations(machine)
      {:ok, degraded} = Manifest.build(stripped, "sess_1")

      [rich_transition] = rich.payload["transitions"]
      [degraded_transition] = degraded.payload["transitions"]

      assert degraded_transition["attribute_locations"] == %{}
      assert degraded_transition["location"] == rich_transition["location"]

      assert Map.delete(degraded_transition, "attribute_locations") ==
               Map.delete(rich_transition, "attribute_locations")

      for state <- degraded.payload["states"] do
        assert state["attribute_locations"] == %{}
      end

      assert Enum.map(degraded.payload["states"], &Map.delete(&1, "attribute_locations")) ==
               Enum.map(rich.payload["states"], &Map.delete(&1, "attribute_locations"))
    end

    test "the object survives JSON encoding with its keys in canonical order" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      decoded = message |> Json.encode_message() |> JSON.decode!()

      [transition] = decoded["transitions"]
      assert Map.has_key?(transition, "attribute_locations")
      assert Map.has_key?(transition["attribute_locations"], "event")

      encoded = Json.encode_to_string(transition["attribute_locations"])
      assert String.starts_with?(encoded, ~s({"cond":))
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

  describe "build/3 - data table" do
    test "empty when the chart has no <datamodel>" do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      assert message.payload["data"] == []
    end

    test "one row per <data> element, dense and in document order" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      data = message.payload["data"]
      assert length(data) == 2

      assert Enum.map(data, & &1["d_index"]) == Enum.to_list(0..1)
      assert Enum.map(data, & &1["id"]) == ["items", "x"]
    end

    test "location is a full six-field span on every row" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      for row <- message.payload["data"] do
        assert %{
                 "start_line" => start_line,
                 "start_column" => start_column,
                 "start_offset" => start_offset,
                 "end_line" => _,
                 "end_column" => _,
                 "end_offset" => end_offset
               } = row["location"]

        assert is_integer(start_line)
        assert is_integer(start_column)
        assert is_integer(start_offset)
        assert is_integer(end_offset)
        assert end_offset >= start_offset
      end
    end

    test "value_location is present as a span, not a string, on both rows" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      # Both <data> elements in @all_content_kinds are written with an
      # `expr` attribute, so the compiler records the attribute value's
      # span and value_location is present on every row here. A chart
      # producing a nil value_location is not exercised in this file - the
      # location_object_or_nil(nil) branch is already covered by
      # cond_location in the transitions table.
      for row <- message.payload["data"] do
        assert %{
                 "start_line" => _,
                 "start_column" => _,
                 "start_offset" => _,
                 "end_line" => _,
                 "end_column" => _,
                 "end_offset" => _
               } = row["value_location"]
      end
    end

    test "never carries value" do
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      for row <- message.payload["data"] do
        refute Map.has_key?(row, "value")
      end
    end

    test "value_location spans the written value for expr and src, and falls back to the element's own span otherwise" do
      # Pins the fallback `docs/wire-format.md`'s `data` table documents: an
      # element written with neither `expr` nor `src` has no distinct value
      # span, so `value_location` equals `location` and a consumer slicing
      # `source` at it gets the whole element rather than a value. The four
      # rows below are the four value sources `Machine.Data` distinguishes.
      source = """
      <?xml version="1.0" encoding="UTF-8"?>
      <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
          <datamodel>
              <data id="fromExpr" expr="1 + 1" />
              <data id="fromSrc" src="http://example.com/d.json" />
              <data id="fromChild">42</data>
              <data id="bare" />
          </datamodel>
          <state id="a" />
      </scxml>
      """

      machine = compile!(source)
      {:ok, message} = Manifest.build(machine, "sess_1", source: source)

      rows = Map.new(message.payload["data"], &{&1["id"], &1})
      assert map_size(rows) == 4

      # Written value: value_location is a distinct, narrower span, and
      # slicing the source at it yields exactly the written value.
      assert slice(source, rows["fromExpr"]["value_location"]) == "1 + 1"
      assert slice(source, rows["fromSrc"]["value_location"]) == "http://example.com/d.json"

      for id <- ~w(fromExpr fromSrc) do
        refute rows[id]["value_location"] == rows[id]["location"]
      end

      # No written value: value_location falls back to the element's own
      # span. Equality with "location" is the signal the doc tells a
      # consumer to test before treating a slice as a value.
      for id <- ~w(fromChild bare) do
        assert rows[id]["value_location"] == rows[id]["location"]
        assert slice(source, rows[id]["value_location"]) =~ ~r/\A<data id="#{id}"/
      end
    end

    test "value_location is present on every row - the compiler has no nil clause" do
      # `Statifier.Machine.Data`'s type admits nil, but every
      # `build_data_value/2` clause upstream returns a location, so the
      # producer's put_present/3 branch is defensive rather than reachable.
      # The wire-format schema still documents the field as conditional, so
      # this asserts the observed behavior without binding the format to it.
      machine = compile!(@all_content_kinds)
      {:ok, message} = Manifest.build(machine, "sess_1")

      for row <- message.payload["data"] do
        assert Map.has_key?(row, "value_location")
      end
    end

    test ~s("data" lands between "contents" and "seq" in canonical byte order) do
      machine = compile!(@two_state)
      {:ok, message} = Manifest.build(machine, "sess_1")

      encoded = Json.encode_message(message)
      assert encoded =~ ~s("contents":[],"data":[],"seq":0)
    end
  end

  describe "build/3 - index round-trip" do
    test "every published index, t_index, c_index, and d_index resolves through Machine.at/2, transition/2, content/2, and data/2" do
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

      for row <- message.payload["data"] do
        resolved = Machine.data(machine, row["d_index"])
        assert resolved.id == row["id"]
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
               MapSet.new(~w(version states transitions contents data))

      {:ok, full} =
        Manifest.build(machine, "sess_1",
          source: @two_state,
          fixtures: %{"version" => 1},
          parent_session: "sess_parent",
          invokeid: "inv_1"
        )

      assert MapSet.new(Map.keys(full.payload)) ==
               MapSet.new(
                 ~w(version states transitions contents data source fixtures parent_session invokeid)
               )
    end
  end
end
