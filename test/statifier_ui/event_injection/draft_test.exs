defmodule StatifierUI.EventInjection.DraftTest do
  use ExUnit.Case, async: true

  alias Statifier.Event
  alias StatifierUI.EventInjection.Draft

  describe "build/2 - payload spelling" do
    test "no payload text means no data (:undefined)" do
      assert {:ok, %Event{name: "payment.success", type: :external, cause: nil, data: :undefined}} =
               Draft.build("payment.success")
    end

    test "blank payload text means no data (:undefined)" do
      assert {:ok, %Event{data: :undefined}} = Draft.build("payment.success", "   ")
    end

    test "\"null\" payload text means data present and null" do
      assert {:ok, %Event{data: nil}} = Draft.build("payment.success", "null")
    end

    test "\"{}\" payload text means data present and empty" do
      assert {:ok, %Event{data: %{}}} = Draft.build("payment.success", "{}")
    end

    test "an object payload with nested values decodes fully" do
      payload = ~s({"amount": 1999, "meta": {"currency": "usd"}})

      assert {:ok, %Event{data: %{"amount" => 1999, "meta" => %{"currency" => "usd"}}}} =
               Draft.build("payment.success", payload)
    end

    test "the $undefined tag decodes to the sentinel" do
      assert {:ok, %Event{data: :undefined}} =
               Draft.build("payment.success", ~s({"$undefined": true}))
    end

    test "the $date tag decodes to a Date" do
      assert {:ok, %Event{data: ~D[2026-08-22]}} =
               Draft.build("payment.success", ~s({"$date": "2026-08-22"}))
    end
  end

  describe "build/2 - payload errors" do
    test "malformed JSON is rejected as invalid_json" do
      assert {:error, {:invalid_json, _reason}} = Draft.build("payment.success", "{not json")
    end

    test "an unknown $tag is rejected as invalid_payload" do
      assert {:error, {:invalid_payload, {:unknown_tag, "$bogus"}}} =
               Draft.build("payment.success", ~s({"$bogus": true}))
    end
  end

  describe "build/2 - name validation" do
    test "a blank name is rejected" do
      assert {:error, :blank_event_name} = Draft.build("")
    end

    test "an all-whitespace name is rejected as blank after trimming" do
      assert {:error, :blank_event_name} = Draft.build("   ")
    end

    test "a name containing whitespace is rejected" do
      assert {:error, {:invalid_event_name, "payment success"}} =
               Draft.build("payment success")
    end

    test "a non-binary name is rejected" do
      assert {:error, {:invalid_event_name, :payment_success}} = Draft.build(:payment_success)
    end

    test "surrounding whitespace on an otherwise valid name is trimmed" do
      assert {:ok, %Event{name: "payment.success"}} = Draft.build("  payment.success  ")
    end

    test "an unmatched but well-formed name is accepted" do
      assert {:ok, %Event{name: "no.such.transition", type: :external, cause: nil}} =
               Draft.build("no.such.transition")
    end
  end
end
