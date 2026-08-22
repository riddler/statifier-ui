defmodule StatifierUI.DatamodelExplorer.Entry do
  @moduledoc """
  One node in the datamodel explorer tree (`sui-t36.7`): a `<data>`
  declaration, a system variable, a provider function, a fixture scenario
  value, or a runtime-only location - the ADR-0003 tiers, plus live mode's
  `:runtime` sibling for a location `session.datamodel` never named.

  Struct and types only - the way `StatifierUI.EventLog.Round` and
  `StatifierUI.EventInjection.Entry` are - because both
  `StatifierUI.DatamodelExplorer.Scope` (authoring and live alike) and
  `sui-t36.8`'s renderer share this one shape.
  """

  @typedoc """
  Which of ADR-0003's tiers this entry belongs to. `:data` and `:runtime`
  are both tier 1 - a document `<data id>` declaration and, in live mode
  only, a location written at runtime that `session.datamodel`'s snapshot
  did not name (an `<invoke idlocation>` or an empty `<finalize>`
  auto-assign). `:system` is tier 2a (spec 5.10.1's system variables),
  `:function` is tier 2b (predicator provider functions in scope), and
  `:scenario` is tier 3 - the one tier that switches source between modes.
  """
  @type tier :: :data | :system | :function | :scenario | :runtime

  @typedoc """
  * `value` - always a **decoded** Elixir value, never a `$`-tagged wire
    term. This is the invariant that lets one `StatifierUI.Shape.infer/1`
    pass serve both authoring and live mode.
  * `changed?` - live-mode only; defaults to `false`. Authoring mode never
    sets it.
  * `arity` - set on `:function` entries only, predicator's
    `non_neg_integer() | [non_neg_integer()]` multi-arity form verbatim.
  * `declared_source` - the tier-1 declared expression text, display only.
    Present only when the pane was given the chart source and
    `value_location != location` (`docs/wire-format.md:335-348`).
  * `location_source` - `effect.datamodel_change`'s raw author string,
    live mode only, display only.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          tier: tier(),
          value: term(),
          shape: StatifierUI.Shape.t(),
          label: String.t(),
          changed?: boolean(),
          children: [t()],
          d_index: non_neg_integer() | nil,
          arity: non_neg_integer() | [non_neg_integer()] | nil,
          declared_source: String.t() | nil,
          location_source: String.t() | nil
        }

  @enforce_keys [:name, :tier, :value, :shape, :label]
  defstruct [
    :name,
    :tier,
    :value,
    :shape,
    :label,
    :d_index,
    :arity,
    :declared_source,
    :location_source,
    changed?: false,
    children: []
  ]
end
