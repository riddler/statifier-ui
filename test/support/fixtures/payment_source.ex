defmodule StatifierUI.Test.Support.Fixtures.PaymentSource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` used by `StatifierUI.FixturesTest` and
  reused by a later phase's sidecar-vs-behaviour convergence test. Describes
  the same bundle a `payment.fixtures.json` sidecar describes: a
  `"gold-tier-user"` scenario and a `"payment.success"` event.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def scenarios do
    %{"gold-tier-user" => %{"tier" => "gold", "user_id" => "u-1999"}}
  end

  @impl StatifierUI.Fixtures.Source
  def example_events do
    %{"payment.success" => %{"amount" => 1999, "currency" => "USD"}}
  end
end
