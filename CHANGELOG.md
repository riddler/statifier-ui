# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.2.0] 2026-08-27

Fixtures become executable. ADR-0006 adds named datasets and free-standing
expressions to a fixture bundle, `StatifierUI.TruthTable` evaluates the two
against each other into a result matrix, and a bundle can now travel with a
single reusable chart fragment rather than with a whole chart - so a palette
entry carries its own worked examples and a host can run them in its own
suite.

### Added

- `StatifierUI.Fixtures` gains `datasets` and `expressions` fields (ADR-0006):
  named example datamodels for evaluating expressions against, and named
  free-standing predicator expressions carrying an `expect` map keyed by
  dataset name.
- `StatifierUI.Fixtures.Source` gains optional `datasets/0` and
  `expressions/0` callbacks so a host can supply the two new maps from
  Elixir alongside `scenarios/0` and `example_events/0`.
- `StatifierUI.Fixtures.Lint` reports an expression matching no compiled
  guard and an `expect` key naming no dataset, both as warnings.
- `StatifierUI.Fixtures.Expectations` runs every `expect` entry against its
  named dataset and reports whether the stated value held, for wiring into a
  host's own test suite.
- Depends directly on `predicator` (`~> 9.0`) rather than only transitively
  through `statifier`.
- `StatifierUI.TruthTable` evaluates a bundle's expressions across its
  datasets and returns the ADR-0006 result matrix, one cell per
  `(expression, dataset)` pair. A cell's verdict is `:satisfied`,
  `:unsatisfied`, `:undefined`, `:value`, `:error`, or `:missing_dataset` -
  deliberately not `true` / `false`, so predicator's three-valued
  `undefined` cannot be collapsed into false by Elixir truthiness.
- `StatifierUI.TruthTable.Markdown` renders that matrix as Markdown, with
  datasets down the rows and expressions across the columns by default, or
  transposed with `orientation: :expressions_as_rows`. Every cell spells its
  value out as a word and adds emphasis on top, so the three truth values
  stay distinct in plain text.
- `StatifierUI.Kino.truth_table/2` wraps the rendered matrix in a
  `Kino.Markdown` widget for a Livebook cell. It needs no session and no
  Phoenix; without the optional `:kino` dependency the stub points at the
  pure renderer instead.
- `StatifierUI.Fixtures.Bundle` lets an ADR-0003/ADR-0006 fixture bundle
  travel with one reusable chart fragment instead of with a whole chart, so
  a palette entry can carry its own executable examples. A fragment supplies
  its bundle as a `StatifierUI.Fixtures` struct, an atom-keyed Elixir map, a
  string-keyed sidecar map, or a path to a `.fixtures.json` file; all four
  route through the existing validation and converge on one struct.
- `StatifierUI.Fixtures.Bundle.discover/2` loads every entry's bundle across
  a palette of modules, and `discover_dir/2` does the same for a directory
  of `<fragment>.fixtures.json` files. Neither is all-or-nothing: a fragment
  that ships no examples is reported as an absence, and one malformed bundle
  is reported against its own name while the rest still load.
- `StatifierUI.Fixtures.Bundle.Markdown` renders a fragment's "test this
  step" panel - its truth table and its expectation results together - and
  `render_discovery/2` renders a whole palette's worth. The expectations
  summary reports four counts rather than a pass or a fail, because
  `Expectations.check/2` and `Fixtures.Lint` deliberately disagree about
  whether an `expect` key naming no dataset is a failure or a warning.
- `StatifierUI.Kino.test_panel/2` and `StatifierUI.Kino.palette_panel/2`
  wrap those renderings as `Kino.Markdown` widgets. Like `truth_table/2`
  they need no session and no chart; without the optional `:kino`
  dependency the stubs point at the pure renderers instead.
- `docs/fixture-bundles.md` documents the convention and walks an embedder
  through wiring a palette entry's bundle, discovering a whole palette, and
  running every fragment's expectations in a host suite.

