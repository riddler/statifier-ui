defmodule StatifierUI.Test.Support.Fixtures.AuthorizationSource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` used by `StatifierUI.FixturesTest` and
  reused by a later phase's sidecar-vs-behaviour convergence test. Describes
  the same bundle an `authorization.fixtures.json` sidecar describes: a
  `"within-budget-account"` scenario and an `"authorize.approved"` event.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def scenarios do
    %{"within-budget-account" => %{"card_brand" => "visa", "account_id" => "acct-1999"}}
  end

  @impl StatifierUI.Fixtures.Source
  def example_events do
    %{"authorize.approved" => %{"amount_cents" => 1999, "currency" => "USD"}}
  end
end
