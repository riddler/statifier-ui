defmodule StatifierUI.Fixtures.BundleTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Bundle
  alias StatifierUI.Test.Support.Fixtures.Palette

  doctest StatifierUI.Fixtures.Bundle

  @bundles_dir "test/support/fixtures/bundles"

  describe "load/3 - the four spellings" do
    test "accepts an already-validated Fixtures struct and records it as inline" do
      {:ok, fixtures} = Fixtures.new(datasets: %{"hot" => %{"score" => 90}})

      assert {:ok, %Bundle{} = bundle} = Bundle.load("myapp.score", fixtures)
      assert bundle.name == "myapp.score"
      assert bundle.origin == :inline
      assert bundle.fixtures == fixtures
    end

    test "accepts the Elixir spelling: atom top-level keys" do
      assert {:ok, %Bundle{} = bundle} =
               Bundle.load("myapp.score", %{
                 datasets: %{"hot" => %{"record" => %{"pages_viewed" => 14}}},
                 expressions: %{"busy" => %{"source" => "record.pages_viewed > 5"}}
               })

      assert Fixtures.dataset_names(bundle.fixtures) == ["hot"]
      assert Fixtures.expression_names(bundle.fixtures) == ["busy"]
    end

    test "accepts the JSON spelling: string top-level keys, decoded like a sidecar" do
      assert {:ok, %Bundle{} = bundle} =
               Bundle.load("myapp.signup", %{
                 "version" => 1,
                 "datasets" => %{"adult" => %{"user" => %{"age" => 30}}},
                 "expressions" => %{
                   "signup" => %{
                     "source" => "user.signup_date",
                     "expect" => %{"adult" => %{"$date" => "2026-01-15"}}
                   }
                 }
               })

      assert {:ok, ~D[2026-01-15]} = Fixtures.expect(bundle.fixtures, "signup", "adult")
    end

    test "supplies version 1 for a JSON-spelled map that omits it" do
      assert {:ok, %Bundle{} = bundle} =
               Bundle.load("myapp.score", %{"datasets" => %{"hot" => %{"score" => 90}}})

      assert Fixtures.dataset_names(bundle.fixtures) == ["hot"]
    end

    test "accepts a sidecar path and records the file as the origin" do
      path = Path.join(@bundles_dir, "score.fixtures.json")

      assert {:ok, %Bundle{} = bundle} = Bundle.load("myapp.score", path)
      assert bundle.origin == {:sidecar, path}
      assert Fixtures.dataset_names(bundle.fixtures) == ["cold-lead", "hot-lead"]
    end

    test "an empty map is a bundle with nothing in it, not an ambiguity" do
      assert {:ok, %Bundle{} = bundle} = Bundle.load("myapp.plain", %{})
      assert Bundle.empty?(bundle)
    end

    test "records an explicit :origin over the derived one" do
      assert {:ok, %Bundle{origin: {:module, SomeModule}}} =
               Bundle.load("myapp.score", %{datasets: %{}}, origin: {:module, SomeModule})
    end
  end

  describe "load/3 - rejections" do
    test "rejects a map mixing atom and string top-level keys rather than guessing" do
      assert {:error, {:mixed_bundle_keys, "myapp.score"}} =
               Bundle.load("myapp.score", %{"expressions" => %{}, datasets: %{}})
    end

    test "rejects an unknown atom key, because a typo in Elixir is a bug not a future version" do
      assert {:error, {:unknown_bundle_key, "myapp.score", :datsets}} =
               Bundle.load("myapp.score", %{datsets: %{"typo" => %{}}})
    end

    test "keeps the sidecar's ignore-unknown-keys discipline for the JSON spelling" do
      assert {:ok, %Bundle{} = bundle} =
               Bundle.load("myapp.score", %{
                 "version" => 1,
                 "datasets" => %{"hot" => %{}},
                 "produced_by" => "a newer writer"
               })

      assert Enum.any?(bundle.diagnostics, &(&1.kind == :unknown_key))
      assert Fixtures.dataset_names(bundle.fixtures) == ["hot"]
    end

    test "wraps a validation failure with the fragment name" do
      assert {:error, {:invalid_bundle, "myapp.score", _reason}} =
               Bundle.load("myapp.score", %{datasets: %{"hot" => %{1 => "bad key"}}})
    end

    test "reports a missing sidecar file rather than an empty bundle" do
      assert {:error, {:sidecar_not_found, _path}} =
               Bundle.load("myapp.gone", Path.join(@bundles_dir, "gone.fixtures.json"))
    end

    test "rejects a term in none of the four spellings" do
      assert {:error, {:unrecognized_bundle, "myapp.score", 42}} =
               Bundle.load("myapp.score", 42)
    end
  end

  describe "load!/3" do
    test "returns the bundle on success" do
      assert %Bundle{name: "myapp.score"} = Bundle.load!("myapp.score", %{datasets: %{}})
    end

    test "raises with the fragment name and the reason" do
      assert_raise ArgumentError, ~r/myapp\.score.*unknown_bundle_key/s, fn ->
        Bundle.load!("myapp.score", %{datsets: %{}})
      end
    end
  end

  describe "discover/2 over a palette" do
    setup do
      %{
        palette: %{
          "myapp.score" => Palette.Score,
          "myapp.notify" => Palette.Notify,
          "myapp.plain" => Palette.Plain,
          "myapp.malformed" => Palette.Malformed,
          "myapp.exploding" => Palette.Exploding
        }
      }
    end

    test "loads both spellings, sorted by name", %{palette: palette} do
      discovery = Bundle.discover(palette)

      assert Enum.map(discovery.bundles, & &1.name) == ["myapp.notify", "myapp.score"]
    end

    test "records the module each bundle came from", %{palette: palette} do
      discovery = Bundle.discover(palette)

      assert %{"myapp.score" => %Bundle{origin: {:module, Palette.Score}}} =
               Bundle.by_name(discovery)
    end

    test "a fragment with no fixtures/0 is an absence, not a failure", %{palette: palette} do
      discovery = Bundle.discover(palette)

      assert discovery.without == ["myapp.plain"]
      refute Enum.any?(discovery.errors, fn {name, _reason} -> name == "myapp.plain" end)
    end

    test "one malformed bundle does not hide the rest", %{palette: palette} do
      discovery = Bundle.discover(palette)

      assert {"myapp.malformed", {:unknown_bundle_key, "myapp.malformed", :datsets}} in discovery.errors

      assert Enum.map(discovery.bundles, & &1.name) == ["myapp.notify", "myapp.score"]
    end

    test "a raising callback is caught and reported against its own name", %{palette: palette} do
      discovery = Bundle.discover(palette)

      assert {"myapp.exploding", {:bundle_callback_raised, %RuntimeError{}}} =
               Enum.find(discovery.errors, fn {name, _reason} -> name == "myapp.exploding" end)
    end

    test "accepts a list of pairs as readily as a map" do
      discovery = Bundle.discover([{"b", Palette.Notify}, {"a", Palette.Score}])

      assert Enum.map(discovery.bundles, & &1.name) == ["a", "b"]
    end

    test "an unloadable module is an absence, not a crash" do
      discovery = Bundle.discover(%{"myapp.ghost" => NoSuchModuleAnywhere})

      assert discovery.without == ["myapp.ghost"]
    end

    test ":callback names a function other than fixtures/0" do
      discovery = Bundle.discover(%{"myapp.score" => Palette.Score}, callback: :examples)

      assert discovery.without == ["myapp.score"]
    end
  end

  describe "discover_dir/2" do
    test "names each bundle after its file and sorts them" do
      assert {:ok, discovery} = Bundle.discover_dir(@bundles_dir)

      assert Enum.map(discovery.bundles, & &1.name) == ["notify", "score"]
    end

    test "records the file as the origin" do
      assert {:ok, discovery} = Bundle.discover_dir(@bundles_dir)
      bundles = Bundle.by_name(discovery)

      assert bundles["score"].origin ==
               {:sidecar, Path.join(@bundles_dir, "score.fixtures.json")}
    end

    test "ignores files that are not sidecars" do
      assert {:ok, discovery} = Bundle.discover_dir(@bundles_dir)

      refute "README" in Enum.map(discovery.bundles, & &1.name)
      refute Enum.any?(discovery.errors, fn {name, _reason} -> name == "README" end)
    end

    test "reports a malformed sidecar against its own name and loads the rest" do
      assert {:ok, discovery} = Bundle.discover_dir(@bundles_dir)

      assert Enum.any?(discovery.errors, fn {name, _reason} -> name == "broken" end)
      assert Enum.map(discovery.bundles, & &1.name) == ["notify", "score"]
    end

    test "carries the sidecar's own diagnostics onto the bundle" do
      assert {:ok, discovery} = Bundle.discover_dir(@bundles_dir)
      bundles = Bundle.by_name(discovery)

      assert Enum.any?(bundles["notify"].diagnostics, &(&1.kind == :unknown_key))
    end

    test "a missing directory is an error, not an empty discovery" do
      assert {:error, {:bundle_dir_unreadable, _dir, :enoent}} =
               Bundle.discover_dir("test/support/fixtures/no-such-palette")
    end
  end

  describe "name_from_path/1 and empty?/1" do
    test "strips the sidecar suffix and the directory" do
      assert Bundle.name_from_path("palette/core.wait.fixtures.json") == "core.wait"
    end

    test "empty? is false once the bundle carries anything to evaluate" do
      assert {:ok, bundle} = Bundle.load("myapp.score", %{datasets: %{"hot" => %{}}})

      refute Bundle.empty?(bundle)
    end
  end
end
