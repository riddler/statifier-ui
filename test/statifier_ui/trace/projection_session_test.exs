defmodule StatifierUI.Trace.ProjectionSessionTest do
  @moduledoc """
  End-to-end evidence for ADR-0012's placement decision: projection runs on
  the `StatifierUI.Trace.Subscriber` path, so a live session's whole stream -
  the manifest, the datamodel snapshot, every write, and the driven
  macrostep - reaches the buffer already projected.

  The practical test the placement is chosen to pass, asserted here directly:
  a projected stream may be buffered, rendered, encoded and persisted without
  any of those having held a datamodel value.
  """

  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Json
  alias StatifierUI.Trace.Projection
  alias StatifierUI.Trace.Subscriber

  # A credit-card authorization: one declared amount, one write that settles
  # it. Both the declared value and the written one are datamodel values, so
  # both must be gone from a projected stream.
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

  # Two effect.datamodel_change messages reach the buffer: the binding fold's
  # initial 1999 at seq 2, and the transition's assign of 2500 at seq 11.
  # Naming which one a test means matters, because the fold's write is
  # allowlisted by the same prefix as the assign's.
  defp assign_write(messages) do
    messages |> Enum.filter(&(&1.type == "effect.datamodel_change")) |> List.last()
  end

  defp run(subscriber_opts) do
    machine = SessionCase.compile!(@chart)
    {sub, session} = SessionCase.start_early!(machine, "sess_projection", subscriber_opts)
    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, 8)
    {sub, Subscriber.messages(sub)}
  end

  describe "a projected session" do
    setup do
      profile = Projection.profile!("end_user_run_history")
      {sub, messages} = run(projection: profile)
      {_full_sub, full_messages} = run([])

      %{sub: sub, messages: messages, full_messages: full_messages}
    end

    test "the declared and written amounts appear in a full stream", %{
      full_messages: full_messages
    } do
      # The positive control. Without it, the projected assertions below
      # would pass just as well against a chart that never carried a value.
      encoded = Json.encode_lines(full_messages)

      assert encoded =~ "1999"
      assert encoded =~ "2500"
    end

    test "no datamodel value survives into the encoded stream", %{messages: messages} do
      encoded = Json.encode_lines(messages)

      refute encoded =~ "1999"
      refute encoded =~ "2500"
      assert encoded =~ "$redacted"
    end

    test "session.start carries the projection header", %{messages: messages} do
      assert %{type: "session.start", payload: payload} = Enum.at(messages, 0)

      assert payload["projection"] == %{
               "mode" => "projected",
               "profile" => "end_user_run_history"
             }
    end

    test "structure, ordering and outcome are preserved", %{
      messages: messages,
      full_messages: full_messages
    } do
      strip = fn list -> Enum.map(list, &{&1.type, &1.seq, &1.macrostep, &1.round}) end

      assert strip.(messages) == strip.(full_messages)
    end

    test "the datamodel write keeps its location and loses its values", %{messages: messages} do
      write = assign_write(messages)

      assert write.payload["location_path"] == ["amount_cents"]
      assert write.payload["new_value"] == %{"$redacted" => true}
      assert write.payload["prior_value"] == %{"$redacted" => true}
      assert write.payload["owner"] == %{"kind" => "transition", "t_index" => 0}
    end

    test "effect.log keeps its label and loses its value", %{messages: messages} do
      log = Enum.find(messages, &(&1.type == "effect.log"))

      assert log.payload["label"] == "audit"
      assert log.payload["value"] == %{"$redacted" => true}
    end

    test "stats surfaces the mode and the profile name", %{sub: sub} do
      assert Subscriber.stats(sub).projection == %{
               mode: "projected",
               profile: "end_user_run_history"
             }
    end
  end

  describe "the default is unchanged" do
    test "an unprojected stream carries no projection key and no sentinel" do
      {sub, messages} = run([])
      encoded = Json.encode_lines(messages)

      refute encoded =~ "$redacted"
      # The bare word also occurs inside the session id, so this matches the
      # JSON key rather than the substring.
      refute encoded =~ ~s("projection":)
      assert encoded =~ "1999"
      assert Subscriber.stats(sub).projection == nil
    end
  end

  describe "an allowlisted profile" do
    test "lets the allowed leaf through and withholds the rest" do
      profile = Projection.profile!("audit", allow_paths: [["amount_cents"]])
      {_sub, messages} = run(projection: profile)

      write = assign_write(messages)
      log = Enum.find(messages, &(&1.type == "effect.log"))

      assert write.payload["new_value"] == 2500
      assert log.payload["value"] == %{"$redacted" => true}
    end
  end
end
