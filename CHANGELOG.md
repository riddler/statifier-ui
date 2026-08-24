# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

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
