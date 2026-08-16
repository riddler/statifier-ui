# ADR-0002: Adopt upstream statifier and predicator decisions by reference

Status: accepted (2026-08-16)

## Context

This repository visualizes an engine it does not own. The seams a GUI needs -
trace effects, step counters, source locations, replay recordings, pure query
functions - all exist because statifier decided, in its own ADRs, to build
them into the core. Those decisions are settled upstream, in the repositories
that own the code they constrain, and re-arguing them here would produce
either a duplicate record that drifts or a contradiction this repo has no
authority to enforce.

The failure mode this record guards against is concrete: an AI session working
a UI bead hits a gap - a trace effect that does not exist, a counter that is
not granular enough, a location that was dropped - and, seeing only this
repository, "fixes" it here with a shim, a patched dependency, or a local
reinterpretation of the wire data. Every such fix forks the semantics the
upstream ADRs pinned down.

ADR-0001 already establishes the citation convention (qualified names for
other repos' ADRs, e.g. "statifier ADR-0012"). What it does not establish is
which upstream decisions this project treats as binding context, and what
"binding" obligates a session working here to do.

## Decision

The following upstream decisions are **adopted by reference**: this project
treats them as settled premises, cites them by qualified number, and never
re-argues them in its own beads, plans, or ADRs. What each one is, and what
this project inherits from it:

- **statifier ADR-0002 (Port the W3C SCXML algorithm literally, Appendix D).**
  The engine's semantics are the spec's, function for function. This project
  inherits the vocabulary: phase names (`select_transitions`,
  `compute_exit_set`, `compute_entry_set`, `microstep`, ...) are the spec's
  names, and UI features that preview or explain behavior (what-if queries,
  "why didn't this transition fire?") call those functions as-is rather than
  re-deriving statechart semantics client-side.
- **statifier ADR-0003 (Pure functional core returning effects).** The core is
  `(state, event) -> {state, [effect]}`, effects are data, and effect
  interpreters live outside the core. This project inherits its own identity
  from this: a UI is one more effect interpreter, the same kind of thing as
  `Statifier.Session` or a test harness. It also inherits the embedder seam
  ("embedders can supply their own effect interpreter") that later decisions
  such as statifier ADR-0029 build on.
- **statifier ADR-0012 (Debuggability is designed into the core).** The
  observability constraints - microsteps as resumable values, trace effects at
  Appendix D phase boundaries, retained source locations and stable
  document-order identities, stamped step counters - are binding on the
  engine. This project inherits the seams themselves: trace effects for live
  highlighting, counters for timeline ordering, locations and indexes for
  click-through between diagram and source. statifier ADR-0020 refines the
  counter shape (the `(macrostep, round)` ordering key the explorer's debug
  mode renders deltas against) and rides along with this adoption.
- **statifier ADR-0014 (Expression-level spans are part of the
  retained-location constraint).** Expression diagnostics carry spans, the
  span table travels with the compiled instructions in predicator's
  `%Predicator.Compiled{}` envelope, and `error.execution` payloads name the
  owning node, the source string, the predicator error, and its span. This
  project inherits the ability to underline a failing subexpression in the
  editor and annotate guard conditions in the debugger, without inventing its
  own position bookkeeping.
- **statifier ADR-0029 (Session.interpret/2 stays public; replay records four
  inputs).** The one serialized, recordable input path into a live session is
  the seam through which anything - including a UI - feeds a session effects
  the core did not derive. This project inherits an obligation: live
  datamodel edits in debug mode flow through `interpret/2`, never through
  direct writes to a paused session's state, so that a recording stays a
  faithful account of the run.
- **statifier ADR-0034 (Replay re-drives the core, not a live session).**
  Replay is a pure fold over a recording, with no process and no timers, and
  recordings carry ordinal order only. This project inherits the shape of
  time travel: timeline scrubbing consumes replay output as data, and nothing
  UI-side expects to rewind a live session or re-wait original delays.
- **The datamodel commitments in statifier-ex `docs/datamodel.md`, anchored on
  statifier ADR-0004 (Predicator is the datamodel; no ECMAScript, no Elixir
  eval).** The bead that produced this record pointed at "predicator
  commitments from docs/datamodel.md"; that file lives in statifier-ex (there
  is no predicator-ex `docs/datamodel.md`), and it is the living surface for
  the commitments this project leans on: predicator is the expression
  language, evaluation is pure and non-evaluative (predicator ADR-0004: no
  eval, errors are values), expressions compile once at Machine-build time
  into predicator's compiled envelope carrying its own position table
  (predicator ADR-0009), and every evaluation returns
  `{:ok, value} | {:error, reason}`. This is what makes the fixture-driven
  scratchpad evaluator and evaluate-on-every-keystroke completions safe by
  construction, and it is why the datamodel explorer renders predicator
  values, not ECMAScript ones.

**The consequence, stated as the rule it is:** the UI attaches at these seams
and never asks the engine to change for it from here. When a UI need turns
out to require something the engine does not expose - a new trace effect, a
fixture hook, a wider counter, anything - that is engine work, filed as an
`st-` bead in statifier-ex (or `px-` in predicator-ex) under the mirror
discipline in this repo's `CLAUDE.md`, and built there. The bead here waits
on it. However small the patch looks, it is not made from this repository.

**What this decision does not do:**

- It does not freeze the upstream ADRs. They evolve in their own repos by
  their own supersession rules; this record adopts them as they stand at any
  given time, not a snapshot. A session citing one re-reads it upstream
  rather than trusting the summary above.
- It does not adopt every upstream ADR. Upstream process decisions (issue
  tracking, quality gates, worktree workflow) and engine-internal decisions
  not named above are context this project may read, not premises it is
  bound to cite. The list above can grow by amendment when a new upstream
  decision becomes load-bearing for the UI.
- It does not give this repository standing in upstream arguments. Reopening
  a statifier or predicator ADR happens in that repo, through an `st-` or
  `px-` bead, with this repo's need stated as input - not by an ADR here
  declaring the upstream decision wrong.
- It does not decide the wire format. The trace wire format boundary
  (`docs/architecture.md`, "The wire format boundary") sits on top of these
  seams but is its own future decision, not settled by adopting the seams it
  will carry.

## Consequences

- Beads, plans, and reviews here cite "statifier ADR-0012" and stop, instead
  of re-deriving why trace effects exist. Settled questions stay settled
  across model context windows.
- "The engine is not modified from here" has a citable number. A plan step
  that patches statifier or predicator from this repo contradicts an accepted
  ADR and should fail review on that ground alone.
- Engine gaps become visible as cross-repo beads with `mirrors:` lines rather
  than disappearing into local workarounds, which is what keeps the trace
  wire format honest enough to serve a second interpreter someday.
- The adopted list is a maintenance surface: when an upstream ADR named above
  is superseded, the summary here can go stale until someone amends this
  record. Accepted as cheap, since the rule is to re-read upstream anyway.

## Open questions

Recorded rather than resolved by invention:

- The bead's phrase "predicator commitments from docs/datamodel.md" most
  plausibly means statifier-ex `docs/datamodel.md`, which exists and carries
  exactly those commitments; predicator-ex has no such file. This record
  reads it that way. If a predicator-ex datamodel document was intended to
  exist separately, adopting it is an amendment here once it does.
- Whether statifier ADR-0040 (session telemetry event contract) belongs on
  the adopted list once this project consumes session telemetry. Not adopted
  now; nothing here reads it yet.
