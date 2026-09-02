### Added

- `StatifierUI.Live.ExpressionInput` - an expression field with completion,
  offering predicator's own grammar (operators, keywords, literal words,
  duration units, and every function the host's providers resolve) alongside
  the datamodel paths the host declares. It is the affordance
  statifier_blocks ADR-0005 defers to this package, and it drops into that
  editor's `expression_component` seam as
  `&StatifierUI.Live.ExpressionInput.expression_input/1` (sui-wqr). The field
  carries no event of its own: it renders an `<input>` with the `name` it was
  given, so edits - typed or completed - arrive through the host form's
  existing `phx-change`.
- `StatifierUI.Expression` - the completion source behind it, pure and
  without LiveView: `completions/2` returns `{label, insert, kind, detail}`
  entries read from `Predicator.Vocabulary` and the supplied paths, so a host
  can render its own control over the same list.
- **This package now ships JavaScript**, as source under `assets/`, per
  ADR-0009. A host adds `"statifier_ui": "file:../deps/statifier_ui/assets"`
  to its `assets/package.json` and spreads `StatifierUIHooks` from
  `js/index.js` into its `LiveSocket` hooks. The one hook,
  `StatifierUIExpressionInput`, upgrades the field from a native `<datalist>`
  to a caret-aware completion list; it imports nothing, and a host that
  registers no hook keeps a working field. Hook names and export names are
  public API. See the ADR-0009 note of 2026-09-02 for the layout.

### Changed

- `predicator` is pinned to a git ref rather than `~> 9.0` while
  `Predicator.Vocabulary` is unreleased. Completion degrades to the declared
  paths alone on a predicator without it, so the pin buys the grammar half
  rather than the package's ability to compile, and it reverts to a hex
  requirement at predicator's next release.
