defmodule StatifierUI.EventLog.LabelsTest do
  use ExUnit.Case, async: true

  alias StatifierUI.EventLog
  alias StatifierUI.EventLog.Labels
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Manifest

  # A superset of the two-state chart at `docs/wire-format.md:757-763`: kept
  # to one `<state id="a">`/`<state id="b">` pair but adds the shapes this
  # module's own resolvers need that the worked example does not exercise -
  # a `<data>` element, a content node, an anonymous state, and transitions
  # covering the multi-token, eventless, and targetless cases.
  @chart """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0" datamodel="predicator">
      <datamodel>
          <data id="x" expr="0" />
      </datamodel>
      <state id="a">
          <onentry>
              <raise event="ping" />
          </onentry>
          <transition event="done.state.s1 go" target="b" />
          <transition cond="1 == 1" target="b" />
          <transition event="stay" />
      </state>
      <state id="b" />
      <state />
  </scxml>
  """

  setup do
    machine = SessionCase.compile!(@chart)
    {:ok, message} = Manifest.build(machine, "sess_1")
    labels = Labels.from_manifest(message)

    payload = message.payload
    state_a = Enum.find(payload["states"], &(&1["id"] == "a"))
    state_b = Enum.find(payload["states"], &(&1["id"] == "b"))
    anonymous = Enum.find(payload["states"], &(&1["kind"] == "state" and is_nil(&1["id"])))
    data_x = Enum.find(payload["data"], &(&1["id"] == "x"))
    raise_content = Enum.find(payload["contents"], &(&1["kind"] == "raise"))

    multi_token =
      Enum.find(
        payload["transitions"],
        &(&1["source"] == state_a["index"] and &1["events"] != [])
      )

    eventless =
      Enum.find(
        payload["transitions"],
        &(&1["source"] == state_a["index"] and &1["events"] == [])
      )

    targetless =
      Enum.find(payload["transitions"], &(&1["events"] == [["stay"]]))

    %{
      message: message,
      labels: labels,
      state_a: state_a,
      state_b: state_b,
      anonymous: anonymous,
      data_x: data_x,
      raise_content: raise_content,
      multi_token: multi_token,
      eventless: eventless,
      targetless: targetless
    }
  end

  describe "state/2" do
    test "resolves a named state to its id", %{labels: labels, state_a: state_a} do
      assert Labels.state(labels, state_a["index"]) == "a"
    end

    test "resolves the root scxml state to <scxml>", %{labels: labels} do
      assert Labels.state(labels, 0) == "<scxml>"
    end

    test "resolves an anonymous state to a bare index", %{labels: labels, anonymous: anonymous} do
      assert Labels.state(labels, anonymous["index"]) == "##{anonymous["index"]}"
    end

    test "resolves an out-of-range index to a bare index", %{labels: labels} do
      assert Labels.state(labels, 999) == "#999"
    end
  end

  describe "states/2" do
    test "resolves each index in list order, joined with a comma", %{
      labels: labels,
      state_a: state_a,
      state_b: state_b
    } do
      assert Labels.states(labels, [state_b["index"], state_a["index"]]) == "b, a"
    end
  end

  describe "transition/2" do
    test "renders a multi-token dot-split descriptor alongside a single-token one", %{
      labels: labels,
      multi_token: multi_token
    } do
      assert multi_token["events"] == [["done", "state", "s1"], ["go"]]
      assert Labels.transition(labels, multi_token["t_index"]) == "done.state.s1 go: a -> b"
    end

    test "renders an eventless transition", %{labels: labels, eventless: eventless} do
      assert Labels.transition(labels, eventless["t_index"]) == "(eventless): a -> b"
    end

    test "renders a targetless transition", %{labels: labels, targetless: targetless} do
      assert Labels.transition(labels, targetless["t_index"]) == "stay: a -> (targetless)"
    end

    test "resolves an out-of-range index to a bare index", %{labels: labels} do
      assert Labels.transition(labels, 999) == "#999"
    end
  end

  describe "content/2" do
    test "renders the content node's kind and start line", %{
      labels: labels,
      raise_content: raise_content
    } do
      expected =
        "raise@#{raise_content["location"]["start_line"]}:#{raise_content["location"]["start_column"]}"

      assert Labels.content(labels, raise_content["c_index"]) == expected
    end

    test "resolves an out-of-range index to a bare index", %{labels: labels} do
      assert Labels.content(labels, 999) == "#999"
    end
  end

  describe "data/2" do
    test "resolves a <data> element to its id", %{labels: labels, data_x: data_x} do
      assert Labels.data(labels, data_x["d_index"]) == "x"
    end

    test "resolves an out-of-range index to a bare index", %{labels: labels} do
      assert Labels.data(labels, 999) == "#999"
    end
  end

  describe "origin/2 - the eight kinds" do
    test "content delegates to owner and content", %{
      labels: labels,
      raise_content: raise_content,
      state_a: state_a
    } do
      origin = %{
        "kind" => "content",
        "c_index" => raise_content["c_index"],
        "owner" => %{"kind" => "onentry", "state_index" => state_a["index"], "ordinal" => 0}
      }

      expected = "a onentry#0: #{Labels.content(labels, raise_content["c_index"])}"
      assert Labels.origin(labels, origin) == expected
    end

    test "state delegates to state/2", %{labels: labels, state_b: state_b} do
      origin = %{"kind" => "state", "state_index" => state_b["index"]}
      assert Labels.origin(labels, origin) == "b"
    end

    test "transition delegates to transition/2", %{labels: labels, multi_token: multi_token} do
      origin = %{"kind" => "transition", "t_index" => multi_token["t_index"]}
      assert Labels.origin(labels, origin) == "done.state.s1 go: a -> b"
    end

    test "data delegates to data/2", %{labels: labels, data_x: data_x} do
      origin = %{"kind" => "data", "d_index" => data_x["d_index"]}
      assert Labels.origin(labels, origin) == "x"
    end

    test "donedata_param names the state and the param index", %{labels: labels, state_b: state_b} do
      origin = %{
        "kind" => "donedata_param",
        "state_index" => state_b["index"],
        "param_index" => 0
      }

      assert Labels.origin(labels, origin) == "b donedata param 0"
    end

    test "global_script delegates to content/2", %{labels: labels, raise_content: raise_content} do
      origin = %{"kind" => "global_script", "index" => raise_content["c_index"]}
      assert Labels.origin(labels, origin) == Labels.content(labels, raise_content["c_index"])
    end

    test "invoke names the state and the invoke index", %{labels: labels, state_a: state_a} do
      origin = %{"kind" => "invoke", "state_index" => state_a["index"], "invoke_index" => 0}
      assert Labels.origin(labels, origin) == "a invoke#0"
    end

    test "finalize names the state and the invoke index", %{labels: labels, state_a: state_a} do
      origin = %{"kind" => "finalize", "state_index" => state_a["index"], "invoke_index" => 0}
      assert Labels.origin(labels, origin) == "a invoke#0 finalize"
    end

    test "an unrecognized kind renders the kind string itself", %{labels: labels} do
      origin = %{"kind" => "mystery_kind"}
      assert Labels.origin(labels, origin) == "mystery_kind"
    end
  end

  describe "owner/2 - the five kinds" do
    test "onentry names the state and the ordinal", %{labels: labels, state_a: state_a} do
      owner = %{"kind" => "onentry", "state_index" => state_a["index"], "ordinal" => 0}
      assert Labels.owner(labels, owner) == "a onentry#0"
    end

    test "onexit names the state and the ordinal", %{labels: labels, state_a: state_a} do
      owner = %{"kind" => "onexit", "state_index" => state_a["index"], "ordinal" => 1}
      assert Labels.owner(labels, owner) == "a onexit#1"
    end

    test "transition delegates to transition/2", %{labels: labels, multi_token: multi_token} do
      owner = %{"kind" => "transition", "t_index" => multi_token["t_index"]}
      assert Labels.owner(labels, owner) == "done.state.s1 go: a -> b"
    end

    test "finalize names the state and the invoke index", %{labels: labels, state_a: state_a} do
      owner = %{"kind" => "finalize", "state_index" => state_a["index"], "invoke_index" => 2}
      assert Labels.owner(labels, owner) == "a invoke#2 finalize"
    end

    test "global_script delegates to content/2", %{labels: labels, raise_content: raise_content} do
      owner = %{"kind" => "global_script", "index" => raise_content["c_index"]}
      assert Labels.owner(labels, owner) == Labels.content(labels, raise_content["c_index"])
    end

    test "an unrecognized kind renders the kind string itself", %{labels: labels} do
      owner = %{"kind" => "mystery_kind"}
      assert Labels.owner(labels, owner) == "mystery_kind"
    end
  end

  describe "from_manifest/1 and from_log/1" do
    test "from_manifest/1 builds a t() a real manifest resolves through", %{
      message: message,
      state_a: state_a
    } do
      labels = Labels.from_manifest(message)
      assert Labels.state(labels, state_a["index"]) == "a"
    end

    test "from_log/1 finds the first session.start and delegates to from_manifest/1", %{
      message: message,
      state_a: state_a
    } do
      {:ok, log} = EventLog.build([message])
      labels = Labels.from_log(log)
      assert Labels.state(labels, state_a["index"]) == "a"
    end

    test "from_log/1 returns empty/0 when the log carries no session.start" do
      labels = Labels.from_log(%EventLog{})
      assert labels == Labels.empty()
    end
  end

  describe "empty/0" do
    test "every index resolver renders a bare index with no manifest at all" do
      labels = Labels.empty()

      assert Labels.state(labels, 3) == "#3"
      assert Labels.transition(labels, 3) == "#3"
      assert Labels.content(labels, 3) == "#3"
      assert Labels.data(labels, 3) == "#3"
    end
  end
end
