# The statifier-ui trace wire format

Version: 1

## Status and scope

This document is the normative specification ADR-0005 names:
`docs/wire-format.md`, "the format's normative home." ADR-0005 settled the
envelope, the nine `trace.*` type names, the `session.start` definition
message and its role, the `$`-tagged JSON value discipline, the integer
`version` field starting at `1`, and the must-ignore-unknown rule; it
delegated field-by-field schemas to this document. **When this document and
an implementation disagree, this document is what conformance means** -
ADR-0005's own words, restated here because it is the rule a second
interpreter's author needs first.

**Conformance.** A conformant producer:

- MUST emit exactly one `session.start` message opening a session's stream.
- MUST, when tracing is enabled, emit the nine `trace.*` types at the phase
  boundaries Appendix D names, with the envelope fields this document
  requires.
- MAY emit further message families (this document also specifies nine
  `effect.*` types and four `session.*` lifecycle types) and MAY add fields
  to any message beyond what this document requires.

A conformant consumer:

- MUST ignore fields it does not recognize on a message of a known type.
- MUST ignore messages whose `type` it does not recognize.

Because of the two MUST-ignore rules, **adding a field or a type is not a
version bump.** A version bump is reserved for a change that would make a
consumer of the previous version misread the stream - removing a field,
changing a field's meaning or shape, or renaming a type.

## The envelope

Every message is a JSON object. Every message carries:

| Field | Type | Present on |
|---|---|---|
| type | string | always |
| session | string | always |
| seq | integer | always |
| macrostep | integer | `trace.*` only |
| microstep | integer | `trace.*` only |
| round | integer | `trace.*` only |

`type` is a dotted-namespace string identifying the message shape; the
remaining sections of this document define every value it may take.
`session` is the emitting session's id (statifier's `_sessionid`), so a
consumer can share one channel across a session and, later, an invoke tree
of related sessions. `seq` is a per-session monotonic integer, described
fully under "Ordering" below.

**`effect.*` messages carry `macrostep` and `microstep` but not `round`.**
Every core (non-trace) statifier effect payload stamps `macrostep` and
`microstep`, but no core effect payload stamps `round` - `round` is a
trace-only counter today, upstream tracking issue `st-nbmj`. This is not an
oversight this document papers over: the omission is real, and inventing a
value would be a guess baked into the wire. When `st-nbmj` lands upstream
and a core effect gains a `round`, this document's `effect.*` schemas gain
the key. That is an additive change under the versioning rule above, not a
version bump.

Beyond the fields in the table, every message carries a **payload**: the
type-specific fields, documented below one type at a time. A payload key
never collides with an envelope key - `type`, `session`, `seq`, `macrostep`,
`microstep`, and `round` are reserved words in every message's JSON object.
This is why `effect.invoke` and `effect.send`/`effect.send_delayed` name
their own `<invoke>`/`<send>` `type`/`typeexpr` attribute `invoke_type` and
`send_type` rather than the engine's own field name `type` - the element
attribute and the envelope's message-type discriminator are unrelated
concepts that would otherwise collide under one key in the same flat JSON
object.

## Ordering

`seq` is stamped by the producer at the point a listener subscribes to a
session's effect stream - the subscription boundary - starting at `0` on
that session's `session.start` message and incrementing by exactly one for
every message the producer emits afterward on that session. No other
component may assign `seq`; a carrier that relays messages onward must
preserve the value the producer stamped.

`(macrostep, round)` is the timeline key: it names *when in the run* a
`trace.*` message belongs, independent of delivery order. `seq` totally
orders one session's message stream; `(macrostep, round)` orders the run
itself.

**Interleaving across sessions is arbitrary.** The format guarantees total
order within one session and promises nothing about how two sessions'
messages interleave on a shared channel - that interleaving is whatever
process scheduling produced, not a promise anyone made. A consumer merging
multiple sessions onto one timeline sorts by `(session, seq)`, or by
`(macrostep, round)` within a session, and never reads causality from
arrival order.

