defmodule StatifierUI.Fixtures.Bundle.MarkdownTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures.Bundle
  alias StatifierUI.Fixtures.Bundle.Markdown
  alias StatifierUI.Test.Support.Fixtures.Palette

  @bundles_dir "test/support/fixtures/bundles"

  setup do
    {:ok, bundle} = Bundle.load("myapp.authorize", Palette.Authorize.fixtures())
    %{bundle: bundle}
  end

  describe "render/2 structure" do
    test "heads the panel with the fragment name", %{bundle: bundle} do
      assert Markdown.render(bundle) =~ "# myapp.authorize"
    end

    test ":heading overrides the name and nil drops the heading", %{bundle: bundle} do
      assert Markdown.render(bundle, heading: "Authorize a card") =~ "# Authorize a card"
      refute Markdown.render(bundle, heading: nil) =~ "\n# "
    end

    test "names where the bundle came from", %{bundle: bundle} do
      {:ok, from_module} =
        Bundle.load("myapp.authorize", Palette.Authorize.fixtures(),
          origin: {:module, Palette.Authorize}
        )

      assert Markdown.render(from_module) =~
               "From `StatifierUI.Test.Support.Fixtures.Palette.Authorize`."

      assert Markdown.render(bundle) =~ "From an inline bundle."
      refute Markdown.render(bundle, origin: false) =~ "From "
    end

    test "renders the truth table without a second heading of its own", %{bundle: bundle} do
      rendered = Markdown.render(bundle)

      refute rendered =~ "# Truth table"
      assert rendered =~ "exceeds-budget"
      assert rendered =~ "within-budget"
    end

    test "says so plainly when a fragment ships nothing to evaluate" do
      {:ok, bundle} = Bundle.load("myapp.plain", %{})

      assert Markdown.render(bundle) =~ "This fragment ships no datasets and no expressions."
    end
  end

  describe "render/2 expectations section" do
    test "tabulates every stated expectation with its outcome", %{bundle: bundle} do
      rendered = Markdown.render(bundle)

      assert rendered =~ "## Expectations"
      assert rendered =~ "| expression | dataset | expected | actual | result |"
      assert rendered =~ "matched"
    end

    test "marks a mismatch in words, with emphasis added on top rather than instead" do
      {:ok, bundle} =
        Bundle.load("myapp.authorize", %{
          datasets: %{"approved" => %{"amount" => 90}},
          expressions: %{"low" => %{"source" => "amount < 50", "expect" => %{"approved" => true}}}
        })

      rendered = Markdown.render(bundle)

      assert rendered =~ "mismatched"
      assert String.replace(rendered, ~w(* _), "") =~ "mismatched"
    end

    test "summarizes as four counts and never as a single verdict" do
      {:ok, bundle} =
        Bundle.load("myapp.authorize", %{
          datasets: %{"approved" => %{"amount" => 90}},
          expressions: %{
            "high" => %{"source" => "amount > 50", "expect" => %{"approved" => true}},
            "dangling" => %{"source" => "amount > 50", "expect" => %{"absent" => true}}
          }
        })

      rendered = Markdown.render(bundle)

      assert rendered =~
               "1 matched, 0 mismatched, 0 errored, 1 stated against a dataset this bundle does not carry."

      refute rendered =~ "PASS"
      refute rendered =~ "FAIL"
    end

    test "an expectation naming no dataset says so instead of showing an actual" do
      {:ok, bundle} =
        Bundle.load("myapp.authorize", %{
          datasets: %{},
          expressions: %{"x" => %{"source" => "amount > 50", "expect" => %{"absent" => true}}}
        })

      assert Markdown.render(bundle) =~ "_no such dataset_"
    end

    test "reports a bundle that states no expectations at all" do
      {:ok, bundle} =
        Bundle.load("myapp.authorize", %{
          datasets: %{"approved" => %{"amount" => 90}},
          expressions: %{"high" => %{"source" => "amount > 50"}}
        })

      assert Markdown.render(bundle) =~ "Expectations: none stated."
    end

    test ":expectations false drops the section", %{bundle: bundle} do
      refute Markdown.render(bundle, expectations: false) =~ "## Expectations"
    end
  end

  describe "render/2 option forwarding" do
    test "forwards :orientation to the truth-table renderer without choosing one", %{
      bundle: bundle
    } do
      datasets_as_rows = Markdown.render(bundle, orientation: :datasets_as_rows)
      expressions_as_rows = Markdown.render(bundle, orientation: :expressions_as_rows)

      assert datasets_as_rows =~ "| dataset |"
      assert expressions_as_rows =~ "| expression | over-budget | within-budget |"
      refute datasets_as_rows == expressions_as_rows
    end

    test "forwards :legend and :sources", %{bundle: bundle} do
      refute Markdown.render(bundle, legend: false) =~ "three separate results"
      refute Markdown.render(bundle, sources: false) =~ "Expressions:\n"
    end

    test "forwards :functions to both halves so table and expectations agree" do
      functions = %{"double" => {1, fn [n], _ctx -> {:ok, n * 2} end}}

      {:ok, bundle} =
        Bundle.load("myapp.authorize", %{
          datasets: %{"approved" => %{"amount" => 21}},
          expressions: %{
            "doubled" => %{"source" => "double(amount)", "expect" => %{"approved" => 42}}
          }
        })

      rendered = Markdown.render(bundle, functions: functions)

      assert rendered =~ "`42`"
      assert rendered =~ "1 matched"
    end
  end

  describe "render/2 diagnostics" do
    test "surfaces the loader's own notes on the panel" do
      {:ok, bundle} =
        Bundle.load("myapp.capture", Path.join(@bundles_dir, "capture.fixtures.json"))

      rendered = Markdown.render(bundle)

      assert rendered =~ "Notes:"
      assert rendered =~ "generator"
    end

    test ":diagnostics false drops the notes", %{bundle: bundle} do
      refute Markdown.render(bundle, diagnostics: false) =~ "Notes:"
    end
  end

  describe "render_discovery/2" do
    test "renders one panel per loaded bundle, in discovery order" do
      {:ok, discovery} = Bundle.discover_dir(@bundles_dir)

      rendered = Markdown.render_discovery(discovery)

      assert rendered =~ "# authorize"
      assert rendered =~ "# capture"

      assert :binary.match(rendered, "# authorize") < :binary.match(rendered, "# capture")
    end

    test "names every bundle that failed to load" do
      {:ok, discovery} = Bundle.discover_dir(@bundles_dir)

      rendered = Markdown.render_discovery(discovery)

      assert rendered =~ "## Bundles that failed to load"
      assert rendered =~ "**broken**"
    end

    test "stays silent about fragments that ship no examples" do
      discovery =
        Bundle.discover(%{"myapp.plain" => Palette.Plain, "myapp.authorize" => Palette.Authorize})

      rendered = Markdown.render_discovery(discovery)

      assert rendered =~ "# myapp.authorize"
      refute rendered =~ "myapp.plain"
    end

    test "prints the three-values legend at most once across the page" do
      {:ok, discovery} = Bundle.discover_dir(@bundles_dir)

      rendered = Markdown.render_discovery(discovery)

      refute rendered =~ "three separate results"
      assert Markdown.render_discovery(discovery, legend: true) =~ "three separate results"
    end

    test "an empty discovery renders to an empty string" do
      assert Markdown.render_discovery(%{bundles: [], without: [], errors: []}) == ""
    end
  end
end
