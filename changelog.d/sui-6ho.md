### Fixed

- `StatifierUI.Diagram.render/2` no longer drops transitions the Mermaid
  projection has no obvious notation for. A targetless transition - the
  spec-legal way to run executable content without changing configuration -
  was rendered as nothing at all, so a state that handles an event read as
  one that ignores it; it is now drawn as a self-edge marked `[internal]`.
  A history state's default transition, which lives in `history_default`
  rather than in the selectable `transitions` list, was dropped the same
  way, leaving the `(H)` / `(H*)` label naming a pseudo-state whose
  fallback target was invisible; it is now drawn with a `[default]` marker.

### Changed

- A transition written `type="internal"` now carries an `[internal]`
  marker in the diagram. SCXML's `external` default stays unmarked, so the
  two no longer render identically.
- `StatifierUI.Diagram`'s moduledoc gained a "Known limits of this
  projection" section: lifted-edge geometry (including edges between two
  regions of one parallel state), self-edge notation for internal
  transitions, pseudo-states drawn as ordinary nodes, shallow-versus-deep
  history distinguishable only by label, executable content not drawn, and
  layout left entirely to Mermaid. These are the accepted limits of the
  Mermaid backend rather than defects; ADR-0008's elkjs renderer is where
  they are addressed.