**The warning a coverage spike earned (`st-r6l9`).** A producer reading a
live statifier session may deliver messages whose `seq` order does not
match `(macrostep, round)` order, and may deliver `trace.*` messages *after*
`session.halted`. This is not a defect this document is proposing be fixed;
it is producer behavior this document describes because a consumer has to
handle it. It arises on charts that exercise `<invoke>` or an internal
`<send>` - live delivery is not guaranteed to be macrostep-ordered across
that seam, and halting a session's interpreter loop does not stop its
effect delivery.

Two consequences for anyone building on this format:

- **Consumers sort by `(macrostep, round)`, never by arrival order, when
  reconstructing the run's timeline**, and never treat `session.halted` as
  end-of-stream - more `trace.*` messages may follow it.
- **Golden-trace comparison on a chart that touches this seam is a
  multiset or a `(macrostep, round)`-sorted comparison, never a byte
  comparison.** A chart that never uses `<invoke>` or an internal `<send>`
  does not hit this seam, and its trace remains byte-comparable run to run,
  which is what makes the worked example and the golden test at the end of
  this document possible.

## JSON discipline

Four rules make the format precise enough for a byte-comparable golden
trace, and precise enough that a second interpreter reproduces the same
bytes for the same run.

### Value encoding

Anything occupying a *value* position - `_event.data`, a `<log>`'s
resolved value, `donedata`, a `<send>`'s resolved `data`, an `<invoke>`'s
resolved `params`/`content` - is encoded through the same four-form scheme
`StatifierUI.Value` implements:

- Booleans, integers, floats, strings, `nil`, lists, and string- or
  atom-keyed maps (atom keys serializing as their names) map to their
  natural JSON form.
- A `Date` encodes as a one-key tagged object: `{"$date": "2026-08-16"}`
  (ISO 8601).
- A `DateTime` encodes the same way: `{"$datetime":
  "2026-08-16T12:00:00Z"}` (ISO 8601).
- A duration encodes as `{"$duration": {...}}`, an object carrying all
  eight unit fields - `years`, `months`, `weeks`, `days`, `hours`,
  `minutes`, `seconds`, `milliseconds` - as integers, absent units filled
  with `0`.
- The `:undefined` sentinel, wherever it appears *inside* a composite value
  (a list element, a map value) rather than at a field's top level, encodes
  as `{"$undefined": true}` - absence has no positional spelling inside a
  list or a map value, so the sentinel needs an explicit encoding there
  even though it is spelled by key-absence at a message's top level (see
  "Absence" below).

The one-key `$`-prefixed object shape is reserved by this document for
exactly these four forms. A host value that happens to be a one-key map
whose only key starts with `$` and is not one of `$undefined`, `$date`,
`$datetime`, or `$duration` is a spec violation on the producer's side, not
a value this format can carry unambiguously - accepted as vanishingly rare.

### Absence

Key absence and JSON `null` mean different things, and no layer of this
format may collapse them. The rule stated once, generalized to every
nullable field this format carries (not only `_event.data`, though that is
where the distinction was first load-bearing):

- **Key absent** - the field has no meaningful value at all (statifier's
  `:undefined` sentinel, or an optional field the producer was not given).
- **JSON `null`** - the field is present, and its value is null.
- **An empty object or array** (`{}`, `[]`) - the field is present, and its
  value is an empty collection.

All three are distinct and a consumer must be able to tell them apart. The
rule applies uniformly to: `_event.data` (`:undefined` -> key absent,
`nil` -> `null`, `%{}` -> `{}`); `Event`'s `invokeid`, `origin`,
`origintype`, `sendid`, and `cause`; `Log`'s `label`, `c_index`, and
`owner`; `Trace.Done`'s `donedata`; and, the load-bearing case for a
consumer reconstructing the run, `trace.transitions_selected`'s `event`
field, whose absence marks an **eventless round** - the platform selected
transitions with no event to match against, spec's NULL round. There is no
separate boolean flag for this; the absence of the `event` key *is* the
signal, the same way absence signals "no data" everywhere else in this
rule. A consumer must not confuse "the `event` key is absent" with "the
`event` key is `null`" - they never mean the same thing anywhere in this
format.

### Structural tagging: `"kind"`

Statifier represents some information as Elixir tuples - the eight
variants of an internally-raised event's cause origin, and the five
variants of which content block ran. Nothing tuple-shaped crosses the wire.
Each variant becomes a JSON object whose `"kind"` field names the tuple's
tag and whose remaining fields name its positional elements:

