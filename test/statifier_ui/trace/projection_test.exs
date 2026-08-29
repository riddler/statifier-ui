defmodule StatifierUI.Trace.ProjectionTest do
  use ExUnit.Case, async: true

  doctest StatifierUI.Trace.Projection

  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Projection

  @redacted %{"$redacted" => true}

  defp message(type, payload), do: %Message{type: type, session: "s", seq: 1, payload: payload}

  defp deny_all, do: Projection.profile!("deny_all")

  defp project(type, payload, profile \\ nil) do
    profile = profile || deny_all()
    Projection.project(message(type, payload), profile).payload
  end

  describe "profile/2" do
    test "defaults deny both allowlists and retain source" do
      assert {:ok, profile} = Projection.profile("p")
      assert profile.name == "p"
      assert profile.allow_paths == []
      assert MapSet.to_list(profile.allow_positions) == []
      assert profile.allow_source == true
    end

    test "accepts string and integer path segments" do
      assert {:ok, profile} = Projection.profile("p", allow_paths: [["a", 0, "b"]])
      assert profile.allow_paths == [["a", 0, "b"]]
    end

    test "rejects a non-list allow_paths" do
      assert {:error, {:invalid_allow_paths, :nope}} =
               Projection.profile("p", allow_paths: :nope)
    end

    test "rejects a path that is not a list of segments" do
      assert {:error, {:invalid_allow_paths, _}} = Projection.profile("p", allow_paths: ["a"])
    end

    test "rejects an empty path, which would allow everything" do
      assert {:error, {:invalid_allow_paths, _}} = Projection.profile("p", allow_paths: [[]])
    end

    test "rejects a segment that is neither string nor integer" do
      assert {:error, {:invalid_allow_paths, _}} =
               Projection.profile("p", allow_paths: [[:atom]])
    end

    test "rejects a position outside the closed set" do
      assert {:error, {:invalid_allow_positions, [:nope]}} =
               Projection.profile("p", allow_positions: [:nope])
    end

    test "rejects a non-boolean allow_source" do
      assert {:error, {:invalid_allow_source, "yes"}} =
               Projection.profile("p", allow_source: "yes")
    end

    test "profile!/2 raises on an invalid allowlist" do
      assert_raise ArgumentError, ~r/invalid projection profile/, fn ->
        Projection.profile!("p", allow_positions: [:nope])
      end
    end
  end

  describe "the closed position set - located positions" do
    test "session.datamodel redacts values and keeps keys" do
      payload = project("session.datamodel", %{"datamodel" => %{"a" => 1, "b" => "x"}})

      assert payload == %{"datamodel" => %{"a" => @redacted, "b" => @redacted}}
    end

    test "effect.datamodel_change redacts both values and keeps the path" do
      payload =
        project("effect.datamodel_change", %{
          "location_path" => ["account", "balance"],
          "location_source" => "assign",
          "d_index" => 0,
          "new_value" => 100,
          "prior_value" => 50
        })

      assert payload["new_value"] == @redacted
      assert payload["prior_value"] == @redacted
      assert payload["location_path"] == ["account", "balance"]
      assert payload["location_source"] == "assign"
      assert payload["d_index"] == 0
    end
  end

  describe "the closed position set - unlocated positions" do
    test "effect.log redacts value and keeps label" do
      payload = project("effect.log", %{"label" => "note", "value" => 42})

      assert payload == %{"label" => "note", "value" => @redacted}
    end

    test "effect.invoke redacts params and content and keeps identity" do
      payload =
        project("effect.invoke", %{
          "invoke_id" => "i1",
          "src" => "child.scxml",
          "invoke_type" => "scxml",
          "params" => %{"a" => 1},
          "content" => "x"
        })

      assert payload["params"] == @redacted
      assert payload["content"] == @redacted
      assert payload["invoke_id"] == "i1"
      assert payload["src"] == "child.scxml"
      assert payload["invoke_type"] == "scxml"
    end

    test "the send family redacts data and keeps target and send_id" do
      for type <- ["effect.send", "effect.send_delayed"] do
        payload =
          project(type, %{
            "event" => "go",
            "send_id" => "s1",
            "target" => "#_internal",
            "data" => 1
          })

        assert payload["data"] == @redacted
        assert payload["send_id"] == "s1"
        assert payload["target"] == "#_internal"
        assert payload["event"] == "go"
      end
    end

    test "donedata is redacted on both carriers, configuration untouched" do
      for type <- ["trace.done", "effect.done"] do
        payload = project(type, %{"configuration" => [0, 1], "donedata" => %{"r" => 1}})

        assert payload == %{"configuration" => [0, 1], "donedata" => @redacted}
      end
    end

    test "event.data is redacted on every carrier, event name and type kept" do
      event = %{"name" => "go", "type" => "external", "data" => %{"a" => 1}}

      for type <- ["trace.event_dequeued", "trace.finalize_autoforward", "effect.autoforward"] do
        payload = project(type, %{"event" => event})

        assert payload["event"]["data"] == @redacted
        assert payload["event"]["name"] == "go"
        assert payload["event"]["type"] == "external"
      end
    end

    test "effect.budget_exhausted walks the pending list" do
      event = %{"name" => "go", "type" => "internal", "data" => 1}

      payload =
        project("effect.budget_exhausted", %{
          "budget" => 10,
          "configuration" => [0],
          "pending_internal_events" => [event, event]
        })

      assert Enum.map(payload["pending_internal_events"], & &1["data"]) == [@redacted, @redacted]
      assert Enum.map(payload["pending_internal_events"], & &1["name"]) == ["go", "go"]
      assert payload["budget"] == 10
    end
  end

  describe "replace, never omit, and never create" do
    test "an absent event key stays absent - the eventless-round signal" do
      payload = project("trace.transitions_selected", %{"t_indexes" => [0]})

      refute Map.has_key?(payload, "event")
      assert payload == %{"t_indexes" => [0]}
    end

    test "an absent prior_value stays absent - the first-write case" do
      payload =
        project("effect.datamodel_change", %{
          "location_path" => ["a"],
          "location_source" => "assign",
          "new_value" => 1
        })

      refute Map.has_key?(payload, "prior_value")
      assert payload["new_value"] == @redacted
    end

    test "an absent event data key stays absent" do
      payload = project("trace.event_dequeued", %{"event" => %{"name" => "go"}})

      refute Map.has_key?(payload["event"], "data")
    end

    test "an absent fixtures key stays absent" do
      payload = project("session.start", %{"version" => 1})

      refute Map.has_key?(payload, "fixtures")
    end

    test "a present null value is replaced, not left as null" do
      payload =
        project("effect.datamodel_change", %{
          "location_path" => ["a"],
          "location_source" => "assign",
          "new_value" => nil
        })

      assert payload["new_value"] == @redacted
    end

    test "a redacted position is never null, empty, or the undefined sentinel" do
      payload = project("effect.log", %{"value" => 1})

      refute payload["value"] == nil
      refute payload["value"] == %{}
      refute payload["value"] == %{"$undefined" => true}
      assert payload["value"] == @redacted
    end
  end

  describe "allow_positions" do
    test "naming a position allows it wholesale" do
      profile = Projection.profile!("p", allow_positions: [:log_value])
      payload = project("effect.log", %{"value" => %{"a" => 1}}, profile)

      assert payload["value"] == %{"a" => 1}
    end

    test "allowing one position does not allow another" do
      profile = Projection.profile!("p", allow_positions: [:log_value])
      payload = project("effect.send", %{"data" => 1}, profile)

      assert payload["data"] == @redacted
    end

    test "event_data covers every event carrier" do
      profile = Projection.profile!("p", allow_positions: [:event_data])
      event = %{"name" => "go", "data" => 7}

      for type <- ["trace.event_dequeued", "trace.finalize_autoforward", "effect.autoforward"] do
        assert project(type, %{"event" => event}, profile)["event"]["data"] == 7
      end
    end
  end

  describe "allow_paths - prefix matching" do
    test "an exactly matching prefix allows the write" do
      profile = Projection.profile!("p", allow_paths: [["account", "currency"]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["account", "currency"], "new_value" => "usd"},
          profile
        )

      assert payload["new_value"] == "usd"
    end

    test "a shorter prefix allows a deeper write - the whole subtree" do
      profile = Projection.profile!("p", allow_paths: [["account"]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["account", "currency"], "new_value" => "usd"},
          profile
        )

      assert payload["new_value"] == "usd"
    end

    test "an unrelated prefix redacts the write" do
      profile = Projection.profile!("p", allow_paths: [["account"]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["authorization", "amount_cents"], "new_value" => 1999},
          profile
        )

      assert payload["new_value"] == @redacted
    end

    test "a sibling of an allowed leaf is redacted" do
      profile = Projection.profile!("p", allow_paths: [["authorization", "status"]])

      allowed =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["authorization", "status"], "new_value" => "captured"},
          profile
        )

      withheld =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["authorization", "amount_cents"], "new_value" => 1999},
          profile
        )

      assert allowed["new_value"] == "captured"
      assert withheld["new_value"] == @redacted
    end

    test "integer segments match array indexes" do
      profile = Projection.profile!("p", allow_paths: [["transactions", 0, "status"]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["transactions", 0, "status"], "new_value" => "settled"},
          profile
        )

      assert payload["new_value"] == "settled"
    end
  end

  describe "allow_paths - the shallower write descends (ruling of 2026-08-29)" do
    setup do
      %{profile: Projection.profile!("p", allow_paths: [["authorization", "status"]])}
    end

    test "a shallower write is descended into, not allowed whole", %{profile: profile} do
      payload =
        project(
          "effect.datamodel_change",
          %{
            "location_path" => ["authorization"],
            "new_value" => %{"status" => "captured", "amount_cents" => 1999}
          },
          profile
        )

      assert payload["new_value"] == %{"status" => "captured", "amount_cents" => @redacted}
    end

    test "descent recurses through nested maps", %{profile: _profile} do
      profile = Projection.profile!("p", allow_paths: [["a", "b", "c"]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["a"], "new_value" => %{"b" => %{"c" => 1, "d" => 2}, "e" => 3}},
          profile
        )

      assert payload["new_value"] == %{"b" => %{"c" => 1, "d" => @redacted}, "e" => @redacted}
    end

    test "descent indexes into lists" do
      profile = Projection.profile!("p", allow_paths: [["items", 1]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["items"], "new_value" => ["a", "b", "c"]},
          profile
        )

      assert payload["new_value"] == [@redacted, "b", @redacted]
    end

    test "a scalar that cannot carry the allowed leaf redacts whole", %{profile: profile} do
      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["authorization"], "new_value" => "just-a-string"},
          profile
        )

      assert payload["new_value"] == @redacted
    end

    test "an already-matching prefix wins over one that would descend" do
      profile = Projection.profile!("p", allow_paths: [["a"], ["a", "b"]])

      payload =
        project(
          "effect.datamodel_change",
          %{"location_path" => ["a"], "new_value" => %{"b" => 1, "c" => 2}},
          profile
        )

      assert payload["new_value"] == %{"b" => 1, "c" => 2}
    end

    test "descent applies to session.datamodel snapshot values", %{profile: profile} do
      payload =
        project(
          "session.datamodel",
          %{
            "datamodel" => %{
              "authorization" => %{"status" => "pending", "amount_cents" => 1999},
              "account" => %{"currency" => "usd"}
            }
          },
          profile
        )

      assert payload["datamodel"]["authorization"] ==
               %{"status" => "pending", "amount_cents" => @redacted}

      assert payload["datamodel"]["account"] == @redacted
    end
  end

  describe "session.start" do
    test "carries the projection header naming mode and profile" do
      payload = project("session.start", %{"version" => 1}, Projection.profile!("end_user"))

      assert payload["projection"] == %{"mode" => "projected", "profile" => "end_user"}
    end

    test "redacts fixtures whole rather than descending" do
      profile = Projection.profile!("p", allow_paths: [["a"]])
      payload = project("session.start", %{"fixtures" => %{"a" => 1, "b" => 2}}, profile)

      assert payload["fixtures"] == @redacted
    end

    test "retains source by default" do
      payload = project("session.start", %{"source" => "<scxml/>"})

      assert payload["source"] == "<scxml/>"
    end

    test "redacts source under allow_source: false" do
      profile = Projection.profile!("p", allow_source: false)
      payload = project("session.start", %{"source" => "<scxml/>"}, profile)

      assert payload["source"] == @redacted
    end

    test "leaves the index tables untouched" do
      tables = %{
        "version" => 1,
        "states" => [%{"index" => 0, "id" => "a"}],
        "transitions" => [%{"t_index" => 0}],
        "contents" => [%{"c_index" => 0}],
        "data" => [%{"d_index" => 0, "id" => "x"}]
      }

      payload = project("session.start", tables)

      for key <- ~w(version states transitions contents data) do
        assert payload[key] == tables[key]
      end
    end
  end

  describe "session.terminated" do
    test "replaces reason whole, changing its JSON type" do
      payload = project("session.terminated", %{"reason" => ":normal"})

      assert payload == %{"reason" => @redacted}
    end
  end

  describe "session.unroutable recursion" do
    test "recurses into the wrapped effect by its kind" do
      payload =
        project("session.unroutable", %{
          "effect" => %{"kind" => "effect.log", "label" => "note", "value" => 42}
        })

      assert payload["effect"]["value"] == @redacted
      assert payload["effect"]["label"] == "note"
      assert payload["effect"]["kind"] == "effect.log"
    end

    test "recurses into a wrapped session.datamodel" do
      payload =
        project("session.unroutable", %{
          "effect" => %{"kind" => "session.datamodel", "datamodel" => %{"a" => 1}}
        })

      assert payload["effect"]["datamodel"] == %{"a" => @redacted}
    end

    test "a wrapper with no kind is left alone rather than guessed at" do
      payload = project("session.unroutable", %{"effect" => %{"value" => 1}})

      assert payload["effect"] == %{"value" => 1}
    end
  end

  describe "what is never projected" do
    test "the envelope is untouched" do
      profile = deny_all()

      projected =
        Projection.project(
          %Message{
            type: "effect.log",
            session: "sess_1",
            seq: 7,
            macrostep: 2,
            microstep: 3,
            round: 1,
            payload: %{"value" => 1}
          },
          profile
        )

      assert projected.type == "effect.log"
      assert projected.session == "sess_1"
      assert projected.seq == 7
      assert projected.macrostep == 2
      assert projected.microstep == 3
      assert projected.round == 1
    end

    test "session.halted's closed reason set is not a value position" do
      payload = project("session.halted", %{"reason" => "done"})

      assert payload == %{"reason" => "done"}
    end

    test "a type with no value position is returned untouched" do
      for {type, payload} <- [
            {"trace.exit_set", %{"indexes" => [1, 0]}},
            {"trace.entry_set", %{"indexes" => [0, 1]}},
            {"trace.macrostep_stable", %{"configuration" => [0]}},
            {"trace.content_executed", %{"owner" => %{"kind" => "onentry"}, "c_indexes" => [0]}},
            {"trace.invoke_pass", %{"state_indexes" => [0], "invoke_ids" => ["i1"]}},
            {"effect.cancel", %{"send_id" => "s1"}},
            {"effect.cancel_invoke", %{"invoke_id" => "i1", "state_index" => 0}}
          ] do
        assert project(type, payload) == payload
      end
    end
  end
end
