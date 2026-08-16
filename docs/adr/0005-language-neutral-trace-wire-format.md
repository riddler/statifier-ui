# ADR-0005: Language-neutral trace wire format

Status: accepted (2026-08-16)

## Context

This repository's boundary with the engine is a wire format, not an
in-process API (`docs/architecture.md`, "The wire format boundary"). The
research doc frames the target: a language-neutral JSON trace format,
specified as its own document, with LiveView one carrier among possible
others. The riddler vision behind it is one authoring/admin UI driving
conformant interpreters in multiple language stacks - the reason this repo
carries no `-ex` suffix (ADR-0004). A future statifier-rb or statifier-go
that emits the format drives the same inspector for free, the way a debug
adapter protocol serves many language backends.

What the format has to carry is already settled upstream and adopted here by
ADR-0002. Statifier emits trace effects at the phase boundaries Appendix D
names (statifier ADR-0012; the nine-row vocabulary in statifier-ex
`docs/observability.md` constraint 2: event dequeued, transitions selected,
exit set, content executed, entry set, macrostep stable, done, invoke pass,
finalize/autoforward pass). Every trace payload is stamped with
`macrostep`/`microstep`/`round` counters (statifier ADR-0020), and wherever
it names an entity it carries a constraint-3 identity - a state index, a
`t_index`, a `c_index` - never a resolved struct; tooling maps identities
back to source locations through tables the compiled Machine retains.
Statifier-ex's own observability page lists "debug protocol or wire format"
as an explicit non-goal, so the serialization seam is this project's to
define - which is exactly the situation ADR-0002 exists for: build on the
seams, never ask the engine to change for it from here.

The nearest prior art is `@statelyai/inspect`, whose four JSON event shapes
(`@xstate.actor`, `@xstate.event`, `@xstate.snapshot`, `@xstate.microstep`)
are open and engine-agnostic. The research doc records that bridging to it
was considered and dropped by user decision (2026-08-16); it survives as
design inspiration only.

The failure mode this record guards against: the Livebook inspector
(sui-t36) ships first, its Kino widget consumes Elixir effect structs
directly, and the de facto protocol becomes "whatever the structs serialize
to" - Elixir atoms, MapSets, and struct names leaking into a contract a
second interpreter could never meet.

## Decision

**The trace protocol is a language-neutral JSON wire format, normatively
defined by a specification document in this repository:
`docs/wire-format.md`.** The document does not exist yet; it is written by
the implementation bead that builds the first producer, and this record
settles its home, its envelope, and its commitments. Naming the file is
intent, in the same sense as ADR-0003's module names. Everything else -
Elixir effect structs, LiveView payloads, Kino rendering, any future
carrier - is a producer, carrier, or consumer of the format, never its
definition. When the spec and an implementation disagree, the spec is what
conformance means.

**The envelope.** Every message is a JSON object carrying, regardless of
type:

- `type`: a dotted-namespace string. The nine trace effects map one-to-one
  onto `trace.*` types named for the upstream vocabulary
  (`trace.event_dequeued`, `trace.transitions_selected`, `trace.exit_set`,
  `trace.content_executed`, `trace.entry_set`, `trace.macrostep_stable`,
  `trace.done`, `trace.invoke_pass`, `trace.finalize_autoforward`).
  Non-trace effect families (`log`, `done`, `budget_exhausted`, the
  send/invoke family) get their own namespaces as consumers need them.
- `session`: the emitting session's id (the `_sessionid` value), so streams
  from an invoke tree of sessions can share one channel.
- `seq`: a per-session monotonic integer assigned by the producer in
  emission order. The engine guarantees effect-list order (statifier
  ADR-0012: no side channel); `seq` is that order made explicit on the
  wire, where a list has become a stream.
- On every `trace.*` message, the three counters as integers: `macrostep`,
  `microstep`, `round`. `(macrostep, round)` remains the timeline ordering
  key (statifier ADR-0020); `seq` totally orders within it.
- Identities as the engine emits them - state indexes, `t_index`,
  `c_index`, `invokeid` - never resolved nodes, and never per-event source
  locations. Locations resolve through the definition message below.

**A stream opens with a definition message** (working type
`session.start`), the format's analog of `@xstate.actor`: the spec version,
the session id, the chart source (SCXML), and the identity tables the
compiled Machine retains - state index to id and location, `t_index` and
`c_index` to location. This is what makes indexes on later messages
resolvable by a consumer that has no compiler, and it is why events
themselves stay small.

**JSON discipline, because the engine's values do not all map trivially:**

- `_event.data` distinguishes `:undefined` (no data) from `nil` (data,
  present, null) from `%{}` (data, empty). On the wire: key absence is "no
  data", JSON `null` is present-and-null. No carrier may collapse them.
- Set-valued fields (configurations, exit/entry sets) serialize as arrays
  in a canonical order (ascending index), so two traces of the same run are
  byte-comparable.