```
{:content, c_index, owner}       -> {"kind": "content", "c_index": c_index, "owner": {...}}
{:onentry, state_index, ordinal} -> {"kind": "onentry", "state_index": state_index, "ordinal": ordinal}
```

and so on for every variant listed under "Origins" and "Owners" below.
`"kind"` rather than `"$kind"`: the `$`-prefixed one-key shape above is
reserved for the value codec's four forms, and these are multi-key
structural objects appearing in a known field position, not values sitting
in a value slot.

### Canonical order

- **Object keys are lexicographic**, in every object this format produces,
  at every nesting level.
- **A genuine set-valued field - a `MapSet` in the engine - serializes as
  an array in ascending-index order.** This applies to `configuration`
  wherever it appears (`trace.macrostep_stable`, `trace.done`,
  `effect.budget_exhausted`).
- **A sequence-valued field that is already ordered by the engine keeps
  that order; it is not additionally sorted.** This is a deliberate,
  narrow departure from an ADR-0005 sentence that names exit and entry
  sets specifically alongside configurations as "canonical order (ascending
  index)". Read literally, sorting would discard information: statifier's
  exit order is inner-to-outer (the order Appendix D's `exitStates` actually
  visits them) and its entry order is entry order, and the event-log pane
  this format was built for renders exactly that sequence to a user
  stepping through a run. Both orders are deterministic for a given run, so
  preserving them costs the byte-comparability rule nothing - the property
  the ascending-index sentence exists to protect. The resolution, applying
  to `trace.exit_set` and `trace.entry_set`'s `indexes` fields precisely:
  they are sequences in the engine's own emission order, never re-sorted.
  Every other sequence field in this document that is not already
  identified as a genuine set (transition lists, content lists, and so on)
  likewise keeps the engine's own order. This document, in stating the
  rule this way, is exercising exactly the field-by-field remit ADR-0005
  delegated to it, not contradicting the envelope ADR-0005 fixed.

Together, canonical ordering plus the value encoding above is what makes
two producer runs of the same chart, the same fixtures, and the same event
script byte-identical JSON Lines - the golden-trace conformance mechanism
ADR-0005 names.

## `session.start`

The definition message that opens a session's stream. Every later message's
indexes (state indexes, `t_index`, `c_index`) resolve back to source
locations only through the tables this message carries - a consumer with no
compiler of its own can still build a working inspector, because everything
it needs to resolve an index arrived once, up front.

| Field | Type | Presence |
|---|---|---|
| version | integer | always |
| states | array of objects | always |
| transitions | array of objects | always |
| contents | array of objects | always |
| source | string | present only when the host supplies chart source |
| fixtures | object | present only when the host supplies a fixtures bundle |
| parent_session | string | present only when this session was started by `<invoke>` |
| invokeid | string | present only when this session was started by `<invoke>` |

`version` is `1` for this document. It is the fixtures sidecar's own
`version` convention (ADR-0003), reused here rather than invented fresh.

**`states`** is one object per compiled state, in `index` order (index `0`
is always the synthesized `:scxml` root):

| Field | Type | Presence |
|---|---|---|
| index | integer | always |
| kind | string | always - one of `"scxml"`, `"state"`, `"parallel"`, `"final"`, `"history"` |
| id | string | omitted when the state has no id (always omitted at index `0`) |
| parent | integer | omitted only at index `0`, the root |
| children | array of integers | always (empty for an atomic state) |
| transitions | array of integers | always - the state's own selectable `t_index` list |
| location | location object | always |

**`transitions`** is one object per compiled transition, in `t_index`
order:

| Field | Type | Presence |
|---|---|---|
| t_index | integer | always |
| source | integer | always - the owning state's index |
| targets | array of integers | always (empty for a targetless transition) |
| events | array of arrays of strings | always - one dot-split token list per whitespace-separated event descriptor; empty for an eventless transition |
| type | string | always - `"internal"` or `"external"` |
| content | array of integers | always - the transition's own executable content, `c_index` list in document order; empty when the transition carries none |
| location | location object | always |
| cond_location | location object | present only when the transition carries a `cond` |

**`contents`** is one object per compiled executable-content node, in
`c_index` order:

