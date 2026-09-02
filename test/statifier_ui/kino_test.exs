defmodule StatifierUI.KinoTest do
  # `configure_livebook_bridge` swaps this process's group leader, so these
  # tests stay out of the async pool.
  use ExUnit.Case, async: false

  import Kino.Test

  alias Statifier.Session
  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Bundle
  alias StatifierUI.Kino.Updater
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Capture
  alias StatifierUI.Trace.Subscriber

  setup :configure_livebook_bridge

  @two_state """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <state id="a">
          <transition event="go" target="b"/>
      </state>
      <state id="b"/>
  </scxml>
  """

  test "inspect/3 composes a layout over a recorded session, palette included" do
    machine = SessionCase.compile!(@two_state)

    {:ok, session} =
      Session.start_link(machine, trace: true, record: true, session_id: "sess_kino_smoke")

    {:ok, fixtures} = Fixtures.new(events: %{"go" => %{"note" => "demo"}})

    layout = StatifierUI.Kino.inspect(session, fixtures, source: @two_state)
    assert %Kino.Layout{} = layout

    # The widget must not have subscribed live-only: the session records,
    # so a second subscriber catching up now sees the same whole stream the
    # widget's own subscriber folded in - the initialize burst included.
    sub = SessionCase.attach_catch_up!(machine, session)
    messages = Subscriber.messages(sub)
    assert Enum.any?(messages, &(&1.type == "session.start"))
    assert Enum.any?(messages, &(&1.payload["indexes"] == [0, 1]))

    # Driving the session after assembly must not crash anything the
    # widget started; the updater re-renders on its coalesced tick.
    Session.send_event(session, "go")
    SessionCase.wait_for_seq(sub, 15)
  end

  test "inspect/3 without fixtures renders no palette and still assembles" do
    machine = SessionCase.compile!(@two_state)

    {:ok, session} =
      Session.start_link(machine, trace: true, record: true, session_id: "sess_kino_bare")

    assert %Kino.Layout{} = StatifierUI.Kino.inspect(session)
  end

  test "inspect/3 on an unrecorded session still assembles (live-only)" do
    machine = SessionCase.compile!(@two_state)
    {:ok, session} = Session.start_link(machine, trace: true, session_id: "sess_kino_lo")

    assert %Kino.Layout{} = StatifierUI.Kino.inspect(session)
  end

  describe "the scrubber's updater (sui-3gg)" do
    setup do
      machine = SessionCase.compile!(@two_state)
      {sub, session} = SessionCase.start_early!(machine, "sess_kino_scrub")
      Session.send_event(session, "go")
      SessionCase.wait_for_seq(sub, 15)

      frames =
        Map.new([:status, :note, :diagram, :datamodel, :log], fn key ->
          {key, Kino.Frame.new(placeholder: false)}
        end)

      {:ok, updater} =
        Updater.start_link(
          sub: sub,
          machine: machine,
          frames: frames,
          initial_configuration: [0, 1]
        )

      %{updater: updater}
    end

    test "starts live and pins the newest macrostep on prev", %{updater: updater} do
      assert :sys.get_state(updater).selection == :live

      :ok = Updater.scrub(updater, :prev)
      assert :sys.get_state(updater).selection == {:macrostep, 2}
    end

    test "first, prev, next and live walk the log and come back", %{updater: updater} do
      :ok = Updater.scrub(updater, :first)
      assert :sys.get_state(updater).selection == {:macrostep, 1}

      :ok = Updater.scrub(updater, :next)
      assert :sys.get_state(updater).selection == {:macrostep, 2}

      # Past the newest macrostep the scrubber follows the tip again.
      :ok = Updater.scrub(updater, :next)
      assert :sys.get_state(updater).selection == :live

      :ok = Updater.scrub(updater, :first)
      :ok = Updater.scrub(updater, :live)
      assert :sys.get_state(updater).selection == :live
    end

    test "a scrubbed updater keeps rendering on later messages", %{updater: updater} do
      :ok = Updater.scrub(updater, :first)
      :ok = Updater.refresh(updater)

      assert Process.alive?(updater)
      assert :sys.get_state(updater).selection == {:macrostep, 1}
    end
  end

  describe "truth_table/2" do
    setup do
      {:ok, fixtures} =
        Fixtures.new(
          datasets: %{
            "variant-b-complete" => %{"signup" => %{"steps_completed" => 4, "variant" => "B"}},
            "variant-a-early" => %{"signup" => %{"steps_completed" => 1, "variant" => "A"}},
            "sparse" => %{"signup" => %{"variant" => "B"}}
          },
          expressions: %{
            "is-complete-variant-b" => %{
              "source" => "signup.steps_completed >= 3 and signup.variant == 'B'"
            }
          }
        )

      %{fixtures: fixtures}
    end

    test "renders the matrix as Markdown with no session and no chart", %{fixtures: fixtures} do
      assert %Kino.Markdown{text: text} = StatifierUI.Kino.truth_table(fixtures)

      assert text =~ "# Truth table"
      assert text =~ "| dataset | is-complete-variant-b |"
      assert text =~ "| variant-b-complete | **true** |"
      assert text =~ "| variant-a-early | false |"
      assert text =~ "| sparse | _undefined_ |"
    end

    test "splits its options between the builder and the renderer", %{fixtures: fixtures} do
      assert %Kino.Markdown{text: text} =
               StatifierUI.Kino.truth_table(fixtures,
                 datasets: ["variant-a-early"],
                 title: nil,
                 legend: false,
                 sources: false
               )

      refute text =~ "# Truth table"
      refute text =~ "Expressions:"
      refute text =~ "| variant-b-complete |"
      refute text =~ "| sparse |"
      assert text =~ "| variant-a-early | false |"
    end
  end

  describe "test_panel/2 and palette_panel/2" do
    setup do
      {:ok, bundle} =
        Bundle.load("myapp.authorize", %{
          datasets: %{
            "within-budget" => %{
              "transaction" => %{"amount" => 14},
              "account" => %{"budget_remaining" => 500}
            }
          },
          expressions: %{
            "exceeds-budget" => %{
              "source" => "transaction.amount > account.budget_remaining",
              "expect" => %{"within-budget" => false}
            }
          }
        })

      %{bundle: bundle}
    end

    test "test_panel/2 renders one fragment's panel as Markdown", %{bundle: bundle} do
      assert %Kino.Markdown{text: text} = StatifierUI.Kino.test_panel(bundle)

      assert text =~ "# myapp.authorize"
      assert text =~ "## Expectations"
      assert text =~ "1 matched, 0 mismatched, 0 errored,"
    end

    test "test_panel/2 forwards its options to the renderer", %{bundle: bundle} do
      assert %Kino.Markdown{text: text} =
               StatifierUI.Kino.test_panel(bundle, heading: nil, expectations: false)

      refute text =~ "# myapp.authorize"
      refute text =~ "## Expectations"
    end

    test "palette_panel/2 renders every bundle a discovery found", %{bundle: bundle} do
      discovery = %{bundles: [bundle], without: ["myapp.plain"], errors: []}

      assert %Kino.Markdown{text: text} = StatifierUI.Kino.palette_panel(discovery)

      assert text =~ "# myapp.authorize"
      refute text =~ "myapp.plain"
    end
  end

  describe "inspect_trace/3" do
    setup do
      machine = SessionCase.compile!(@two_state)

      {:ok, session} =
        Session.start_link(machine, trace: true, record: true, session_id: "sess_kino_reload")

      Session.send_event(session, "go")
      SessionCase.wait_for_macrostep(session, 2)

      {:ok, messages} = Capture.record(session, machine, source: @two_state)

      %{machine: machine, messages: messages}
    end

    test "composes a static layout over a message list", %{machine: machine, messages: messages} do
      assert %Kino.Layout{} =
               StatifierUI.Kino.inspect_trace(messages, nil, machine: machine)
    end

    test "reads a saved file through Capture.load/1", %{messages: messages} do
      path =
        Path.join(System.tmp_dir!(), "sui-pb2-kino-#{System.unique_integer([:positive])}.jsonl")

      on_exit(fn -> File.rm(path) end)
      :ok = Capture.save(messages, path)

      assert %Kino.Layout{} = StatifierUI.Kino.inspect_trace(path)
    end

    test "recompiles the machine from the source the trace carries", %{messages: messages} do
      # No `machine:` option, and the file is the only artefact: this is the
      # round trip the wire format exists to make possible.
      assert %Kino.Layout{} = StatifierUI.Kino.inspect_trace(messages)
    end

    test "says so rather than drawing when there is no chart", %{machine: machine} do
      {:ok, session} =
        Session.start_link(machine, trace: true, record: true, session_id: "sess_kino_nosource")

      {:ok, sourceless} = Capture.record(session, machine)

      assert %Kino.Markdown{text: text} = StatifierUI.Kino.inspect_trace(sourceless)
      assert text =~ "No chart to draw"
      assert text =~ "`:source`"
    end

    test "reports an unreadable path rather than raising" do
      assert %Kino.Markdown{text: text} =
               StatifierUI.Kino.inspect_trace(
                 Path.join(System.tmp_dir!(), "sui-pb2-no-such-file.jsonl")
               )

      assert text =~ "Could not read"
      assert text =~ ":enoent"
    end
  end
end
