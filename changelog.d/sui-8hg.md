### Added

- `StatifierUI.DatamodelExplorer` carries `session.start`'s `projection`
  header on the pane struct and exposes it as `projected?/1` and
  `projection_profile/1`, so a host can surface the profile name alongside
  the mode (ADR-0012).
- `StatifierUI.DatamodelExplorer.edit_disabled_reason/1` and `/2`, with the
  boolean forms `editable?/1` and `editable?/2`: ADR-0012's rule that no
  value-editing affordance may be offered over a projected stream, or over a
  redacted slot, as a function a write path can consult. The reason is a
  sentence written to be shown, naming the profile or the slot. The pane
  still has no write path of its own; this is the guard whatever builds one
  asks first.
- `StatifierUI.DatamodelExplorer.Markdown` renders that reason under a live
  pane's header when the stream is projected, instead of leaving the reader
  to guess why every value reads `(redacted)`.

`StatifierUI.EventInjection` is explicitly **excluded** from the same rule
and its moduledoc records why: its palette is composed from a fixtures
bundle the operator already holds in full, never from observed values, so
projection cannot reach it.