| Field | Type | Presence |
|---|---|---|
| c_index | integer | always |
| kind | string | always - the node's own tag: `"raise"`, `"log"`, `"assign"`, `"if"`, `"foreach"`, `"script"`, `"send"`, or `"cancel"` |
| location | location object | always |

Every content node kind except `<script>` carries a `:location` field
directly. `Statifier.Machine.Content.Script` is the one exception - it
carries `:node_location` instead, because a script's own compiled program
lives where a sibling node's resolved value would. This document's
producer reads a content node's location as its `:location` field when
present, falling back to `:node_location` when it is not, so every entry in
`contents` carries a `location` regardless of kind. A producer that
hardcodes `:location` and skips the fallback will crash on the first
`<script>` in a chart - this is the specific bug this note exists to
prevent.

**A location object** is always all six fields, and is either wholly
present or wholly absent - there is no partial location:

| Field | Type |
|---|---|
| start_line | integer (1-based) |
| start_column | integer (1-based, Unicode codepoints) |
| start_offset | integer (0-based byte offset) |
| end_line | integer (1-based) |
| end_column | integer (1-based, Unicode codepoints) |
| end_offset | integer (0-based byte offset, exclusive) |

**`source`**, when present, is the chart's SCXML text, verbatim. It cannot
be derived from the compiled Machine - the compiled form does not retain
source text - so this document's producer accepts it as caller-supplied
context rather than recovering it. Absence means the host supplied none.

**`fixtures`**, when present, is the ADR-0003 sidecar's decoded JSON object,
carried through verbatim, its own `version` field included. This document's
producer does not construct or validate a fixtures bundle; the caller
supplies an already-decoded object, or supplies none.

**`parent_session`** and **`invokeid`**, when present, name the session
that started this one via `<invoke>` and the `invokeid` this session
stamps, respectively. Together they let a consumer holding two sessions'
`session.start` messages reconstruct the parent-child edge between them
without any other channel. Both are absent for a session with no invoking
parent.