**Versioning.** The definition message carries an integer `"version"`,
initially `1` (the fixtures sidecar's convention, ADR-0003). Consumers must
ignore unknown fields and unknown `type`s; additive change is therefore not
a version bump, and a bump means a consumer of the old version would
misread the stream. A conformant producer **must** emit the definition
message and, when tracing is enabled, the nine `trace.*` types at their
boundaries with the envelope fields above; it **may** emit further effect
families and additional fields.

**Where `@statelyai/inspect` informs the shape, and where it does not.**
The actor/event/snapshot triple maps: `session.start` is the actor
announcement, `trace.event_dequeued` is the event, and
`trace.macrostep_stable` carries the full configuration at quiescence -
the snapshot moment. The fit ends at `@xstate.snapshot`'s center of
gravity: inspect is snapshot-per-event, leaving consumers to diff, because
XState has no counters and no phase boundaries to publish. Statifier's
model is the opposite - deltas at named Appendix D boundaries, stamped and
ordered - so this format is delta-first with a configuration snapshot at
quiescence, and `@xstate.microstep` corresponds not to one type here but to
the whole `trace.*` family between two stable points.

**Trace output is fixture-checkable.** A chart, a fixture bundle
(ADR-0003), and an event script determine a trace, and the trace serialized
in this format is plain data - so golden-trace tests (produce, compare
bytes) are the format's own conformance mechanism, the same move as the
conformance corpus (statifier ADR-0006). The canonical-order rule above is
what makes byte comparison honest. And the fixtures sidecar question
ADR-0003 left to this record is settled **yes**: the sidecar's JSON shape
joins `docs/wire-format.md` as a companion contract, keeping its own
`version` field, so a non-Elixir interpreter shares fixture files as well
as traces.

**The Elixir producer lives here.** The mapping from
`Statifier.Effect.Trace.*` structs to wire JSON is statifier-ui code,
attached at the session subscription boundary (statifier ADR-0012 seams,
via ADR-0002). The engine is not asked to learn JSON.

**What this decision does not do:**

- It does not decide transport. WebSocket, LiveView push, Kino frame,
  file of JSON lines - carriers all, each an implementation bead's call.
- It does not decide subscription, filtering, or backpressure. Whether a
  consumer can ask for "only `trace.macrostep_stable`" is a carrier
  concern.
- It does not enumerate every field of every message. The envelope and the
  type set are settled here; field-by-field schemas are the spec document's
  content, written against the engine structs when the first producer is
  built.
- It does not give replay recordings a wire shape. Recordings are inputs
  (statifier ADR-0029, ADR-0034), not traces; whether they join the spec
  is a future question the format's JSON discipline keeps open.
- It does not move the spec out of this repo. Graduation to
  riddler_spec/statifier_spec territory once a second interpreter exists
  remains the anticipated path (research doc, "Open questions"); until
  then `docs/wire-format.md` is the normative home.

## Consequences

- The Livebook inspector and the LiveView components are built as two
  consumers of one format from day one, which is the cheap moment to
  enforce it; retrofitting a wire boundary under a shipped struct-coupled
  UI is the expensive path this record forecloses.
- A second interpreter's cost of entry is written down: emit the definition
  message and nine event types with counters and identities, and the
  inspector works. Conformance is checkable by golden trace, not by
  reading Elixir.
- Every UI feature pays a serialization toll even in-process, and the
  definition message duplicates data (source, tables) a co-located
  consumer already has. Accepted: the toll is the contract, and carriers
  may negotiate not to resend what a consumer holds, so long as the
  format's meaning never depends on that shortcut.
- The spec document is a second place the trace vocabulary lives, and it
  can drift from the engine's. The golden-trace mechanism is the drift
  alarm; an upstream vocabulary change that breaks it is handled as
  ADR-0002 prescribes, in the open, not by a quiet local patch.
- The must-ignore rule means a consumer silently skips types it does not
  know - a debugging hazard when a typo'd `type` is dropped instead of
  flagged. Accepted as the standard price of forward compatibility;
  carriers may surface unknown-type counts.

**Alternatives considered:**

- **Adopt `@statelyai/inspect` outright**: already dropped by user decision
  in the research phase - no non-JS engine has ever spoken it, it has no
  macrostep/round counters, no source locations, no SCXML vocabulary, and
  its snapshot-per-event model discards exactly the phase-boundary
  structure statifier emits. Kept as inspiration only.
- **Elixir structs as the de facto protocol** (serialize
  `Statifier.Effect.Trace.*` as-is): cheapest first inspector, but atoms,
  MapSets, and module names are not a contract another stack can meet, and
  the format would be defined by whatever the structs happen to be.
  Rejected; it is the failure mode named in Context.
- **A binary or schema-IDL format** (protobuf and kin): tighter wires,
  but imports a toolchain into every would-be interpreter, defeats
  eyeball-debuggability and golden-trace diffing, and optimizes a channel
  nothing here has measured as slow. Rejected; JSON is the format the
  fixtures sidecar and the corpus already speak.
- **Spec upstream in statifier-ex now**: statifier-ex declares the wire
  format a non-goal, and a spec next to one engine reads as that engine's
  serialization. Starting here keeps the language-neutral claim honest;
  graduation later is already the recorded path. Rejected for now.

**Open questions carried, not resolved here:**

- Whether `seq` is stamped by the producer at the session boundary or by
  the carrier at delivery - equivalent for one session on one channel,
  not for multiplexed invoke trees; the first producer bead settles it.
- How child-session streams interleave on a shared channel (one
  `session.start` per session is settled; ordering guarantees across
  sessions are not).
- The exact JSON encoding of predicator values beyond the
  `:undefined`/`null` rule - tuples and other non-JSON-native values need
  a documented mapping in the spec when the first producer meets one.
- Whether `session.start` carries the fixture bundle (or a reference to
  it) so a debugging consumer gets chart, tables, and example data in one
  message - a spec-document call, constrained only by the sidecar shape
  settled in ADR-0003.
