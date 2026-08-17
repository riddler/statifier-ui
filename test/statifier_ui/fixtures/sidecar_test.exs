defmodule StatifierUI.Fixtures.SidecarTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Sidecar

  @fixtures_dir "test/support/fixtures"

  describe "sidecar_path/1" do
    test "replaces the final extension with .fixtures.json" do
      assert Sidecar.sidecar_path("payment.scxml") == "payment.fixtures.json"
    end

    test "replaces the final extension in a full path" do
      assert Sidecar.sidecar_path("charts/payment.scxml") == "charts/payment.fixtures.json"
    end

    test "appends .fixtures.json when the path has no extension" do
      assert Sidecar.sidecar_path("payment") == "payment.fixtures.json"
    end
  end

  describe "load_for_chart/1" do
    test "a missing sidecar is {:error, :enoent}" do
      assert Sidecar.load_for_chart(Path.join(@fixtures_dir, "nonexistent.scxml")) ==
               {:error, :enoent}
    end

    test "loads the sidecar derived from a chart path" do
      assert {:ok, %Fixtures{}} =
               Sidecar.load_for_chart(Path.join(@fixtures_dir, "payment.scxml"))
    end
  end

  describe "load/1" do
    test "a missing file returns {:error, :enoent}" do
      assert Sidecar.load(Path.join(@fixtures_dir, "does_not_exist.fixtures.json")) ==
               {:error, :enoent}
    end

    test "malformed JSON returns an error value" do
      path =
        Path.join(System.tmp_dir!(), "sidecar_test_malformed_#{System.unique_integer()}.json")

      File.write!(path, "{not json")

      on_exit(fn -> File.rm(path) end)

      assert {:error, _reason} = Sidecar.load(path)
    end
  end

  describe "from_json/1 - version handling" do
    test "rejects a missing version" do
      assert {:error, :missing_version} = Sidecar.from_json(%{})
    end

    test "rejects a non-integer version" do
      assert {:error, {:invalid_version, "1"}} = Sidecar.from_json(%{"version" => "1"})
    end

    test "accepts version 1 with no version diagnostic" do
      assert {:ok, %Fixtures{diagnostics: []}} = Sidecar.from_json(%{"version" => 1})
    end

    test "accepts a higher version with a :future_version diagnostic" do
      assert {:ok, %Fixtures{diagnostics: [%{kind: :future_version}]}} =
               Sidecar.from_json(%{"version" => 2})
    end

    test "rejects version 0" do
      assert {:error, {:invalid_version, 0}} = Sidecar.from_json(%{"version" => 0})
    end

    test "rejects a negative version" do
      assert {:error, {:invalid_version, -1}} = Sidecar.from_json(%{"version" => -1})
    end
  end

  describe "from_json/1 - shape" do
    test "rejects a non-object top level" do
      assert {:error, {:invalid_sidecar, [1, 2, 3]}} = Sidecar.from_json([1, 2, 3])
    end
  end

  describe "from_json/1 - extended.fixtures.json" do
    setup do
      path = Path.join(@fixtures_dir, "extended.fixtures.json")
      {:ok, contents} = File.read(path)
      {:ok, decoded} = JSON.decode(contents)
      %{decoded: decoded}
    end

    test "loads with three :unknown_key diagnostics naming datasets, expressions, and the nonsense key",
         %{decoded: decoded} do
      assert {:ok, %Fixtures{diagnostics: diagnostics}} = Sidecar.from_json(decoded)

      unknown_key_names =
        diagnostics
        |> Enum.filter(&(&1.kind == :unknown_key))
        |> Enum.map(&hd(&1.path))
        |> Enum.sort()

      assert unknown_key_names == ["datasets", "expressions", "nonsense"]
    end

    test "scenarios and events load as empty maps", %{decoded: decoded} do
      assert {:ok, %Fixtures{scenarios: %{}, events: %{}}} = Sidecar.from_json(decoded)
    end
  end

  describe "from_json/1 - tagged.fixtures.json" do
    setup do
      path = Path.join(@fixtures_dir, "tagged.fixtures.json")
      {:ok, contents} = File.read(path)
      {:ok, decoded} = JSON.decode(contents)
      %{decoded: decoded}
    end

    test "decodes real Date, DateTime, duration, and :undefined values", %{decoded: decoded} do
      assert {:ok, %Fixtures{} = fixtures} = Sidecar.from_json(decoded)

      assert {:ok, scenario} = Fixtures.scenario(fixtures, "tagged")
      assert scenario["created_at"] == ~D[2026-08-16]
      assert scenario["expires_at"] == ~U[2026-08-16 10:30:00Z]
      assert scenario["middle_name"] == nil
      assert scenario["tags"] == [~D[2026-08-17]]

      assert Fixtures.event(fixtures, "payment.pending") == {:ok, :undefined}

      assert {:ok, duration} = Fixtures.event(fixtures, "grace_period.granted")

      assert duration == %{
               years: 0,
               months: 0,
               weeks: 1,
               days: 3,
               hours: 0,
               minutes: 0,
               seconds: 0,
               milliseconds: 0
             }
    end
  end
end
