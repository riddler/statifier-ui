defmodule StatifierUI.EventInjection.Entry do
  @moduledoc """
  One fixture event, rendered as a palette button: an event name, its sample
  payload verbatim, and the ADR-0005 JSON text a form prefills the payload
  field with.

  ## The `:undefined` asymmetry

  `payload` is the fixture value exactly as `StatifierUI.Fixtures.event/2`
  returned it - a predicator value, possibly the `:undefined` sentinel that
  means "no data". `payload_text` is that value's canonical ADR-0005 JSON,
  with one deliberate exception: a `payload` of `:undefined` produces
  `payload_text: ""` rather than `~s({"$undefined":true})`.

  The reason is the round trip. `StatifierUI.EventInjection.Draft.build/2`
  reads a blank payload field as "no data" - the same spelling
  `Statifier.Event.external/2` itself defaults to. Emitting the tagged JSON
  text for `:undefined` would prefill a form field with text that, if sent
  back unedited, still means "no data" but no longer looks blank to a person
  editing it; emitting the blank string instead makes the palette's round
  trip through the form the identity on the common case. Every other value,
  `nil` included, gets its ordinary JSON text (`"null"` for `nil`, `"{}"` for
  an empty map). This is the one place in the pane where the encoding and the
  form affordance diverge, and it diverges on purpose.
  """

  @type t :: %__MODULE__{
          name: String.t(),
          payload: term(),
          payload_text: String.t()
        }

  defstruct [:name, :payload, :payload_text]
end
