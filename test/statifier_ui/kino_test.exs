defmodule StatifierUI.KinoTest do
  # `configure_livebook_bridge` swaps this process's group leader, so these
  # tests stay out of the async pool.
  use ExUnit.Case, async: false

  import Kino.Test

  alias Statifier.Session
  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Bundle
  alias StatifierUI.Test.Support.Trace.SessionCase
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
            "needs_review" => %{
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
end
