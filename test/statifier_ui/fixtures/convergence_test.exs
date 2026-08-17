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
  alias StatifierUI.Test.Support.Fixtures.PaymentSource
  alias StatifierUI.Test.Support.Fixtures.TaggedSource

  @fixtures_dir "test/support/fixtures"

  describe "the plain-scalar bundle" do
    test "the behaviour and sidecar paths agree on scenarios and events" do
      assert {:ok, source} = Fixtures.from_source(PaymentSource)
      assert {:ok, sidecar} = Sidecar.load(Path.join(@fixtures_dir, "payment.fixtures.json"))

      assert source.scenarios == sidecar.scenarios
      assert source.events == sidecar.events

      assert source.diagnostics == []
      assert sidecar.diagnostics == []
    end
  end

  describe "the tagged-value bundle" do
    test "the behaviour and sidecar paths agree on scenarios and events" do
      assert {:ok, source} = Fixtures.from_source(TaggedSource)
      assert {:ok, sidecar} = Sidecar.load(Path.join(@fixtures_dir, "tagged.fixtures.json"))

      assert source.scenarios == sidecar.scenarios
      assert source.events == sidecar.events

      assert source.diagnostics == []
      assert sidecar.diagnostics == []
    end
  end
end
