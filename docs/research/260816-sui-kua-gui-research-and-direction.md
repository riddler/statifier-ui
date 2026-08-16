---
date: 2026-08-16T09:55:43-0600
researcher: Claude
git_commit: 7bab61ed3a5c284535c4d33630643e8b2d088fdc
branch: main
repository: statifier_ui
beads_issue: sui-kua
topic: "GUI research and direction: authoring, observing, inspecting, and debugging statifier statecharts and predicator expressions"
tags: [research, stately, lucidchart, liveview, codemirror, elkjs, fixtures, wire-format]
status: complete
last_updated: 2026-08-16
last_updated_by: Claude
---

# Research: GUI research and direction

**Date**: 2026-08-16T09:55:43-0600
**Beads Issue**: sui-kua

This document folds in the August 2026 research conversation (held in the
statifier-ex session) that led to this repository existing. It is the source
material the ADR beads cite; the decisions extracted from it are listed at the
end with their owning ADR beads.

## Research question

What should a GUI for authoring, observing, inspecting, and debugging
statifier statecharts and predicator expressions look like - build on an
existing platform (Stately.ai, Lucidchart), adopt an existing tool, or build
custom? And how should such a thing be packaged and distributed for Elixir
hosts?

## Summary

Build custom, debug-first, text-first, as one hex package of LiveView/Livebook
components. Statifier's observability seams (statifier ADR-0012) make a GUI
"just another effect interpreter" - the engine needs nothing changed. No
existing platform survives contact: Lucidchart cannot round-trip, Stately
Studio dropped SCXML, dedicated statechart tools are wrong-platform, and the
Elixir ecosystem has no statechart visualizer at all - which makes a good one
a genuine differentiator.

## Findings

### Statifier is already half a debugger

`statifier-ex/docs/observability.md` (ADR-0012) maps almost one-to-one onto
GUI needs:

| GUI need | Existing seam |
|---|---|
| Live state highlighting | Trace effects at every Appendix D phase boundary, fanned out to subscriber pids at the session boundary |
| Timeline ordering | Every trace effect stamped with `(macrostep, round)` counters (ADR-0020) |
| Click-through to source | Machine retains source locations on states/transitions/content; expressions keep predicator span tables (ADR-0014) |
| Time travel | `record: true` recordings + `Statifier.Replay` make runs reproducible (ADR-0029, ADR-0034) |
| Step debugging | `microstep/1` is a resumable value |
| "What would event X do?" | Pure queries: `select_transitions`, `compute_exit_set`, `compute_entry_set` |

### Stately.ai / XState

- Stately Studio: closed-source SaaS, freemium ($33-199/mo tiers), active
  company as of mid-2026. Imports XState code; exports JS/TS/JSON/Mermaid.
