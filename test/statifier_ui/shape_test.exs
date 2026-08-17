defmodule StatifierUI.ShapeTest do
  use ExUnit.Case, async: true
  doctest StatifierUI.Shape

  alias StatifierUI.Shape

  describe "infer/1 - scalars" do
    test "boolean" do
      assert Shape.infer(true) == :boolean
      assert Shape.infer(false) == :boolean
    end

    test "integer" do
      assert Shape.infer(1999) == :integer
    end

    test "float" do
      assert Shape.infer(19.99) == :float
    end

    test "string" do
      assert Shape.infer("gold") == :string
    end

    test "date" do
      assert Shape.infer(Date.utc_today()) == :date
    end

    test "datetime" do
      assert Shape.infer(DateTime.utc_now()) == :datetime
    end

    test "nil infers as :null" do
      assert Shape.infer(nil) == :null
    end

    test ":undefined infers as :undefined, distinct from :null" do
      assert Shape.infer(:undefined) == :undefined
      assert Shape.infer(:undefined) != Shape.infer(nil)
    end
  end

  describe "infer/1 - structs" do
    test "%Date{} is not walked as a plain map" do
      assert Shape.infer(Date.utc_today()) == :date
    end

    test "%DateTime{} is not walked as a plain map" do
      assert Shape.infer(DateTime.utc_now()) == :datetime
    end
  end

  describe "infer/1 - duration" do
    test "an eight-key duration map (atom keys, all integers) infers as :duration" do
      duration = %{
        years: 0,
        months: 0,
        weeks: 0,
        days: 3,
        hours: 8,
        minutes: 0,
        seconds: 0,
        milliseconds: 0
      }

      assert Shape.infer(duration) == :duration
    end

    test "a seven-key near-miss infers as a plain map instead" do
      near_miss = %{
        years: 0,
        months: 0,
        weeks: 0,
        days: 3,
        hours: 8,
        minutes: 0,
        seconds: 0
      }

      assert {:map, _pairs} = Shape.infer(near_miss)
    end

    test "a map with a \"$date\" key infers as a plain map, not a wire-decoded value" do
      assert Shape.infer(%{"$date" => "2024-01-01"}) == {:map, %{"$date" => :string}}
    end
  end

  describe "infer/1 - lists" do
    test "empty list infers as {:list, :empty}" do
      assert Shape.infer([]) == {:list, :empty}
    end

    test "a homogeneous list infers as {:list, shape}" do
      assert Shape.infer(["a", "b", "c"]) == {:list, :string}
    end

    test "a heterogeneous list produces a sorted union" do
      assert Shape.infer([1, "a"]) == {:list, {:union, [:integer, :string]}}
    end

    test "a list of maps with differing key sets unifies the odd key against :undefined" do
      list = [%{"a" => 1, "b" => 2}, %{"a" => 3}]

      assert Shape.infer(list) ==
               {:list, {:map, %{"a" => :integer, "b" => {:union, [:integer, :undefined]}}}}
    end

    test "deep nesting infers recursively" do
      value = %{"orders" => [%{"items" => [%{"amount" => 100}]}]}

      assert Shape.infer(value) ==
               {:map,
                %{
                  "orders" =>
                    {:list,
                     {:map,
                      %{
                        "items" => {:list, {:map, %{"amount" => :integer}}}
                      }}}
                }}
    end
  end

  describe "infer/1 - maps" do
    test "atom keys are normalized to strings" do
      assert Shape.infer(%{tier: "gold"}) == {:map, %{"tier" => :string}}
    end

    test "key ordering is stable under a shuffled input map" do
      map_a = %{"z" => 1, "a" => 2, "m" => 3}
      map_b = %{"a" => 2, "m" => 3, "z" => 1}

      assert Shape.infer(map_a) == Shape.infer(map_b)
    end
  end

  describe "infer/1 - totality" do
    test "a tuple infers as :unknown without raising" do
      assert Shape.infer({:ok, 1}) == :unknown
    end

    test "a mixed list of tuples, pids, and refs each infer as :unknown" do
      values = [
        {:a, :b},
        self(),
        make_ref(),
        {1, 2, 3},
        spawn(fn -> :ok end)
      ]

      for value <- values do
        assert Shape.infer(value) == :unknown
      end
    end
  end

  describe "label/2" do
    test "renders scalars by name" do
      assert Shape.label(:integer) == "integer"
      assert Shape.label(:float) == "float"
      assert Shape.label(:string) == "string"
      assert Shape.label(:boolean) == "boolean"
      assert Shape.label(:date) == "date"
      assert Shape.label(:datetime) == "datetime"
      assert Shape.label(:duration) == "duration"
      assert Shape.label(:null) == "null"
      assert Shape.label(:undefined) == "undefined"
      assert Shape.label(:unknown) == "unknown"
    end

    test "renders {:list, :empty} as list<>" do
      assert Shape.label({:list, :empty}) == "list<>"
    end

    test "renders {:list, shape} as list<inner>" do
      assert Shape.label({:list, :string}) == "list<string>"
    end

    test "renders {:map, pairs} with keys sorted" do
      shape = {:map, %{"z" => :integer, "a" => :string}}
      assert Shape.label(shape) == "map{a: string, z: integer}"
    end

    test "renders {:union, shapes} joined by |" do
      assert Shape.label({:union, [:integer, :string]}) == "integer|string"
    end

    test "truncates at :max_keys, replacing remaining pairs with a single ..." do
      shape =
        {:map,
         %{
           "a" => :integer,
           "b" => :integer,
           "c" => :integer,
           "d" => :integer,
           "e" => :integer
         }}

      assert Shape.label(shape, max_keys: 2) == "map{a: integer, b: integer, ...}"
    end

    test "truncates nested maps and lists at :max_depth" do
      shape = {:map, %{"a" => {:map, %{"b" => {:list, :integer}}}}}

      assert Shape.label(shape, max_depth: 1) == "map{a: map{...}}"
      assert Shape.label(shape, max_depth: 2) == "map{a: map{b: list<...>}}"
    end
  end
end
