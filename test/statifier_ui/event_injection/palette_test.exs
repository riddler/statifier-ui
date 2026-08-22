defmodule StatifierUI.EventInjection.PaletteTest do
  use ExUnit.Case, async: true

  alias StatifierUI.EventInjection.Entry
  alias StatifierUI.EventInjection.Palette
  alias StatifierUI.Fixtures
  alias StatifierUI.Test.Support.Fixtures.PaymentSource

  describe "build/1 - degraded mode" do
    test "nil yields an empty palette with no diagnostics" do
      assert {:ok, %Palette{entries: [], diagnostics: []}} = Palette.build(nil)
    end

    test "a bundle with no events yields an empty palette" do
      assert {:ok, fixtures} = Fixtures.new()
      assert {:ok, %Palette{entries: [], diagnostics: []}} = Palette.build(fixtures)
    end
  end

  describe "build/1 - entries" do
    test "covers a map, nil, :undefined, a Date, and a duration payload" do
      assert {:ok, fixtures} =
               Fixtures.new(
                 events: %{
                   "payment.success" => %{"amount" => 1999},
                   "payment.nulled" => nil,
                   "payment.pending" => :undefined,
                   "payment.scheduled" => ~D[2026-08-22],
                   "payment.delayed" => %{seconds: 30}
                 }
               )

      assert {:ok, %Palette{entries: entries, diagnostics: []}} = Palette.build(fixtures)

      assert [
               %Entry{name: "payment.delayed"},
               %Entry{name: "payment.nulled", payload: nil, payload_text: "null"},
               %Entry{name: "payment.pending", payload: :undefined, payload_text: ""},
               %Entry{name: "payment.scheduled"},
               %Entry{name: "payment.success"}
             ] = entries

      assert Palette.names(%Palette{entries: entries}) == [
               "payment.delayed",
               "payment.nulled",
               "payment.pending",
               "payment.scheduled",
               "payment.success"
             ]

      assert {:ok, %Entry{payload: %{"amount" => 1999}, payload_text: ~s({"amount":1999})}} =
               Palette.entry(%Palette{entries: entries}, "payment.success")

      assert {:ok, %Entry{payload: ~D[2026-08-22], payload_text: ~s({"$date":"2026-08-22"})}} =
               Palette.entry(%Palette{entries: entries}, "payment.scheduled")

      assert {:ok, %Entry{payload: %{seconds: 30}} = delayed} =
               Palette.entry(%Palette{entries: entries}, "payment.delayed")

      assert delayed.payload_text ==
               ~s({"$duration":{"days":0,"hours":0,"milliseconds":0,"minutes":0,"months":0,"seconds":30,"weeks":0,"years":0}})
    end

    test "payload_text has canonical (sorted) object keys regardless of input key order" do
      assert {:ok, fixtures} =
               Fixtures.new(
                 events: %{"payment.success" => %{"currency" => "USD", "amount" => 1999}}
               )

      assert {:ok, %Palette{entries: [entry]}} = Palette.build(fixtures)
      assert entry.payload_text == ~s({"amount":1999,"currency":"USD"})
    end

    test "an unencodable payload becomes a diagnostic without taking the palette down" do
      assert {:ok, fixtures} =
               Fixtures.new(
                 events: %{
                   "payment.success" => %{"amount" => 1999},
                   "payment.broken" => {:not, :a, :value}
                 }
               )

      assert {:ok, %Palette{entries: entries, diagnostics: diagnostics}} = Palette.build(fixtures)

      assert [%Entry{name: "payment.success"}] = entries

      assert [
               %{
                 kind: :unencodable_event_payload,
                 path: ["events", "payment.broken"],
                 source: nil
               }
             ] = diagnostics
    end

    test "atom-keyed payloads keep atoms in payload but round-trip to string keys in payload_text" do
      assert {:ok, fixtures} =
               Fixtures.new(events: %{"payment.success" => %{amount: 1999}})

      assert {:ok, %Palette{entries: [entry]}} = Palette.build(fixtures)
      assert entry.payload == %{amount: 1999}
      assert entry.payload_text == ~s({"amount":1999})
    end
  end

  describe "build/1 - invalid input" do
    test "anything other than a Fixtures struct or nil is rejected" do
      assert {:error, {:invalid_fixtures, :not_a_bundle}} = Palette.build(:not_a_bundle)
    end
  end

  describe "build/1 - from a behaviour source" do
    test "builds a palette from test/support/fixtures/payment_source.ex" do
      assert {:ok, fixtures} = Fixtures.from_source(PaymentSource)
      assert {:ok, %Palette{entries: entries, diagnostics: []}} = Palette.build(fixtures)

      assert [
               %Entry{
                 name: "payment.success",
                 payload: %{"amount" => 1999, "currency" => "USD"},
                 payload_text: ~s({"amount":1999,"currency":"USD"})
               }
             ] = entries
    end
  end
end
