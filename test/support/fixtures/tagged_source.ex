defmodule StatifierUI.Test.Support.Fixtures.TaggedSource do
  @moduledoc """
  A `StatifierUI.Fixtures.Source` used by the sidecar-vs-behaviour
  convergence test. Describes the same bundle as
  `test/support/fixtures/tagged.fixtures.json`, written in Elixir terms
  instead of ADR-0005's JSON tagged encoding: a `%Date{}`, a `%DateTime{}`,
  an eight-key duration map, `:undefined`, and `nil`.

  The duration lives in an event payload rather than in scenario data: a
  scenario's datamodel is walked by `StatifierUI.Fixtures.new/1`'s
  `check_keys/2` (mirroring `Statifier.MachineState.check_keys!/2`), which
  requires string keys at every level and stops only at structs. Predicator
  durations are bare maps with atom keys (no struct - see
  `deps/predicator/lib/predicator/duration.ex`), so a literal duration value
  cannot appear inside example scenario data any more than it could inside a
  real chart's initial `:datamodel` option. Event payloads carry no such
  constraint - they are preserved verbatim - so that is where a duration
  value belongs.
  """

  use StatifierUI.Fixtures.Source

  @impl StatifierUI.Fixtures.Source
  def scenarios do
    %{
      "tagged" => %{
        "created_at" => ~D[2026-08-16],
        "expires_at" => ~U[2026-08-16 10:30:00Z],
        "middle_name" => nil,
        "tags" => [~D[2026-08-17]]
      }
    }
  end

  @impl StatifierUI.Fixtures.Source
  def example_events do
    %{
      "payment.pending" => :undefined,
      "grace_period.granted" => %{
        years: 0,
        months: 0,
        weeks: 1,
        days: 3,
        hours: 0,
        minutes: 0,
        seconds: 0,
        milliseconds: 0
      }
    }
  end
end
