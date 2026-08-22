defmodule StatifierUI.EventInjectionTest do
  use ExUnit.Case, async: true

  alias StatifierUI.EventInjection
  alias StatifierUI.EventInjection.Entry
  alias StatifierUI.EventInjection.Palette
  alias StatifierUI.Fixtures

  describe "build/1 - free_form_only?" do
    test "nil yields free_form_only?: true and no entries" do
      assert {:ok, %EventInjection{free_form_only?: true} = pane} = EventInjection.build(nil)
      assert EventInjection.entries(pane) == []
      assert EventInjection.diagnostics(pane) == []
    end

    test "a bundle with no events yields free_form_only?: true" do
      assert {:ok, fixtures} = Fixtures.new()
      assert {:ok, %EventInjection{free_form_only?: true} = pane} = EventInjection.build(fixtures)
      assert EventInjection.entries(pane) == []
    end

    test "a bundle with at least one encodable event yields free_form_only?: false" do
      assert {:ok, fixtures} =
               Fixtures.new(events: %{"payment.success" => %{"amount" => 1999}})

      assert {:ok, %EventInjection{free_form_only?: false} = pane} =
               EventInjection.build(fixtures)

      assert [%Entry{name: "payment.success"}] = EventInjection.entries(pane)
    end

    test "a bundle whose only event payload is unencodable degrades to free_form_only?" do
      assert {:ok, fixtures} =
               Fixtures.new(events: %{"payment.broken" => {:not, :a, :value}})

      assert {:ok, %EventInjection{free_form_only?: true} = pane} =
               EventInjection.build(fixtures)

      assert EventInjection.entries(pane) == []
      assert [%{kind: :unencodable_event_payload}] = EventInjection.diagnostics(pane)
    end

    test "propagates Palette.build/1's error for invalid input" do
      assert {:error, {:invalid_fixtures, :not_a_bundle}} = EventInjection.build(:not_a_bundle)
    end
  end

  describe "entries/1 and diagnostics/1 - pass-through" do
    test "return the underlying palette's entries and diagnostics" do
      assert {:ok, fixtures} =
               Fixtures.new(
                 events: %{
                   "payment.success" => %{"amount" => 1999},
                   "payment.broken" => {:not, :a, :value}
                 }
               )

      assert {:ok, %Palette{entries: entries, diagnostics: diagnostics} = palette} =
               Palette.build(fixtures)

      pane = %EventInjection{palette: palette, free_form_only?: entries == []}

      assert EventInjection.entries(pane) == entries
      assert EventInjection.diagnostics(pane) == diagnostics
      assert [%Entry{name: "payment.success"}] = entries
      assert [%{kind: :unencodable_event_payload}] = diagnostics
    end
  end

  describe "send_draft/3 - refuses before it sends" do
    # A bare (non-GenServer) pid still receives a `GenServer.cast/2` as an
    # ordinary `{:"$gen_cast", _}` message - casting does not check that the
    # target is a running GenServer. A collector process that never reads its
    # mailbox is therefore proof, not just a plausible stand-in: if
    # `send_draft/3` ever cast before its build succeeded, this message queue
    # would be non-empty.
    setup do
      collector = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(collector, :kill) end)
      %{collector: collector}
    end

    test "a build failure is returned without ever casting to the server", %{
      collector: collector
    } do
      assert {:error, :blank_event_name} = EventInjection.send_draft(collector, "")
      assert {:messages, []} = Process.info(collector, :messages)
      assert Process.alive?(collector)
    end

    test "an invalid payload is also returned without sending", %{collector: collector} do
      assert {:error, {:invalid_json, _reason}} =
               EventInjection.send_draft(collector, "payment.success", "{not json")

      assert {:messages, []} = Process.info(collector, :messages)
    end
  end
end