- **SCXML interop is gone**: XState v4's partial SCXML importer was removed
  entirely in v5 ([discussion #4320](https://github.com/statelyai/xstate/discussions/4320)).
  Studio cannot be statifier's authoring surface.
- **The inspector protocol is open and explicitly engine-agnostic**:
  `@statelyai/inspect` streams four JSON event shapes - `@xstate.actor`,
  `@xstate.event`, `@xstate.snapshot`, `@xstate.microstep` - over WebSocket or
  postMessage, with a manual API for non-XState systems
  ([docs](https://stately.ai/docs/inspection)). No non-JS engine has ever
  spoken it. A bridge spike was considered and **dropped by user decision
  (2026-08-16)**; the protocol survives as design inspiration for the wire
  format (sui-w1b).
- Stately Sketch (March 2026): free, MIT, no-login visualizer/simulator for
  XState/JSON/YAML/Mermaid input - useful reference implementation.
- Time travel in the Stately world piggybacks on Redux DevTools; statifier's
  replay recordings are strictly stronger (exact, not approximate).

### Lucidchart

Verdict: **viewer at best, not a foundation**.

- TypeScript extension SDK is real (custom shapes with arbitrary `shapeData`,
  editor panels, data connectors), but there is **no stable structured
  export** - the only structural read-back outside a live editor session is an
  endpoint Lucid disclaims as internal/unstable. Diagram-to-SCXML would ride
  on undocumented internals.
- No semantic enforcement (invalid statecharts draw fine), no
  hierarchical/orthogonal layout, consumer data-linking polls at 30s and is
  Enterprise-gated, platform access requires a Team/Enterprise subscription.
- Zero statechart prior art on the platform.
- Kept in the back pocket: one-way export via Lucid Standard Import JSON
  (well-documented, write-only) for sharing diagrams with non-engineers.

### Landscape

- **Dedicated tools** (itemis CREATE, Quantum Leaps QM, Sketch.systems, Qt
  Creator's SCXML editor): wrong format, wrong platform, or dormant.
  **ScxmlEditor** (alexzhornyak, BSD-3, active) is the best prior art - live
  state highlighting, breakpoints, step mode against a running interpreter
  over UDP. Right UX, wrong stack. scxmlgui (Apache-2.0, Java) similar but
  dormant.
- **Web building blocks**: React Flow (MIT) is the emerging default canvas for
  bespoke statechart editors; **elkjs** (EPL-2.0, ELK layered with
  `hierarchyHandling: INCLUDE_CHILDREN`) is the only credible answer to
  compound-state layout and originated in statechart research tooling
  (KIELER). **Mermaid stateDiagram-v2 is disqualified for execution-accurate
  rendering**: it cannot draw transitions between substates of different
  composite states, which SCXML's LCCA semantics make routine.
  **state-machine-cat** (active, reads and writes real SCXML) covers static
  SCXML-to-SVG. Commercial libraries (JointJS+, GoJS, ~$2,900-3,495/dev) add
  nothing the free stack lacks here.
- **Elixir ecosystem**: a true green field - no gen_statem or statechart
  visualizer exists. LiveDashboard is the architectural pattern for a mounted
  LiveView debug UI; Kino/Livebook the pattern for notebook inspection.
- **Adjacent patterns**: DAP has no statechart vocabulary. The
  PlantUML-preview extension pattern (text pane + live-rendered preview) and
  Devessier's scxml-interpreter web app (paste SCXML, run, stream to an
  inspector) are the proven templates for text-first authoring.

### LiveView packaging (verified against LiveView 1.2.x, mid-2026)

- Distribution units: function components (no client state - chrome only),
  **stateful LiveComponents** (the right unit for hook-driven panes), and a
  full LiveView behind a router macro (LiveDashboard pattern - right for the
  eventual mounted debugger, built from the same components).
- **Colocated hooks (1.1) and colocated CSS (1.2) do not cover third-party
  npm deps** - official docs say libraries with real JS deps still hand-bundle
  or ship source. CodeMirror cannot ride colocation.
- The de facto standard for real JS deps: ship source in `assets/`, host adds
  `"statifier_ui": "file:../deps/statifier_ui"` to `assets/package.json` and
  imports hooks in `app.js` (live_toast, Backpex, live_svelte, live_vue).
  Host's bundler tree-shakes and dedupes. Fallback for zero-npm hosts: a
  precompiled ESM in `priv/static` (live_monaco_editor pattern).
- **Livebook uses CodeMirror 6, not Monaco** (migrated after the CM6 rewrite
  landed; maintains `codemirror-lang-elixir`). CM6's modularity is why
  source-recompile beats a precompiled blob.
- Runtime hooks (`bundle="runtime"`, new) solve the inverse problem
  (host cannot extend a library's bundle) - noted, not needed.

### Datamodel explorer and fixtures

Predicator is dynamically typed with no eval, so authors get zero ambient
help about what is in scope. What is knowable comes in three tiers:

1. **Static from the document**: `<data id>` declarations on the compiled
   Machine; initial values evaluable.
2. **Static from the platform**: system variables with spec-fixed shapes
   (`_sessionid`, `_name`, `_ioprocessors`, `_event` with its 5.10.1 fields -
   `Statifier.Evaluator.SystemVariables` is literally the schema), and
   predicator function providers enumerable today via the `Provider`
   behaviour's `functions/0` callback (`name -> {arity, impl}`), covering
   built-ins and host-registered providers alike. Richer metadata (param
   names, return shapes, docs) is an upstream predicator seam - a mirror bead
   there if wanted, never work here.
3. **Host-only**: initial data, `_event.data` shapes per event, host function
   return values. Unknowable statically - fixtures fill this tier.

The fixture bundle (named scenario datamodels + example events keyed by event
name with sample payloads) powers four features from one artifact: the
explorer tree, editor completions/hover (context-sensitive - inside
`<transition event="payment.success">`, `_event.data.` completes from that
event's fixture), the scratchpad evaluator (safe on every keystroke -
predicator evaluation is pure and sandboxed), and the simulator event palette
(without fixtures a simulator can only fire empty events).

Types are **inferred shapes from example values**, not a declared schema
language - examples are concrete and evaluable; schemas optional later.
Fixture-aware linting falls out: walk compiled instruction streams for
identifier references nothing provides ("`user.tier` referenced in the guard
at line 23, but no scenario or event fixture defines it") - catching the
most common statechart bug (typo'd path, silently `:undefined`) at author
time.

The explorer is one component, two modes: authoring mode shows fixture scope
with example values editable in place; debug mode shows the paused session's
live datamodel with per-step deltas. Live datamodel edits are technically
trivial (machine_state is a value) but must flow through a recordable input
channel (statifier ADR-0029's `interpret/2` batch seam) or replay determinism
silently breaks.

## Decisions extracted (owning bead in parentheses)

- Text-first authoring; visualization is read-only (sui-z8y).
- Language-neutral JSON trace wire format, specified as a document; LiveView
  is one carrier (sui-w1b). Motivated by the riddler vision: one UI, many
  interpreter language stacks - which is also why this repo carries no `-ex`
  suffix.
- Fixtures as the example-data contract, behaviour + sidecar delivery
  (sui-8a7).
- CodeMirror 6, source-recompile JS distribution via `file:../deps/`
  (sui-8tj).
- Client-side elkjs layout rendering plain SVG; no React (sui-p61).
- One hex package; core depends only on statifier (github dep until statifier
  publishes); `kino` and `phoenix_live_view` both optional (sui-8di). MIT.
- First milestone: the Livebook inspector (sui-t36). Stately bridge dropped.
- No CI; local gates only, realistic (not statifier-100%) thresholds
  (sui-d5m). Sole contributor.
- Statifier-side needs (trace emission gaps, fixture hooks) get filed in the
  `st-` tracker with `mirrors:` links, never implemented from here (sui-652).

## Phasing (as discussed; only the first is committed)

1. **Livebook inspector** (sui-t36) - Kino widget: configuration rendering,
   `(macrostep, round)` event log, fixture-fed event injection, datamodel
   explorer. Needs only statifier + kino.
2. LiveView editor + viewer LiveComponents - CM6 pane with validator
   diagnostics as lint gutters; elkjs SVG viewer; hover-sync both directions
   via source locations and `t_index` data attributes.
3. Mounted debugger (router macro) - live configuration highlighting,
   timeline scrubbing over replay recordings, what-if previews from the pure
   queries, guard-condition annotation from predicator spans ("why didn't
   this transition fire?" answered at a glance).
4. Authoring polish - simulation is the debugger pointed at an ephemeral
   session; canvas editing only if users ever demand it.

## Open questions

- Wire-format spec home: starts here; may graduate to
  riddler_spec/statifier_spec territory once a second interpreter exists.
- Fixture sidecar file naming/shape (`<chart>.fixtures.json`?) - settle in
  sui-8a7.
- Whether the Livebook inspector's first rendering is Mermaid (accepting the
  cross-hierarchy limit, temporarily) or waits for the elkjs renderer -
  settle in sui-t36.

## Key sources

- statifier-ex `docs/observability.md`, `docs/architecture.md` (ADR-0012,
  -0002, -0003, -0014, -0020, -0029, -0034)
- https://stately.ai/docs/inspection - inspector event shapes
- https://github.com/statelyai/xstate/discussions/4320 - SCXML dropped in v5
- https://developer.lucid.co/docs/lucid-extension-api - Lucid SDK
- https://github.com/alexzhornyak/ScxmlEditor-Tutorial - best SCXML debugger prior art
- https://eclipse.dev/elk/reference/options/org-eclipse-elk-hierarchyHandling.html
- https://github.com/BeaconCMS/live_monaco_editor - editor-as-hook packaging prior art
- https://hexdocs.pm/live_toast/readme.html - `file:../deps/` distribution pattern
- https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.ColocatedJS.html - colocation limits
- https://github.com/livebook-dev/codemirror-lang-elixir - Livebook's CM6 grammar