## [0.1.1] 2026-08-24

Documentation-only release: brings the hexdocs to the shared fleet standard.
No code changes.

### Changed

- Unpublishes the ADRs from hexdocs; they remain in the repository under
  `docs/adr/`.
- Fixes the five broken links in the published docs - repo-relative
  references (research doc, ADRs, inspector notebook, architecture's
  research link, LICENSE) now resolve as absolute GitHub URLs or badges.
- Adds a badge row (CI, Hex version, downloads, hexdocs, license) and a
  Documentation index to the README, and corrects the stale claim that the
  project has no CI.
- `mix docs` now builds with zero warnings.

## [0.1.0] 2026-08-22

First release: authoring, observing, and debugging components for the
[statifier](https://hex.pm/packages/statifier) statechart engine, consuming
its effect stream through the language-neutral trace wire format (format
version 1). The Livebook inspector is the first assembled frontend; the
panes underneath it are pure folds any other frontend can render.

### Added

- `StatifierUI.Diagram.render/2` renders a compiled machine and an active
  configuration as Mermaid `stateDiagram-v2` source for `Kino.Mermaid`, with
  composite nesting, parallel regions, active-state highlighting, and
  cross-hierarchy transitions lifted to the composite level with a
  `[lifted: ...]` marker.
- `StatifierUI.EventLog.build/1` folds a trace message stream into a log
  grouped by `(macrostep, round)`, ordered by the producer's stamps rather
  than arrival, and `StatifierUI.EventLog.Markdown.render/2` renders it as
  collapsible Markdown for `Kino.Markdown`, with wire-format indexes
  resolved to state and transition names by `StatifierUI.EventLog.Labels`.
- `StatifierUI.EventInjection.build/1` turns an ADR-0003 fixture bundle
  (or `nil`) into the event-injection pane model: a sorted palette of
  editable event buttons via `StatifierUI.EventInjection.Palette`, a
  `free_form_only?` flag for the fixture-less degraded mode, and
  `send/2`/`send_draft/3` to deliver a `StatifierUI.EventInjection.Draft`
  through `Statifier.Session.send_event/2` - the ordinary recordable input
  path, per statifier ADR-0029.
- `StatifierUI.DatamodelExplorer.build_authoring/3` and `build_live/2` build
  a read-only datamodel tree - document `<data id>` declarations, spec
  5.10.1 system variables, predicator provider functions in scope, and
  either a fixture scenario or a live session's datamodel with entries
  marked `changed?` per macrostep - and
  `StatifierUI.DatamodelExplorer.Markdown.render/2` renders it as Markdown
  for `Kino.Markdown`.
- `StatifierUI.Kino.inspect/3` assembles the Livebook inspector: the
  configuration diagram, datamodel explorer, event injection, and event
  log panes composed over one shared subscriber, live-updating, detaching
  cleanly on cell re-evaluation. Compiled only when the optional `:kino`
  dependency is present.
- `StatifierUI.Trace.Subscriber.attach/3` accepts `catch_up: true`: on a
  session started with `record: true` the missed prefix is replayed into
  the buffer atomically with the subscription (statifier ADR-0049); an
  unrecorded session falls back to live delivery with a `:not_recorded`
  diagnostic the inspector surfaces as "Live-only".
- `StatifierUI.Inspector` - the pure pane-assembly fold the Kino shell
  renders, usable by any other frontend.
- `notebooks/inspector.livemd` - the demo notebook, doubling as the
  milestone's manual acceptance test.
- Serializes statifier's `DatamodelChange` effect as the
  `effect.datamodel_change` wire type, so consumers can observe datamodel
  values as they are written instead of only the variable names
  `session.datamodel` carries. New types are additive under the wire
  format's must-ignore rule.
- Every `effect.*` wire message carries the engine's `round` stamp in
  its envelope, alongside `macrostep` and `microstep`; consumers reading
  older recorded streams must still tolerate `effect.*` messages without
  the key.
