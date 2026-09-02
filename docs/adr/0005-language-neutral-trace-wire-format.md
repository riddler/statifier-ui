# ADR-0005: Language-neutral trace wire format

Status: accepted (2026-08-16), amended in part by ADR-0011 (2026-08-17):
exit and entry sets are engine-ordered sequences, not canonically sorted
sets; extended by ADR-0012 (2026-08-26): the `$`-prefixed reserved value
set gains exactly one form, `{"$redacted": true}`, producible by the
projection layer; format version stays 1
Amendment status: **proposed** (2026-09-01, sui-qay: attribute-level
entries in the identity tables) - see "Amendment proposed" below; the
accepted text is unchanged and stays authoritative until the amendment is
read and accepted.

## Amendment proposed 2026-09-01 (sui-qay): attribute-level entries in the identity tables

*Proposed, not accepted. Nothing outside this section has been edited, and
no Status line elsewhere in this record has been changed.*

The Decision specifies `session.start` as carrying "the identity tables the
compiled Machine retains - state index to id and location, `t_index` and
`c_index` to location". It names the layer and stops there; it says nothing
about how fine those locations are, and this record's Consequences do not
take the question up either. The element-level limit was never a decision
of this record at all - it was a property of what that layer happened to
retain, written down elsewhere: in ADR-0007's Consequences bullet
("Attribute-level hover locations live one layer higher than the identities
on the wire") and in `docs/wire-format.md`'s caveat on location
granularity, both of which record it as a constraint to be lifted upstream
rather than a price this format chose to pay.

It has been lifted. statifier's `st-9i5r` (statifier-ex PR #185) carried
the `attribute_locations` map from the Document node through to
`Statifier.Machine.State` and `Statifier.Machine.Transition` verbatim,
key-presence contract included, so the finer table is now readable at
exactly the layer the Decision already names. Nothing in the accepted
Decision has to bend to admit it: the tables still carry what the compiled
Machine retains, and the Machine now retains more.

**The amendment: a state row and a transition row each gain an
`attribute_locations` object**, mapping an attribute's name to that
attribute's own value span, alongside the element-level `location` they
already carry. `docs/wire-format.md`'s `session.start` section states the
field; this record states why it is a legitimate extension of the
accepted decision rather than a departure from it.

**Key presence is the contract, not the span.** An entry exists only for an
attribute the author actually wrote, which is a question the lowered value
cannot answer: a transition compiled `type: :external` was either written
`type="external"` or written nothing at all, and only the presence of the
`type` key separates the two. This is the same discipline the accepted
"JSON discipline" section already applies to `_event.data` - absence and
present-and-empty are different facts, and no carrier may collapse them -
applied one level down, to attributes.

**It is additive, so the format version stays `1`.** The accepted
versioning rule is explicit that adding a field is not a version bump. A
consumer that never looks at the key sees the format it already knows;
every existing row keeps its element-level `location` unchanged, and a
consumer that finds no entry for the attribute it wants falls back to that
`location`, which is exactly the granularity this format offered before.
The degrade path is the same one a producer reading an older Machine takes:
the field is `{}` and nothing else changes.

**It does not touch projection.** `attribute_locations` is an identity
table and holds source spans, never datamodel values, so it falls under
ADR-0012's existing "every `session.start` table and every `location`
object in them" - a structural position that is never projected. No new
value position is created, so the closed position set is unchanged.

**Scope: `states` and `transitions` only.** `contents` and `data` rows do
not gain the field. The compiled Machine retains the map on its content
nodes too, but the `data` table is deliberately identity-only - an
argument this record's accepted text does not make, since it names no
`data` table at all; it is made in `docs/wire-format.md`'s note on that
table ("This table is deliberately **identity only**"), and reinforced by
ADR-0012's projection rule, which leans on exactly that property. No
consumer has asked for attribute granularity on either table. Extending
it later is additive on the same terms.

**`cond_location` is retained, not superseded.** It carries a fallback the
raw map does not - the transition's own `location` when a guard was written
without a recorded span - so the two answer different questions and both
stay. New work prefers `attribute_locations["cond"]`.

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
- `seq`: a per-session monotonic integer stamped by the producer at the
  session subscription boundary, starting at `0` on `session.start` and
  incrementing by one per message; the carrier never assigns it. The
  engine guarantees effect-list order (statifier ADR-0012: no side
  channel), and the session's fan-out preserves it per subscriber - but
  only per session. Each session is its own process, so a carrier
  merging an invoke tree onto one channel receives an interleaving
  nobody ordered; delivery-time stamping would bake that accident into
  the stream. `seq` is the engine's order made explicit on the wire,
  where a list has become a stream, and only the subscription boundary
  still sees that order.
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
themselves stay small. A session started by `<invoke>` also names its
origin on `session.start` - the parent's session id and the `invokeid`
the child stamps (spec 5.10.1) - so a consumer rebuilds the invoke tree
from message content alone. And `session.start` may carry the fixture
bundle inline, as an optional `fixtures` field holding the ADR-0003
sidecar's JSON object verbatim, its own `version` field included.
Inline rather than by reference: a reference needs a namespace to
resolve in - a filesystem, a URL scheme - and the format presupposes no
shared one. Key absence means the host supplied no fixtures, per the
discipline below.

**Interleaving across sessions is arbitrary.** The format guarantees
total order within a session (`seq`) and promises nothing between
sessions: the engine orders only a session's own effect list, and a
shared channel's merge is whatever process scheduling produced.
Consumers must not read causality from arrival order; parent-child
causality lives in the data - the `trace.invoke_pass` effects, the
`invokeid` on forwarded and child events, and the origin fields on
`session.start` above. This writes down the guarantee the engine
actually provides rather than promising one it does not.

**JSON discipline, because the engine's values do not all map trivially:**

- `_event.data` distinguishes `:undefined` (no data) from `nil` (data,
  present, null) from `%{}` (data, empty). On the wire: key absence is "no
  data", JSON `null` is present-and-null. No carrier may collapse them.
- Predicator's value domain is closed (predicator
  `Predicator.Types.value/0`): booleans, integers, floats, strings,
  lists, string- or atom-keyed maps, `Date`, `DateTime`, durations,
  `nil`, and `:undefined`. No tuple reaches a value position. The
  JSON-native members map to themselves, atom map keys serializing as
  their names. The non-native members serialize as one-key tagged
  objects: `{"$date": "2026-08-16"}` and `{"$datetime": ...}` in ISO
  8601, `{"$duration": {...}}` carrying all eight unit fields as
  integers, and - because absence has no positional encoding inside a
  list or map value - `{"$undefined": true}` where the `:undefined`
  sentinel appears in a composite. The `$`-prefixed one-key shape is
  reserved by the spec.
- Set-valued fields (configurations, exit/entry sets) serialize as arrays
  in a canonical order (ascending index), and object keys in
  lexicographic order, so two traces of the same run are byte-comparable.

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
  definition message duplicates data (source, tables, any inline
  fixtures) a co-located consumer already has. Accepted: the toll is the
  contract, and carriers may negotiate not to resend what a consumer
  holds, so long as the format's meaning never depends on that shortcut.
- The tagged-object encodings buy type fidelity at an ambiguity price: a
  host map whose only key genuinely is `"$date"` is indistinguishable
  from an encoded `Date`. Accepted as vanishingly rare, and the reserved
  shape makes the collision a spec violation on the host's side rather
  than a silent misread.
- No cross-session ordering means a merged timeline view does its own
  merging - on `(session, seq)` and the invoke-tree links, never on
  arrival order - and two captures of the same run on a shared channel
  are byte-comparable only session by session, not as one interleaved
  file.
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
