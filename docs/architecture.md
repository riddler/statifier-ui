# Architecture

This document describes the layers of statifier-ui: what each piece is for,
how they depend on one another, and where the boundary sits between this
repository and the engine it visualizes. It describes intended design, not
only what is built. The repository is presently a scaffold - see "What exists
today" below for the line between built and planned.

The direction summarized here was settled in
[`docs/research/260816-sui-kua-gui-research-and-direction.md`][research]
("the research doc"); this document narrates the resulting shape rather than
re-arguing it. Decisions are cited by ADR number - bare numbers are this
repo's (see `docs/adr/`), and other repositories' ADRs are cited by name, for
example "statifier ADR-0012".

## Contents

- [Two things that shape everything](#two-things-that-shape-everything)
- [What exists today](#what-exists-today)
- [The fixtures contract](#the-fixtures-contract)
- [The LiveComponents](#the-livecomponents)
- [The datamodel explorer's two modes](#the-datamodel-explorers-two-modes)
- [The wire format boundary](#the-wire-format-boundary)
- [The JS strategy](#the-js-strategy)
- [The router-macro debugger](#the-router-macro-debugger)
- [The dependency rule](#the-dependency-rule)
- [Open questions](#open-questions)

## Two things that shape everything

**Text-first.** SCXML is the source of truth, and the visualization reads it.
The diagram is an output, not an editor backed by its own model - there is no
shadow representation that a canvas mutates and SCXML gets generated from.
Editing happens in the text; the diagram, the explorer, and the debugger all
render what the text (and, in debug mode, the running session) says. This is
why the CodeMirror pane is the editing surface and the SVG viewer is
described below as read-only.

**The engine is not modified from here.** Statifier already emits trace
effects at every Appendix D phase boundary, stamps them with
`(macrostep, round)` counters (statifier ADR-0020), and retains source
locations on states, transitions, and expressions (statifier ADR-0014). A UI
is one more interpreter of those effects, the same way a debugger client is
one more interpreter of a running process's events. When a GUI need turns out
to require something the engine does not yet expose - a new trace effect, a
fixture hook, anything - that need is engine work, filed as an `st-` bead in
the statifier-ex tracker and built there, never patched in from this
repository. See "Beads that span repositories" in this repo's `CLAUDE.md`.

The research doc's finding that motivates both: statifier's observability
seams (statifier ADR-0012) already map almost one-to-one onto GUI
requirements - trace effects for live highlighting, macrostep/round counters
for timeline ordering, source locations for click-through, replay recordings
(statifier ADR-0029, statifier ADR-0034) for time travel, and pure query
functions for "what would event X do?" previews. The engine was not built for
a GUI, but it was built observable enough that a GUI needs no new engine
capability to get started.

## What exists today

As of this writing one thing is built and the rest is scaffold. The scaffold
is the packaging: `mix.exs` declares the `statifier` dependency (a git
dependency until statifier-ex publishes to hex) and the two optional
integrations, `kino` and `phoenix_live_view`, and `lib/statifier_ui.ex` is
the top-level module with its `@moduledoc` and a `version/0` function.

What is built is the fixtures contract described below, plus the trace
plumbing described under "The wire format boundary." `lib/statifier_ui/`
holds fifteen core modules, none of which reference `Kino` or
`Phoenix.LiveView`:

- `StatifierUI.Fixtures` - the consumed struct and its validation.
- `StatifierUI.Fixtures.Source` - the behaviour a host module implements to
  supply fixtures from Elixir.
- `StatifierUI.Fixtures.Sidecar` - the `<chart>.fixtures.json` loader for
  corpus and CLI use.
- `StatifierUI.Fixtures.Lint` - ADR-0006's lint over datasets and
  expressions: an expression matching no guard, and an `expect` key naming
  no dataset, both reported as warnings.
- `StatifierUI.Fixtures.Expectations` - ADR-0006's executable-expectations
  runner: evaluates every `expect` entry against its named dataset and
  reports whether the stated value held.
- `StatifierUI.TruthTable` - ADR-0006's result matrix: every expression
  evaluated across every dataset, with a six-way verdict per cell.
- `StatifierUI.TruthTable.Markdown` - renders that matrix as Markdown, in
  either orientation.
- `StatifierUI.Value` - the codec for ADR-0005's `$`-tagged JSON encoding of
  predicator values, used by the sidecar loader.
- `StatifierUI.Shape` - pure shape inference from an example value to a
  display-type label, independent of the fixtures modules.
- `StatifierUI.Trace.Message` - the wire-format envelope struct and its
  `to_map/1` rendering.
- `StatifierUI.Trace.Json` - the canonical, byte-comparable JSON encoder for
  trace messages.
- `StatifierUI.Trace.Normalizer` - the pure mapping from engine effects to
  `StatifierUI.Trace.Message` structs.
- `StatifierUI.Trace.Manifest` - builds the `session.start` definition
  message from a compiled machine.
- `StatifierUI.Trace.Buffer` - the fixed-capacity, drop-oldest message store
  a chatty session buffers into.
- `StatifierUI.Trace.Subscriber` - the `GenServer` that attaches to a live
  `Statifier.Session`, stamps `seq`, and fans messages out to listeners.

Two integration layers have since been built on top of that core, and the
module list above is no longer the whole of `lib/`. The Livebook inspector
(`StatifierUI.Kino` over the pure `StatifierUI.Inspector`) is phase 1 below.
The read-only **ops view** - `StatifierUI.Live`'s function components over
`StatifierUI.Live.State`, the current-state diagram and the run-history
event log over a live or persisted trace stream - is a first slice of phase
2, written for a host's admin and support screens rather than for authoring;
`docs/ops-embedding.md` is its guide. Both integrations keep their optional
dependency behind a compile-time `Code.ensure_loaded?/1` guard, as ADR-0004
requires, and both are pure folds underneath.

Still true: no JS asset exists yet, and none of the three authoring
LiveComponents described below is built - the ops view's diagram pane emits
`StatifierUI.Diagram`'s Mermaid source for a host-supplied client, not the
elkjs SVG the viewer will eventually draw. Everything described below past
this section is intended design, tracked by beads and phased as summarized
under "Phasing" in the research doc:

1. The Livebook inspector (a Kino widget - configuration rendering, event
   log, fixture-fed event injection, datamodel explorer).
2. LiveView editor and viewer LiveComponents.
3. The mounted router-macro debugger.
4. Authoring polish (simulation, and canvas editing only if ever demanded).

Only the first is currently committed to; the rest is directional.

## The fixtures contract

Predicator (the expression language statifier evaluates guards and content
against) is dynamically typed with no eval, so an author gets no ambient
information about what is in scope while writing a guard or an assignment.
The research doc identifies three tiers of what is knowable about a
statechart's datamodel:

1. **Static from the document.** `<data id>` declarations on the compiled
   Machine, and their initial values, are evaluable directly - no fixture
   needed.
2. **Static from the platform.** System variables have spec-fixed shapes
   (`_sessionid`, `_name`, `_ioprocessors`, and `_event` with its SCXML
   5.10.1 fields), and predicator function providers are enumerable today
   via the `Provider` behaviour's `functions/0` callback. This tier is also
   knowable without a fixture.
3. **Host-only.** Initial data supplied by the host, the shape of
   `_event.data` for a given event, and host function return values are not
   statically knowable at all - only the host that will eventually run the
   chart knows them.

A **fixture** is what fills tier 3: a named scenario datamodel plus example
events keyed by event name with sample payloads, authored alongside a chart.
Types are inferred from example values rather than declared through a schema
language - examples are concrete and immediately evaluable, and a schema
layer is left as a possible later addition rather than a prerequisite.

One fixture bundle is meant to power four features from a single artifact:

- the datamodel explorer tree, in authoring mode (see below),
- editor completions and hover, made context-sensitive by which fixture is
  in scope (for example, inside `<transition event="capture.settled">`,
  `_event.data.` completions come from that event's fixture),
- a scratchpad evaluator that can safely evaluate on every keystroke, since
  predicator evaluation is pure and sandboxed,
- a simulator's event palette - without fixtures a simulator can only fire
  events with empty payloads.

The bundle carries two more maps, both additive and both optional (ADR-0006):
**datasets** are named, reusable example datamodels for evaluating
expressions against - smaller in intent than a scenario, and named so a
truth table's columns read as situations a human recognizes
(`"variant-a-early"`, `"variant-b-complete"`) rather than inline duplicates.
**Expressions** are named,
free-standing predicator source strings paired with an `expect` map keyed by
dataset name, each entry a claim ("this expression evaluates to `true` under
this dataset") a test suite can check rather than merely assert in prose.
Datasets are shared across expressions rather than inlined per expression
because a truth table is only a matrix when its columns are the same named
situations for every row; inlining would duplicate the same situation into
every expression that needs it, and the copies would drift apart. An
expression is matched to a chart's guards by source-text equality only -
never by `t_index` or any other position - because a compiled transition's
index is a document-order position that shifts under an unrelated edit
earlier in the chart, while the author-written source text is the one
identity that survives reformatting the chart around it.

Fixture-aware linting is a corollary rather than separate machinery: walking
the compiled instruction stream for identifier references that no scenario
or event fixture defines catches the common statechart bug of a typo'd path
that silently evaluates to undefined, at author time rather than at run
time. `StatifierUI.Fixtures.Lint` is ADR-0006's own lint over the two new
maps - an expression matching no guard, and an `expect` key naming no
dataset - both reported as warnings rather than errors, since neither is a
defect of the contract on its own. `StatifierUI.Fixtures.Expectations` is
ADR-0006's executable side: it evaluates every `expect` entry against its
named dataset and reports whether the stated value held, so a host wires it
into its own test suite and fixture documentation goes red the moment it
drifts from what its expressions actually evaluate to.

`StatifierUI.TruthTable` is the reading surface over the same two maps, and
asks the complementary question: not "did every stated expectation hold" but
"what does every expression actually evaluate to under every dataset",
whether or not an expectation was stated. Its cells carry a six-way verdict
rather than a boolean, because predicator's `undefined` is a third truth
value and sparse example records make it the common case: an encoding where
`:undefined` can be reached through Elixir truthiness is an encoding where a
reader eventually sees it as `false`, which is the misreading a truth table
exists to prevent. `StatifierUI.TruthTable.Markdown` renders the matrix with
each cell's value spelled out as a word and emphasis added on top of it, so
the three values stay three even where styling does not render.

`StatifierUI.Fixtures.Bundle` addresses the same bundle by **fragment name**
rather than by chart path, for an embedder composing charts from a palette of
reusable fragments: the fragment is a module or a palette entry, the chart it
will land in does not exist yet, and its examples still have to travel with
it. It adds no fixture shape - a bundle's `fixtures` field is the same struct
both ADR-0003 delivery paths produce - only identity, provenance, and
discovery, over a palette of modules or a directory of sidecars. The two
delivery paths reappear one level up as `discover/2` and `discover_dir/2`,
and neither is all-or-nothing: one fragment's malformed bundle is reported
against that fragment and the rest still load.
`StatifierUI.Fixtures.Bundle.Markdown` renders one fragment's panel as its
truth table plus its expectation results - the reading surface and the
checking surface together, since neither alone tells an author what a step
does and what it was meant to do. See `docs/fixture-bundles.md`.

Fixtures are how a chart moves between statifier-ex and this repository:
statifier-ex is the engine and the compiler, and does not need fixtures to
run a chart; this repository is the consumer that needs example data to
render anything more than the static structure. The concrete delivery
mechanism is a behaviour plus a sidecar file, per the research doc's
summary, and both paths converge on the one struct ADR-0003 names:

- `StatifierUI.Fixtures.Source` is the behaviour a host module implements
  (`scenarios/0`, `example_events/0`) to supply fixtures from Elixir.
- `StatifierUI.Fixtures.Sidecar` reads the `<chart>.fixtures.json` file for
  corpus and CLI use.
- Both paths produce a `StatifierUI.Fixtures` struct, so a consumer never
  needs to know which one produced it.
- `StatifierUI.Shape` turns any example value - from a fixture or from a
  live datamodel - into the display-type label the explorer tree and editor
  completions use.

How the sidecar file is named and how predicator values are encoded as
`$`-tagged JSON are settled by ADR-0003 and ADR-0005 respectively, and the
two additive maps described above are settled by ADR-0006; see those ADRs
for the reasoning.

## The LiveComponents

The GUI is built from three LiveComponents, each a distribution unit in
LiveView's sense: a stateful component that owns its own hook-driven client
state, as opposed to a stateless function component (chrome only) or a full
LiveView mounted behind a router (the debugger, described later).

**The editor pane.** A CodeMirror 6 pane over the chart's SCXML source.
CM6 was chosen (research doc, "LiveView packaging") because Livebook itself
moved to CM6 and maintains `codemirror-lang-elixir`, and because CM6's
modular architecture is what makes source-recompile distribution (below)
practical where a monolithic editor bundle would not be. The editor is where
authoring happens - validator diagnostics surface as lint gutters, and
completions and hover draw on fixtures as described above. Consistent with
text-first, the editor pane is the place edits are made; nothing generates
SCXML on the author's behalf from a diagram.

**The SVG viewer.** Renders the compiled statechart as an SVG diagram, laid
out client-side by elkjs (`hierarchyHandling: INCLUDE_CHILDREN`), chosen
because ELK is, per the research doc, "the only credible answer to
compound-state layout" and because Mermaid's `stateDiagram-v2` is disqualified
for execution-accurate rendering (it cannot draw transitions between
substates of different composite states, which SCXML's LCCA semantics make
routine). The viewer is read-only: it is an output of the text, not an editor
with its own model, and it hover-syncs with the editor pane in both
directions using source locations and `t_index` data attributes rather than
any diagram-side notion of chart identity.

**The datamodel explorer.** One LiveComponent, not two - a single component
with two modes, described in its own section below because the two-mode
design is load-bearing for how it is built, not just how it is skinned.

All three are meant to compose into the router-macro debugger described
below, in the same way LiveDashboard assembles panels from independent
LiveComponents behind one mounted LiveView.

## The datamodel explorer's two modes

The explorer is **one component with two modes**, not two components,
because the two modes render the same three-tier information described
under "the fixtures contract" - only the source of tier-3 data changes
between them.

**Authoring mode** shows fixture scope: the named scenario datamodel and
example event payloads from the chart's fixture bundle, with example values
editable in place. There is no running session in this mode; what is shown
is exactly what a fixture declares.

**Debug mode** shows a paused session's live datamodel, sourced from trace
effects rather than from a fixture, with per-step deltas rendered against the
`(macrostep, round)` counters that order every trace effect (statifier
ADR-0020). Where authoring mode shows what an author declared could happen,
debug mode shows what did happen, step by step.

The two modes share a renderer for the same tiered value tree because tiers
1 and 2 (document-static and platform-static values) are identical in both
modes; only tier 3 switches source, from fixture example data to the actual
running datamodel.

Live datamodel edits in debug mode are a case the research doc calls out
explicitly: editing a paused session's `machine_state` is technically
trivial, since it is an ordinary value, but an edit made by writing to that
value directly would silently break replay determinism. Per statifier
ADR-0029, live edits must flow through statifier's recordable
`interpret/2` batch input channel - the same channel every other event
delivered to a running session goes through - so that a replay recording
stays a complete, faithful account of everything that happened to the
session. The explorer never mutates a live session's state outside that
channel.

## The wire format boundary

Trace effects are the seam a GUI reads (see "Two things that shape
everything," above), and this repository's boundary with statifier-ex is a
**wire format**, not an in-process API: statifier emits trace effects, and
this repository (or, eventually, another interpreter entirely) consumes them
as data. The research doc frames the target as a language-neutral JSON trace
wire format, specified as its own document, with LiveView being one carrier
among possible others rather than the format's definition.

This is also why the repository carries no `-ex` suffix, unlike statifier-ex
and predicator-ex: the wire format is meant to outlive any one language
binding. The riddler-project vision the research doc cites is one UI capable
of eventually serving interpreters written in other stacks, not only
statifier-ex - the same way a debug adapter protocol serves many language
backends. The research doc also records that a design considered and
dropped was bridging to Stately.ai's `@statelyai/inspect` protocol; that
protocol's four JSON event shapes (`@xstate.actor`, `@xstate.event`,
`@xstate.snapshot`, `@xstate.microstep`) survive only as design inspiration,
not as a dependency or a target to interoperate with.

The format itself - envelope, event types, versioning, and the rule that
structs and LiveView payloads are carriers rather than the definition - is
settled by ADR-0005, and `docs/wire-format.md` is its normative home: when
the document and an implementation disagree, the document is what
conformance means. The first producer is `StatifierUI.Trace.Normalizer`,
which maps engine effects to `StatifierUI.Trace.Message` structs matching
the document field for field; `StatifierUI.Trace.Manifest` builds the
`session.start` message the same way; `StatifierUI.Trace.Json` renders
either to the document's canonical, byte-comparable JSON; and
`StatifierUI.Trace.Subscriber`, backed by `StatifierUI.Trace.Buffer`, is the
process that attaches to a live session and produces the stream from those
pieces.

## The JS strategy

Two toolchain facts shape how JavaScript ships from this repository, both
stated in this repo's `CLAUDE.md` and confirmed by the research doc's
"LiveView packaging" findings:

- **No Node in this repo's toolchain.** `mise.toml` does not provision Node.
  This repository's own gate never runs a JS bundler.
- **JavaScript ships as source**, and a host's own esbuild compiles it. The
  research doc found that LiveView's colocated hooks (1.1) and colocated CSS
  (1.2) explicitly do not cover third-party npm dependencies - the official
  LiveView documentation states that libraries with real JS dependencies
  still need hand-bundling or source distribution. The de facto pattern
  among comparable LiveView component libraries (`live_toast`, `Backpex`,
  `live_svelte`, `live_vue`) is for the host to add
  `"statifier_ui": "file:../deps/statifier_ui"` to the host's own
  `assets/package.json` and import the hooks from `app.js`; the host's
  bundler then tree-shakes and dedupes the dependency tree, including
  CodeMirror, which cannot ride colocation because of its own modular
  dependency graph.

The research doc also notes a fallback, used elsewhere in the LiveView
ecosystem (`live_monaco_editor`) for zero-npm hosts: shipping a precompiled
ESM bundle from `priv/static`. It is recorded here as a documented fallback
pattern, not as a commitment this repository has made; nothing in the
sources says whether statifier-ui itself will offer it.

## The router-macro debugger

The eventual mounted debugger is a full LiveView behind a router macro, in
the LiveDashboard architectural pattern the research doc identifies:
LiveDashboard's own approach - a host mounts a debugger by adding one line
to its router, and the mounted LiveView assembles independent panels - is
the intended shape for the third distribution unit named under "The
LiveComponents," above, built from the same editor, viewer, and explorer
components rather than duplicating them behind the router boundary.

The research doc's phasing describes the debugger's intended capabilities:
live configuration highlighting (states currently active), timeline
scrubbing over replay recordings, what-if previews built from statifier's
pure query functions (`select_transitions`, `compute_exit_set`,
`compute_entry_set`), and guard-condition annotation from predicator span
tables answering "why didn't this transition fire?" at a glance. None of
this is built; it is phase 3 of 4 in the phasing the research doc records,
after the Livebook inspector and the LiveView editor/viewer components.

## The dependency rule

Stated explicitly, because it governs how every module under `lib/` is
written, not only how `mix.exs` is structured: **core depends on statifier
only.** `Kino` and `Phoenix.LiveView` are both genuinely optional
dependencies (`mix.exs` marks both `optional: true`), and "optional" is
enforced at compile time, not only at the dependency-resolution level.
Anything under `lib/` that touches `Kino` or `Phoenix.LiveView` has to
tolerate that dependency's absence when the application compiles - a host
that wants the Livebook inspector must not be made to pull in LiveView, and
a host that wants the LiveView components must not be made to pull in Kino.
This is stated in this repo's `CLAUDE.md` conventions and is one of the
decisions the research doc extracts directly: "one hex package; core depends
only on statifier ... `kino` and `phoenix_live_view` both optional."

The practical consequence for every LiveComponent, Kino widget, or shared
module added later is that any reference to `Kino.*` or `Phoenix.LiveView.*`
needs to be guarded (for example, behind `Code.ensure_loaded?/1` or an
equivalent compile-time check) rather than assumed present, and that shared
logic used by both integrations - trace effect handling, fixture parsing,
the datamodel tiering described above - belongs in modules that reference
neither.

## Open questions

These are gaps the bead implies but that the research doc and existing ADRs
do not settle. They are recorded here rather than resolved by invention:

- **Whether the Livebook inspector's first rendering uses Mermaid** (accepting
  the cross-hierarchy limitation noted under "The LiveComponents," above,
  temporarily) **or waits for the elkjs renderer.** The research doc flags
  this as open, to be decided in sui-t36.
- **The zero-npm fallback's status for this repository specifically.** The
  research doc records the precompiled-ESM pattern as prior art elsewhere in
  the ecosystem (`live_monaco_editor`) but does not state whether
  statifier-ui commits to offering it alongside the `file:../deps/` source
  path, or only the latter.

[research]: https://github.com/riddler/statifier-ui/blob/main/docs/research/260816-sui-kua-gui-research-and-direction.md