**A caveat on location granularity.** The tables above are built from the
compiled `%Statifier.Machine{}` layer, which carries element-level spans -
a whole `<transition>`, a whole `<assign>` - plus a transition's own
`cond_location` for its guard expression specifically. It does **not**
carry attribute-level spans for every attribute (for example, a `<send>`
element's individual `event`/`target`/`delay` attribute spans): that finer
table, `attribute_locations`, lives one layer up, on the `Document` the
compiler consumes, not on the `Machine` this document's producer reads
(tracked as `sui-qay`). A consumer wanting hover-precision on an individual
attribute rather than the whole element does not yet have it from
`session.start` alone.

## The nine `trace.*` schemas

Every `trace.*` message carries the envelope's `macrostep`, `microstep`,
and `round`, in addition to `type`, `session`, and `seq`. Fields below are
the payload beyond the envelope.

### `trace.event_dequeued`

Emitted when an event is selected off a queue for processing.

| Field | Type | Presence |
|---|---|---|
| event | event object | always |
| from | string | always - `"external"` or `"internal"` |

**An event object** is `Statifier.Event.t()` rendered to JSON:

| Field | Type | Presence |
|---|---|---|
| name | string | always |
| data | value | present only when data was supplied (absence-rule: `:undefined` omits the key, `nil` present as `null`, `%{}` present as `{}`) |
| type | string | always - `"external"`, `"internal"`, or `"platform"` |
| cause | cause object | present only for `"internal"`/`"platform"` events the platform itself raised |
| invokeid | string | present only when set |
| origin | string | present only when set |
| origintype | string | present only when set |
| sendid | string | present only when set |

**A cause object** (`Statifier.Event.Cause.t()`):

| Field | Type | Presence |
|---|---|---|
| origin | origin object | always - see "Origins" below |
| macrostep | integer | always |
| microstep | integer | always |
| round | integer | always |

### `trace.transitions_selected`

Emitted whenever transition selection runs, including when it selects
nothing.

| Field | Type | Presence |
|---|---|---|
| t_indexes | array of integers | always - selected transitions' `t_index`, in selection order, empty when none selected |
| event | event object | present only for an event-triggered round; absent marks an eventless (NULL) round |

### `trace.exit_set`

Emitted before any state is exited, whether by ordinary transition or by
interpreter shutdown.

| Field | Type | Presence |
|---|---|---|
| indexes | array of integers | always - the states about to be exited, **in the engine's own exit order** (inner-to-outer), not re-sorted; empty when none exit |

### `trace.content_executed`

Emitted when a block of executable content runs (an `<onentry>`/`<onexit>`
block, a transition's own content, or a top-level `<script>` at load time).

| Field | Type | Presence |
|---|---|---|
| owner | owner object | always - see "Owners" below |
| c_indexes | array of integers | always - the run content nodes' `c_index`, in execution order |

### `trace.entry_set`

Emitted before any state is entered, with `compute_entry_set`'s result.

| Field | Type | Presence |
|---|---|---|
| indexes | array of integers | always - the states about to be entered, **in the engine's own entry order**, not re-sorted; empty when none enter |

### `trace.macrostep_stable`

Emitted once the configuration reaches quiescence - the macrostep's
microstep loop has drained.

| Field | Type | Presence |
|---|---|---|
| configuration | array of integers | always - the full configuration (ancestors included), a genuine set, sorted ascending |

### `trace.done`

Emitted alongside the top-level final entry / interpreter exit.

| Field | Type | Presence |
|---|---|---|
| donedata | value | present only when the top-level final carried `<donedata>` (absence-rule applies) |
| configuration | array of integers | always - the full configuration as it stood at exit, a genuine set, sorted ascending |

### `trace.invoke_pass`

Emitted once the invoke pass finishes, including when it starts nothing.

| Field | Type | Presence |
|---|---|---|
| state_indexes | array of integers | always - `states_to_invoke`, in the entry order the pass walked, including a state that owns no `<invoke>` |
| invoke_ids | array of strings | always - every invocation this pass actually started, in the order it started them |

### `trace.finalize_autoforward`

Emitted once per external event, at the end of the finalize/autoforward
pass, including when nothing was finalized or forwarded.

| Field | Type | Presence |
|---|---|---|
| event | event object | always - the external event the pass matched against |
| finalized | array of strings | always - `invoke_id`s of every invocation `<finalize>` ran for |
| forwarded | array of strings | always - `invoke_id`s of every invocation `event` was autoforwarded to, in the pass's own walk order |

## The nine `effect.*` schemas

The nine core (non-trace) statifier effects, mapped one-to-one onto their
own namespace. ADR-0005 leaves non-trace effect naming to this document
("their own namespaces as consumers need them"); this document uses one
`effect.*` family rather than several separate top-level namespaces,
because a bare top-level `done` type would sit confusingly next to
`trace.done` - a different message about the same moment in the run.
`effect.*` and `trace.*` are two visibly distinct halves of the vocabulary:
`trace.*` are the nine Appendix D phase boundaries, stamped with all three
counters; `effect.*` are the core effect vocabulary, stamped with
`macrostep`/`microstep` only (see "The envelope" above for why `round` is
absent).

Every `effect.*` message carries `macrostep` and `microstep`, never
`round`.

### `effect.log`

Payload for `<log>` (spec 4.7).

| Field | Type | Presence |
|---|---|---|
| label | string | present only when the element wrote a `label` |
| value | value | present only when the element wrote an `expr` (absence-rule applies) |
| c_index | integer | present only when known |
| owner | owner object | present only when known |

### `effect.done`

The terminal effect, emitted once after top-level final entry.

| Field | Type | Presence |
|---|---|---|
| donedata | value | present only when the top-level final carried `<donedata>` (absence-rule applies) |
| configuration | array of integers | always - the full configuration at exit, sorted ascending |

### `effect.budget_exhausted`

Emitted when a macrostep's fold spends its round budget without reaching
quiescence (ADR-0019). This is the one core effect that does carry `round`
- see "The envelope" above.

| Field | Type | Presence |
|---|---|---|
| configuration | array of integers | always - the configuration as the last round left it, sorted ascending |
| budget | integer or string | always - the spent budget; the string `"infinity"` when the budget was unbounded |
| pending_internal_events | array of event objects | always - the queue's ordered view at exhaustion |

### `effect.invoke`

Emitted once per `<invoke>` the invoke pass actually started (spec 6.4).

| Field | Type | Presence |
|---|---|---|
| invoke_id | string | always |
| invoke_type | string | present only when set - the `<invoke>` element's own `type`/`typeexpr` attribute |
| src | string | present only when set |
| params | value | present only when the invocation resolved params (absence-rule applies) |
| content | value | present only when the invocation resolved content (absence-rule applies) |
| autoforward | boolean | present only when set |
| state_index | integer | always - the invoking state |
| invoke_index | integer | always - the invocation's position in the state's own `invoke` list |

### `effect.cancel_invoke`

Emitted once per invocation the engine cancels because its owning state
exited while the invocation was still live.

| Field | Type | Presence |
|---|---|---|
| invoke_id | string | always |
| state_index | integer | always - the state that owned the cancelled invocation |

### `effect.autoforward`

Emitted once per autoforwarding invocation, during the finalize/autoforward
pass.

| Field | Type | Presence |
|---|---|---|
| invoke_id | string | always |
| state_index | integer | always - the invoking state |
| event | event object | always - the external event forwarded verbatim |

### `effect.send`

Payload for `<send>`, fired immediately (spec 6.2).

| Field | Type | Presence |
|---|---|---|
| event | string | always |
| target | string | present only when set |
| send_type | string | present only when set - the `<send>` element's own `type`/`typeexpr` attribute |
| data | value | present only when resolved (absence-rule applies) |
| send_id | string | always |
| id_from_author | boolean | always - whether the document wrote `id`/`idlocation` itself, rather than the engine generating one |
| c_index | integer | present only when known |
| owner | owner object | present only when known |

### `effect.send_delayed`

Payload for `<send>` with a `delay`/`delayexpr`. Carries every field
`effect.send` does, plus:

| Field | Type | Presence |
|---|---|---|
| delay_ms | integer | always - the resolved delay, in milliseconds, as of when the send was scheduled |

### `effect.cancel`

Payload for `<cancel>` (spec 6.3).

| Field | Type | Presence |
|---|---|---|
| send_id | string | always - the `sendid`/`sendidexpr` naming the delayed send to cancel |
| c_index | integer | present only when known |
| owner | owner object | present only when known |

## Origins

`Statifier.Event.Cause.origin/0`'s eight variants, each a tagged object
with `"kind"` naming the tuple's tag:

| "kind" | Fields | Meaning |
|---|---|---|
| "content" | c_index (integer), owner (owner object) | a content node (for example `<raise>`) raised the event |
| "state" | state_index (integer) | the platform raised the event with no content node behind it (for example `done.state.*`) |
| "transition" | t_index (integer) | the platform raised the event about a transition's own `cond` |
| "data" | d_index (integer) | the platform raised the event about a `<data>` element that failed to bind |
| "donedata_param" | state_index (integer), param_index (integer) | one `<param>` under a `<final>`'s `<donedata>` failed to evaluate |
| "global_script" | index (integer) | a top-level `<script>` failed at load time |
| "invoke" | state_index (integer), invoke_index (integer) | one of an `<invoke>`'s own arguments failed to evaluate |
| "finalize" | state_index (integer), invoke_index (integer) | an empty `<finalize>`'s own auto-assign write failed |

## Owners

`Statifier.Machine.Content.owner/0`'s four variants, plus the one case
`Statifier.Effect.Trace.ContentExecuted` widens it with for a top-level
`<script>`, together the five variants an `owner` field may take anywhere
in this format:

| "kind" | Fields | Meaning |
|---|---|---|
| "onentry" | state_index (integer), ordinal (integer) | an `<onentry>` block; ordinal is the block's position in the state's own `onentry` list |
| "onexit" | state_index (integer), ordinal (integer) | an `<onexit>` block; ordinal is the block's position in the state's own `onexit` list |
| "transition" | t_index (integer) | a transition's own executable content |
| "finalize" | state_index (integer), invoke_index (integer) | an `<invoke>`'s own `<finalize>` block |
| "global_script" | index (integer) | a top-level `<script>`, run at load time - only ever appears as `trace.content_executed`'s owner, since a top-level script belongs to no `<onentry>`/`<onexit>`/transition block |

## The `session.*` lifecycle types

Four types name a session's shape from the outside - its start, and the
three ways a subscriber's own stream can end or change state. None of the
four carry `macrostep`/`microstep`/`round`; they describe the *stream*,
not a point inside a run.

### `session.start`

The definition message. Schema above under "`session.start`". Always
`seq: 0`.

### `session.halted`

Emitted when the session reports `{:halted, reason}` to its subscriber.

| Field | Type | Presence |
|---|---|---|
| reason | string | always - one of `"done"`, `"cancelled"`, `"budget_exhausted"` |

Halting a session does not stop effect delivery: `trace.*` messages may
still arrive after `session.halted` (see "Ordering" above, `st-r6l9`). A
consumer must not treat this message as end-of-stream.

### `session.terminated`

Emitted when the subscriber observes the session's process exit (a
monitor `:DOWN`).

| Field | Type | Presence |
|---|---|---|
| reason | string | always - `inspect/1` of the Elixir exit reason |

`reason` is a human-readable string, not structured data to branch on - an
Elixir process exit reason has no language-neutral shape, so this document
does not attempt to give it one.

### `session.unroutable`

Emitted when the session reports `{:unroutable, effect}` to its subscriber
- an effect the session could not route to a destination. Currently
unreachable in the engine as shipped, reserved for when it becomes
reachable.

| Field | Type | Presence |
|---|---|---|
| effect | object | always - the unrouted effect, encoded the same way its own `effect.*` or `trace.*` type would encode it, under a `kind` key naming that type |

## Reserved and not yet emitted

**`session.datamodel`** is reserved by this document and emits nothing
today. Nothing on statifier's effect stream reports a datamodel change
(tracked as `st-oef3`); polling the session's own snapshot from inside a
subscriber would race the running session and be unreproducible under
replay, so this document does not specify a polling-based `session.*`
message as a substitute. The name is reserved so a future implementation
of `st-oef3` has an uncontested type string to emit into, and so a second
interpreter reading this document today knows the gap exists rather than
discovering it by a consumer silently ignoring an unrecognized type. It
appears in the type index below, marked reserved, so the drift test's type
count accounts for it even though no producer emits it yet.

## Worked example

The complete JSON Lines trace of a two-state chart with one external
transition. The producer ran with `session_id: "sess_golden"`. This is the
same fixture phase 5's golden test compares against byte-for-byte.

Chart:

```xml
<scxml initial="a">
    <state id="a">
        <transition event="go" target="b"/>
    </state>
    <state id="b"/>
</scxml>
```

Driven with one external event, `"go"`, with no data. Trace (one JSON
object per line, each shown here pretty-printed for readability; the wire
form is one line with lexicographic keys and no extra whitespace):

```json
{"type": "session.start", "session": "sess_golden", "seq": 0, "version": 1, "states": [{"index": 0, "kind": "scxml", "children": [1, 2], "transitions": [], "location": {"start_line": 1, "start_column": 1, "start_offset": 0, "end_line": 5, "end_column": 9, "end_offset": 140}}, {"index": 1, "kind": "state", "id": "a", "parent": 0, "children": [], "transitions": [0], "location": {"start_line": 2, "start_column": 5, "start_offset": 25, "end_line": 4, "end_column": 13, "end_offset": 99}}, {"index": 2, "kind": "state", "id": "b", "parent": 0, "children": [], "transitions": [], "location": {"start_line": 4, "start_column": 5, "start_offset": 105, "end_line": 4, "end_column": 17, "end_offset": 117}}], "transitions": [{"t_index": 0, "source": 1, "targets": [2], "events": [["go"]], "type": "external", "content": [], "location": {"start_line": 3, "start_column": 9, "start_offset": 39, "end_line": 3, "end_column": 47, "end_offset": 77}}], "contents": []}
{"type": "trace.event_dequeued", "session": "sess_golden", "seq": 1, "macrostep": 1, "microstep": 0, "round": 0, "event": {"name": "go", "type": "external"}, "from": "external"}
{"type": "trace.transitions_selected", "session": "sess_golden", "seq": 2, "macrostep": 1, "microstep": 0, "round": 0, "t_indexes": [0], "event": {"name": "go", "type": "external"}}
{"type": "trace.exit_set", "session": "sess_golden", "seq": 3, "macrostep": 1, "microstep": 1, "round": 0, "indexes": [1]}
{"type": "trace.entry_set", "session": "sess_golden", "seq": 4, "macrostep": 1, "microstep": 1, "round": 0, "indexes": [2]}
{"type": "trace.invoke_pass", "session": "sess_golden", "seq": 5, "macrostep": 1, "microstep": 1, "round": 0, "state_indexes": [], "invoke_ids": []}
{"type": "trace.finalize_autoforward", "session": "sess_golden", "seq": 6, "macrostep": 1, "microstep": 1, "round": 0, "event": {"name": "go", "type": "external"}, "finalized": [], "forwarded": []}
{"type": "trace.macrostep_stable", "session": "sess_golden", "seq": 7, "macrostep": 1, "microstep": 1, "round": 0, "configuration": [2]}
```

`seq` starts at `0` on `session.start` and increments by one across every
subsequent message, with no gaps - this chart never touches the `<invoke>`/
internal-`<send>` reordering seam, so a producer's live delivery order and
`(macrostep, round)` order agree throughout, and the trace above is
byte-comparable run to run. `trace.content_executed` and `trace.done` do
not appear because this run has no executable content and never halts
through a `<final>` state; a chart exercising those types would show them
in the same shape the schemas above describe.

## Type index

One row per type this document defines - 23 rows: 9 `trace.*`, 9
`effect.*`, and 5 `session.*` (the four lifecycle types plus the reserved
`session.datamodel`). This table's first column is a machine boundary: a
drift test parses exactly this table's backtick-quoted `type` strings and
asserts them equal to the producer's own emitted type set, so a type
documented here and not emitted, or emitted and not documented here, fails
that test rather than drifting silently. `session.datamodel` is excluded
from that equality on the emitted side, since this document states above
that no producer emits it yet.

| Type | Family | Emitted when |
|---|---|---|
| `trace.event_dequeued` | trace | an event is dequeued for processing |
| `trace.transitions_selected` | trace | transition selection runs |
| `trace.exit_set` | trace | before states are exited |
| `trace.content_executed` | trace | a block of executable content runs |
| `trace.entry_set` | trace | before states are entered |
| `trace.macrostep_stable` | trace | the configuration reaches quiescence |
| `trace.done` | trace | alongside top-level final entry |
| `trace.invoke_pass` | trace | the invoke pass finishes |
| `trace.finalize_autoforward` | trace | the finalize/autoforward pass finishes |
| `effect.log` | effect | `<log>` runs |
| `effect.done` | effect | the interpreter terminates |
| `effect.budget_exhausted` | effect | a macrostep's round budget is spent without quiescence |
| `effect.invoke` | effect | an invocation starts |
| `effect.cancel_invoke` | effect | a live invocation's owning state exits |
| `effect.autoforward` | effect | an event is autoforwarded to an invocation |
| `effect.send` | effect | `<send>` fires immediately |
| `effect.send_delayed` | effect | `<send>` with a delay is scheduled |
| `effect.cancel` | effect | `<cancel>` runs |
| `session.start` | session | a session's stream opens |
| `session.halted` | session | the session reports `{:halted, reason}` |
| `session.terminated` | session | the session's process exits |
| `session.unroutable` | session | the session reports an unroutable effect |
| `session.datamodel` | session | reserved, not yet emitted (`st-oef3`) |

## References

- ADR-0005 (`docs/adr/0005-language-neutral-trace-wire-format.md`) - the
  envelope, the nine `trace.*` type names, the `session.start` role, the
  JSON discipline this document restates by reference, versioning, and the
  clause naming this document as the format's normative home.
- ADR-0003 (`docs/adr/0003-fixtures-as-the-example-data-contract.md`) - the
  fixtures sidecar object `session.start`'s `fixtures` field carries
  verbatim.
- `st-nbmj` - the upstream gap behind `effect.*` messages carrying no
  `round`.
- `st-r6l9` - the upstream reordering seam behind the ordering warning
  above.
- `st-oef3` - the upstream gap behind `session.datamodel` being reserved
  rather than emitted.
- `sui-qay` - the gap behind `session.start`'s location tables carrying no
  attribute-level spans.
