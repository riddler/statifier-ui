defmodule StatifierUI.ValueTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Value

  describe "decode/1 - JSON-native values" do
    test "booleans, integers, floats, and strings map to themselves" do
      assert Value.decode(true) == {:ok, true}
      assert Value.decode(1999) == {:ok, 1999}
      assert Value.decode(19.99) == {:ok, 19.99}
      assert Value.decode("gold") == {:ok, "gold"}
    end

    test "JSON null decodes to nil, not :undefined" do
      assert Value.decode(nil) == {:ok, nil}
    end

    test "recurses through lists" do
      assert Value.decode([1, "a", nil]) == {:ok, [1, "a", nil]}
    end

    test "recurses through map values" do
      assert Value.decode(%{"amount" => 1999, "nested" => %{"currency" => "USD"}}) ==
               {:ok, %{"amount" => 1999, "nested" => %{"currency" => "USD"}}}
    end
  end

  describe "decode/1 - tagged forms" do
    test "decodes $undefined to the :undefined sentinel" do
      assert Value.decode(%{"$undefined" => true}) == {:ok, :undefined}
    end

    test "decodes $date to a Date" do
      assert Value.decode(%{"$date" => "2026-08-16"}) == {:ok, ~D[2026-08-16]}
    end

    test "decodes $datetime to a DateTime" do
      assert Value.decode(%{"$datetime" => "2026-08-16T10:30:00Z"}) ==
               {:ok, ~U[2026-08-16 10:30:00Z]}
    end

    test "decodes $duration to a bare map with all eight unit keys" do
      assert Value.decode(%{"$duration" => %{"days" => 3, "hours" => 8}}) ==
               {:ok,
                %{
                  years: 0,
                  months: 0,
                  weeks: 0,
                  days: 3,
                  hours: 8,
                  minutes: 0,
                  seconds: 0,
                  milliseconds: 0
                }}
    end

    test "decodes a tagged value nested inside a list" do
      assert Value.decode([%{"$date" => "2026-08-16"}]) == {:ok, [~D[2026-08-16]]}
    end
  end

  describe "decode/1 - reserved shape enforcement" do
    test "rejects an unrecognized $-prefixed one-key object" do
      assert {:error, {:unknown_tag, "$bogus"}} = Value.decode(%{"$bogus" => true})
    end

    test "treats a multi-key object containing $date as an ordinary host map" do
      assert Value.decode(%{"$date" => "2026-08-16", "other" => 1}) ==
               {:ok, %{"$date" => "2026-08-16", "other" => 1}}
    end
  end

  describe "decode/1 - error propagation" do
    test "propagates a malformed ISO 8601 date as an error value" do
      assert {:error, _reason} = Value.decode(%{"$date" => "not-a-date"})
    end

    test "propagates a malformed ISO 8601 datetime as an error value" do
      assert {:error, _reason} = Value.decode(%{"$datetime" => "not-a-datetime"})
    end

    test "a duration missing a unit defaults it to 0" do
      assert {:ok, duration} = Value.decode(%{"$duration" => %{"days" => 3}})
      assert duration.hours == 0
      assert duration.days == 3
    end

    test "encodes the seven-key duration predicator's parser emits, filling milliseconds" do
      assert {:ok, value} = Predicator.evaluate("3d8h")
      assert {:ok, %{"$duration" => encoded}} = Value.encode(value)
      assert encoded["days"] == 3
      assert encoded["hours"] == 8
      assert encoded["milliseconds"] == 0
      assert map_size(encoded) == 8
    end

    test "a parsed duration re-decodes to the canonical eight-key form" do
      assert {:ok, value} = Predicator.evaluate("2w")
      assert {:ok, encoded} = Value.encode(value)
      assert {:ok, decoded} = Value.decode(encoded)
      assert decoded == Map.put(value, :milliseconds, 0)
      assert {:ok, ^encoded} = Value.encode(decoded)
    end

    test "a duration with a bogus unit key is rejected" do
      assert {:error, {:unknown_duration_unit, "fortnights"}} =
               Value.decode(%{"$duration" => %{"fortnights" => 1}})
    end

    test "a duration with a non-integer unit value is rejected" do
      assert {:error, {:invalid_duration_value, "days", "three"}} =
               Value.decode(%{"$duration" => %{"days" => "three"}})
    end
  end

  describe "encode/1" do
    test "encodes :undefined to the $undefined tagged shape" do
      assert Value.encode(:undefined) == {:ok, %{"$undefined" => true}}
    end

    test "encodes a Date to the $date tagged shape" do
      assert Value.encode(~D[2026-08-16]) == {:ok, %{"$date" => "2026-08-16"}}
    end

    test "encodes a DateTime to the $datetime tagged shape" do
      assert {:ok, %{"$datetime" => encoded}} = Value.encode(~U[2026-08-16 10:30:00Z])
      assert encoded =~ "2026-08-16T10:30:00"
    end

    test "encodes a duration map to the $duration tagged shape" do
      duration = %{
        years: 0,
        months: 0,
        weeks: 1,
        days: 3,
        hours: 0,
        minutes: 0,
        seconds: 0,
        milliseconds: 0
      }

      assert Value.encode(duration) ==
               {:ok,
                %{
                  "$duration" => %{
                    "years" => 0,
                    "months" => 0,
                    "weeks" => 1,
                    "days" => 3,
                    "hours" => 0,
                    "minutes" => 0,
                    "seconds" => 0,
                    "milliseconds" => 0
                  }
                }}
    end

    test "JSON-native scalars and host maps encode to themselves" do
      assert Value.encode(1999) == {:ok, 1999}
      assert Value.encode(%{"amount" => 1999}) == {:ok, %{"amount" => 1999}}
    end
  end

  describe "round trip" do
    @duration %{
      years: 1,
      months: 2,
      weeks: 3,
      days: 4,
      hours: 5,
      minutes: 6,
      seconds: 7,
      milliseconds: 8
    }

    for {label, value} <- [
          {"boolean", true},
          {"integer", 1999},
          {"float", 19.99},
          {"string", "gold"},
          {"nil", nil},
          {"list", [1, "a", nil]},
          {"map", %{"amount" => 1999}},
          {"undefined", :undefined},
          {"date", ~D[2026-08-16]},
          {"datetime", ~U[2026-08-16 10:30:00Z]},
          {"duration", @duration}
        ] do
      test "round trips #{label}" do
        value = unquote(Macro.escape(value))
        assert {:ok, encoded} = Value.encode(value)
        assert Value.decode(encoded) == {:ok, value}
      end
    end
  end
end
