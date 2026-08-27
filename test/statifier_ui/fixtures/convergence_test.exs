defmodule StatifierUI.Fixtures.ConvergenceTest do
  @moduledoc """
  ADR-0003's requirement made mechanical: the behaviour delivery path and the
  JSON sidecar delivery path converge on the same `StatifierUI.Fixtures`
  struct. `diagnostics` is compared separately - it is the one field the two
  paths legitimately differ on, since only the sidecar path emits
  loader diagnostics.
  """

  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures
  alias StatifierUI.Fixtures.Sidecar
  alias StatifierUI.Test.Support.Fixtures.ExpressionsSource
  alias StatifierUI.Test.Support.Fixtures.PaymentSource
  alias StatifierUI.Test.Support.Fixtures.TaggedSource

  @fixtures_dir "test/support/fixtures"

  describe "the plain-scalar bundle" do
    test "the behaviour and sidecar paths agree on scenarios, events, datasets, and expressions" do
      assert {:ok, source} = Fixtures.from_source(PaymentSource)
      assert {:ok, sidecar} = Sidecar.load(Path.join(@fixtures_dir, "payment.fixtures.json"))

      assert source.scenarios == sidecar.scenarios
      assert source.events == sidecar.events
      assert source.datasets == sidecar.datasets
      assert source.expressions == sidecar.expressions

      assert source.diagnostics == []
      assert sidecar.diagnostics == []
    end
  end

  describe "the tagged-value bundle" do
    test "the behaviour and sidecar paths agree on scenarios, events, datasets, and expressions" do
      assert {:ok, source} = Fixtures.from_source(TaggedSource)
      assert {:ok, sidecar} = Sidecar.load(Path.join(@fixtures_dir, "tagged.fixtures.json"))

      assert source.scenarios == sidecar.scenarios
      assert source.events == sidecar.events
      assert source.datasets == sidecar.datasets
      assert source.expressions == sidecar.expressions

      assert source.diagnostics == []
      assert sidecar.diagnostics == []
    end
  end

  describe "the datasets-and-expressions bundle" do
    test "the behaviour and sidecar paths agree on scenarios, events, datasets, and expressions" do
      assert {:ok, source} = Fixtures.from_source(ExpressionsSource)
      assert {:ok, sidecar} = Sidecar.load(Path.join(@fixtures_dir, "expressions.fixtures.json"))

      assert source.scenarios == sidecar.scenarios
      assert source.events == sidecar.events
      assert source.datasets == sidecar.datasets
      assert source.expressions == sidecar.expressions

      assert source.datasets != %{}
      assert source.expressions != %{}

      assert {:ok,
              %{"expect" => %{"variant-a-early" => :undefined, "variant-b-complete" => %Date{}}}} =
               Fixtures.expression(source, "started-date")

      assert source.diagnostics == []
      assert sidecar.diagnostics == []
    end
  end
end
