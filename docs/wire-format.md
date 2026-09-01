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
- MAY emit further message families (this document also specifies ten
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
| macrostep | integer | `trace.*` and `effect.*` |
| microstep | integer | `trace.*` and `effect.*` |
| round | integer | `trace.*` and `effect.*` |
| otel | object | optional, and only on `trace.*` and `effect.*` - see "OTel correlation" below |

`type` is a dotted-namespace string identifying the message shape; the
remaining sections of this document define every value it may take.
`session` is the emitting session's id (statifier's `_sessionid`), so a
consumer can share one channel across a session and, later, an invoke tree
of related sessions. `seq` is a per-session monotonic integer, described
fully under "Ordering" below.

**`effect.*` messages carry all three counters, `round` included**
(`sui-67d`). The value is the engine's own stamp, carried verbatim: as of
statifier ADR-0046 (`st-xb2b`), every core (non-trace) statifier effect
payload carries `macrostep`, `microstep`, and `round` - effects emitted
before that fold carry `round: 0` - and this producer propagates the
stamp rather than inventing one. Between ADR-0046 landing upstream and
`sui-67d` landing here, this producer emitted `round` on `trace.*`
messages and `effect.budget_exhausted` only; the other `effect.*` types
gained the key later. **Versioning decision, recorded rather than left
implicit:** adding `round` to the remaining `effect.*` envelopes is an
additive field change, exactly what the conformance section's MUST-ignore
rule makes safe, so **the format version stays 1** - the same reasoning
`effect.datamodel_change` records below for adding a whole type. A
consumer reading an older recorded stream must still tolerate `effect.*`
messages without `round` (the must-ignore rule's mirror image: absence of
a field a newer producer would have written is not an error).

Beyond the fields in the table, every message carries a **payload**: the
type-specific fields, documented below one type at a time. A payload key
never collides with an envelope key - `type`, `session`, `seq`, `macrostep`,
`microstep`, `round`, and `otel` are reserved words in every message's JSON
object.
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

**Monotone delivery (`st-r6l9`, closed by ADR-0044).** A live statifier
session used to be able to deliver messages whose `seq` order did not match
`(macrostep, round)` order, and could deliver `trace.*` messages after
`session.halted`, on charts that exercise `<invoke>` or an internal
`<send>`. ADR-0044 closed that seam: re-entry effects are now enqueued and
FIFO-drained after the outer batch rather than performed inline, so arrival
order is non-decreasing in `(macrostep, round)` across a whole run, and
`{:halted, reason}` is promised as end-of-stream. ADR-0044 also settled the
uniqueness key for quiescence: more than one `trace.macrostep_stable` per
macrostep is explicitly allowed, but exactly one per `(macrostep, round)`,
with the last-arriving one being that macrostep's quiescence.

One consequence still worth stating for anyone building on this format:

- **Consumers reconstruct the run's timeline by sorting on `(macrostep,
  round)` rather than relying on arrival order** - that key names *when in
  the run* a message belongs, independent of delivery, and it is still the
  right key to sort by even though arrival order is now guaranteed
  non-decreasing in it.

A chart that never uses `<invoke>` or an internal `<send>` was never
exposed to the old seam, and its trace remains byte-comparable run to run,
which is what makes the worked example and the golden test at the end of
this document possible.

## OTel correlation: the `otel` key

A `trace.*` or `effect.*` message may carry an `otel` object identifying the
OpenTelemetry span that covers its macrostep, so a consumer can deep-link a
rendered step to the matching trace in an APM backend. ADR-0013 is the
record; this section is the normative shape.

```json
{"type": "trace.entry_set", "session": "sess_1", "seq": 7,
 "macrostep": 2, "microstep": 1, "round": 0,
 "otel": {"span_id": "00f067aa0ba902b7",
          "trace_id": "4bf92f3577b34da6a3ce929d0e0e4736"},
 "indexes": [3, 4]}
```

| Field | Type | Presence |
|---|---|---|
| trace_id | string | always, within the object |
| span_id | string | always, within the object |

Both are W3C Trace Context hex encodings: `trace_id` is exactly 32
lowercase hex digits, `span_id` exactly 16, with no `0x` prefix, no dashes,
and no uppercase. They name the `statifier.macrostep` span the upstream
bridge opens for this message's macrostep, and the trace that span roots
(statifier `docs/opentelemetry.md`, "A macrostep is a span" and "One trace
per macrostep"). The object is never partial - a producer that can name one
id but not the other omits the key entirely, because half the pair cannot
be looked up in any backend.

**Where it is legal.** Exactly where `macrostep` is legal: on `trace.*` and
`effect.*` messages, and on no others. No `session.*` message ever carries
it. Upstream has no session-lifetime span and no session-lifetime trace, so
a session-scoped message stamped with whichever macrostep span happened to
be open would assert a containment the engine's own bridge declines to
claim. A consumer wanting the trace a session ended inside reads the last
`trace.*` or `effect.*` message before the lifecycle message.

**The value is per macrostep and it repeats.** Every message of one
macrostep in one session carries the same `otel` value, because one span
covers the whole macrostep. Carrying it once per macrostep would be smaller
and is rejected for the reason the `$redacted` sentinel is kept alongside
the `projection` header: a consumer that joined mid-stream, or a single
message pulled out of a log, still has to be able to say what it is.

**Absence.** The key is absent whenever no correlation context is attached -
no bridge in the host, no resolvable span, or a producer predating this
section. It is never `null` and never `{}`; the absence rule above already
spends both of those on other meanings, and neither means "there is no
span".

**Versioning decision.** Adding `otel` is an additive field change, exactly
what the conformance section's MUST-ignore rule makes safe, so **the format
version stays 1** - the same reasoning `round` on the `effect.*` envelopes
and the `projection` header each record. No existing stream changes a byte,
and nothing a v1 consumer previously read correctly is now read incorrectly.

**Golden traces carry no `otel`.** Span and trace ids are random per run, so
a stream carrying them is not byte-comparable run to run. Golden captures
attach no correlation context, exactly as they carry no `projection` header,
and the full-fidelity default is unchanged. A test asserting this key's
shape does so against fixed stub ids, never against a golden.

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
- A value withheld by a projected stream encodes as `{"$redacted": true}`
  (ADR-0012). It is legal wherever a value is legal, including nested inside
  a list or map value. Unlike the four forms above it is a claim about the
  *stream* rather than about the run: it says a value stood here and this
  stream is not carrying it. It is never spelled by key-absence, by `null`,
  by `{}`, or by `{"$undefined": true}`, each of which already means
  something else - see "Projection" below.

The one-key `$`-prefixed object shape is reserved by this document for
exactly these five forms. A host value that happens to be a one-key map
whose only key starts with `$` and is not one of `$undefined`, `$date`,
`$datetime`, `$duration`, or `$redacted` is a spec violation on the
producer's side, not a value this format can carry unambiguously - accepted
as vanishingly rare.

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
reserved for the value codec's five forms, and these are multi-key
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
  that order; it is not additionally sorted** (ADR-0011). This applies to
  `trace.exit_set` and `trace.entry_set`'s `indexes` fields precisely:
  they are sequences in the engine's own emission order - exit order is
  inner-to-outer (the order Appendix D's `exitStates` actually visits
  them), entry order is ascending - and re-sorting the exit set would
  reverse what happened. Both orders are deterministic for a given run,
  so preserving them costs the byte-comparability rule nothing. Every
  other sequence field in this document that is not already identified as
  a genuine set (transition lists, content lists, and so on) likewise
  keeps the engine's own order.

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
| data | array of objects | always |
| source | string | present only when the host supplies chart source |
| fixtures | object | present only when the host supplies a fixtures bundle |
| parent_session | string | present only when this session was started by `<invoke>` |
| invokeid | string | present only when this session was started by `<invoke>` |
| projection | object | present only when the stream is projected - see "Projection" below |

`version` is `1` for this document. It is the fixtures sidecar's own
`version` convention (ADR-0003), reused here rather than invented fresh.

`data` is always present, never key-absent, even when the chart has no
`<datamodel>` at all: an empty datamodel still emits `[]`, the
empty-collection arm of the absence rule below, not the omitted-key arm.

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

**`data`** is one object per compiled `<data>` element, in `d_index`
order (document order across the whole chart, not per `<datamodel>`
block):

| Field | Type | Presence |
|---|---|---|
| d_index | integer | always |
| id | string | always - SCXML requires `id` on `<data>` |
| location | location object | always - the `<data>` element's own span |
| value_location | location object | present only when the compiler recorded a span for the element's value |

This table is deliberately **identity only**: it resolves a `d_index` to
an id and a source span, and carries no representation of the element's
declared value. A consumer wanting to display the declared value reads
it out of `source` at `value_location`, subject to the fallback below; a
consumer wanting a *runtime* value reads `session.datamodel` for the
starting snapshot and the datamodel-change messages after it. The
compiled value itself is an expression program, a compile error, or an
unresolved `src` URI depending on how the element was written, and none
of the three has a language-neutral encoding in this format. Adding a
value field later would be an additive change and therefore not a
version bump (ADR-0005), so this document commits to the narrow shape
now rather than to an encoding it would have to keep.

**`value_location` is not always a value span, and a consumer must check
before slicing.** It spans the element's *written* value only when the
element has one to point at: the `expr` attribute's value for an
`expr`-written element, the `src` attribute's value for a `src`-written
one. An element written with neither - a bare `<data id="x"/>`, or one
whose value is child content - has no distinct value span, and
`value_location` falls back to the `<data>` element's own span, equal to
this row's `location`. So a consumer slicing `source` at
`value_location` must compare it against `location` first: when the two
are equal there is no value span, and the slice is the whole element
(`<data id="x"/>`), not a value. This is the one place `value_location`
parts company with a transition's `cond_location`, which is *absent*
when there is no guard rather than falling back, and therefore always
spans a guard when present.

**A location object** is always all six fields, and is either wholly
present or wholly absent - there is no partial location:

| Field | Type |
|---|---|
| start_line | integer (1-based) |
| start_column | integer (1-based, Unicode codepoints) |
| start_offset | integer (0-based byte offset) |
| end_line | integer (1-based, exclusive) |
| end_column | integer (1-based, Unicode codepoints, exclusive) |
| end_offset | integer (0-based byte offset, exclusive) |

**Ends are exclusive.** A location's `end_line`/`end_column`/`end_offset`
and a span object's `end_line`/`end_column` all name the position **one past**
the last character of the span, so a zero-width span has its start equal to
its end and a consumer slices `[start, end)` without adjustment. This is the
convention statifier's own `Statifier.Parser.Location` and predicator's
`t:Predicator.Types.span/0` both use, and it is stated here rather than left
for a consumer to infer from the data.

**`source`**, when present, is the chart's SCXML text, verbatim. It cannot
be derived from the compiled Machine - the compiled form does not retain
source text - so this document's producer accepts it as caller-supplied
context rather than recovering it. Absence means the host supplied none.

**`fixtures`**, when present, is the ADR-0003 sidecar's decoded JSON object,
carried through verbatim, its own `version` field included. This document's
producer does not construct or validate a fixtures bundle; the caller
supplies an already-decoded object, or supplies none. The carried object may
contain ADR-0006's `datasets` and `expressions` keys alongside ADR-0003's
`scenarios` and `events`; this producer neither constructs nor validates
either of the two additive keys, the same as it does not for the other two.

**`parent_session`** and **`invokeid`**, when present, name the session
that started this one via `<invoke>` and the `invokeid` this session
stamps, respectively. Together they let a consumer holding two sessions'
`session.start` messages reconstruct the parent-child edge between them
without any other channel. Both are absent for a session with no invoking
parent.

**A caveat on location granularity.** The tables above are built from the
compiled `%Statifier.Machine{}` layer, which carries element-level spans -
a whole `<transition>`, a whole `<assign>` - plus a transition's own
`cond_location` for its guard expression specifically and a `<data>`
element's own `value_location` for its declared value where the element
was written with one (see the `data` table's fallback note above). It
does **not**
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
| data | value | present only when data was supplied and is not an expression-evaluation failure (absence-rule: `:undefined` omits the key, `nil` present as `null`, `%{}` present as `{}`; omitted, instead of failing to normalize, when the event's data is an expression-evaluation failure - such an event carries `error` instead) |
| error | error object | present only when the event's data is an expression-evaluation failure |
| type | string | always - `"external"`, `"internal"`, or `"platform"` |
| cause | cause object | present only for `"internal"`/`"platform"` events the platform itself raised |
| invokeid | string | present only when set |
| origin | string | present only when set |
| origintype | string | present only when set |
| sendid | string | present only when set |

**An error object** is the wire rendering of a failed expression
evaluation (`Statifier.Evaluator.Error.t()`), produced when an event's data
is such a failure rather than a value:

| Field | Type | Presence |
|---|---|---|
| kind | string | always - the underscored name of the predicator error struct, trailing `_error` dropped (e.g. `"undefined_variable"`, `"type_mismatch"`, `"evaluation"`, `"parse"`, `"location"`) |
| expression | string | always - the failing expression's **entity-expanded** text, not the raw source |
| span | span object (`start_line`, `start_column`, `end_line`, `end_column`) | present only when the underlying evaluator error carries a span within `expression` |
| location | location object | present only when the producer had both a `Statifier.Machine.t()` and `source` to resolve against, and could anchor the failure on a location at all |
| location_kind | string | present only alongside `location` - `"resolved"` or `"node"`, see below |

Three notes a consumer needs before using this object to underline
anything:

- **`expression` is not raw source.** It is the entity-expanded string the
  expression engine counted columns in - a `cond` written `amount &lt; limit`
  appears here as `amount < limit`. `span`'s columns are offsets into this
  expanded string, not into `source`, and cannot be added to a raw-source
  column directly. This is why `location` exists: it is pre-resolved for
  you.
- **`location` is absolute and already resolved.** A consumer underlines it
  directly against `source`, with no span composition of its own. This is
  the field that makes the format usable by a consumer with no Elixir and no
  compiler.
- **`location_kind` says what the producer did, not what happened
  internally.** `"resolved"` means the span was composed against the
  expression's own value location; `"node"` means there was no span to
  compose, or no value location to compose it against, and the owning
  node's whole span was emitted instead. **`"resolved"` may still span the
  whole attribute value**: the composition degrades rather than failing
  when the raw and entity-expanded text desync, and the producer does not
  distinguish that case from a genuine resolution. Treat this as a
  documented limitation, not a promise that `"resolved"` always narrows to
  the failing subexpression.

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

## The ten `effect.*` schemas

The core (non-trace) statifier effects, mapped one-to-one onto their
own namespace: the nine originals plus `effect.datamodel_change`
(`Statifier.Effect.DatamodelChange`, `st-oef3`). The engine's eleventh
core effect, `Statifier.Effect.DatamodelInit`, is the one exception to
the one-to-one mapping - it serializes as `session.datamodel`, below.
ADR-0005 leaves non-trace effect naming to this document
("their own namespaces as consumers need them"); this document uses one
`effect.*` family rather than several separate top-level namespaces,
because a bare top-level `done` type would sit confusingly next to
`trace.done` - a different message about the same moment in the run.
`effect.*` and `trace.*` are two visibly distinct halves of the vocabulary:
`trace.*` are the nine Appendix D phase boundaries and `effect.*` are the
core effect vocabulary, both stamped with all three counters (see "The
envelope" above; `round` joined the `effect.*` envelopes in `sui-67d`,
after `effect.budget_exhausted` had carried it from the start).

Every `effect.*` message carries `macrostep`, `microstep`, and `round`.

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
quiescence (ADR-0019). This was the one core effect that carried `round`
before `sui-67d` propagated the key onto the rest of the `effect.*`
family - see "The envelope" above.

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

### `effect.datamodel_change`

Emitted once per successful datamodel write (`st-oef3`): an `<assign>`, a
`<data>` binding during the binding fold, a `<send idlocation>` write, an
`<invoke idlocation>` write, or an empty-`<finalize>` auto-assign. A failed
write emits nothing - the datamodel did not change, and the failure is
already on the error channel. Together with `session.datamodel`'s starting
snapshot, the sequence of these messages reconstructs the datamodel at any
point in the run from the stream alone.

| Field | Type | Presence |
|---|---|---|
| location_path | array of strings and integers | always - the resolved write path; see below |
| location_source | string | always - the raw author string that named the location (`items[i].name` as written) |
| new_value | value | present unless the write stored the unbound sentinel; a stored null is present as `null` (three-way absence rule) |
| prior_value | value | present unless nothing stood at the path before the write; a previously stored null is present as `null` (three-way absence rule) |
| d_index | integer | present only for a `<data>` binding - resolves through `session.start`'s `data` table |
| c_index | integer | present only when a content node performed the write (`<assign>`, `<send idlocation>`) |
| owner | owner object | present only when known - which construct performed the write |

**`location_path` is a heterogeneous JSON array.** Each segment is either a
string - an object key, the variable name first - or an integer, a 0-based
array index: `user.items[0].name` resolved against `i = 0` arrives as
`["user", "items", 0, "name"]`. JSON's own typing carries the distinction -
the string `"0"` is a key, the number `0` is an index - so no tagging or
escaping is needed, and a consumer applies the segments in order to its own
copy of the datamodel to reproduce the write. It is the *resolved* path:
an index expression like `[i]` has already been evaluated by the engine,
which is what makes the path applicable without the pre-assignment
datamodel. `location_source` is the raw author string kept alongside for
display; neither substitutes for the other.

**`new_value` and `prior_value` follow the `_event.data` three-way rule**,
because the engine genuinely distinguishes unbound from null here
(statifier ADR-0037 spells unbound as `:undefined`): key absence means the
slot was or became unbound - for `prior_value`, that nothing stood at the
path before the write, the common case for a first assignment - while JSON
`null` means a genuinely stored null.

**`d_index` and `c_index` are mutually exclusive** on this message: a
`d_index` means the write was a `<data>` binding, which belongs to no
content block and therefore also carries no `owner`; a `c_index` means a
content node performed it. The two runner-side writes - the
empty-`<finalize>` auto-assign and `<invoke idlocation>` - carry neither,
identified by `owner` alone (`"finalize"` and `"invoke"` kinds
respectively).

**Versioning decision, recorded rather than left implicit:** this type
joined the format after version 1 shipped with 23 types. Adding a type is
exactly what the conformance section's MUST-ignore rule makes additive, so
**the format version stays 1** - unlike `session.datamodel`, which kept
version 1 because its type string was already reserved, this one keeps it
because new types never bump the version at all.

## Origins

The `origin` type on `Statifier.Event.Cause` has eight variants, each a
tagged object with `"kind"` naming the tuple's tag:

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

A `d_index` anywhere in this format - here or on
`effect.datamodel_change` - resolves through `session.start`'s
`data` table, the same way a `state_index` resolves through `states` and
a `t_index` through `transitions`.

## Owners

The `owner` type on `Statifier.Machine.Content` has four variants, plus the case
`Statifier.Effect.Trace.ContentExecuted` widens it with for a top-level
`<script>` and the case `Statifier.Effect.DatamodelChange` widens it with
for `<invoke idlocation>`, together the six variants an `owner` field may
take anywhere in this format:

| "kind" | Fields | Meaning |
|---|---|---|
| "onentry" | state_index (integer), ordinal (integer) | an `<onentry>` block; ordinal is the block's position in the state's own `onentry` list |
| "onexit" | state_index (integer), ordinal (integer) | an `<onexit>` block; ordinal is the block's position in the state's own `onexit` list |
| "transition" | t_index (integer) | a transition's own executable content |
| "finalize" | state_index (integer), invoke_index (integer) | an `<invoke>`'s own `<finalize>` block |
| "global_script" | index (integer) | a top-level `<script>`, run at load time - only ever appears as `trace.content_executed`'s owner, since a top-level script belongs to no `<onentry>`/`<onexit>`/transition block |
| "invoke" | state_index (integer), invoke_index (integer) | an `<invoke idlocation>` write - only ever appears as `effect.datamodel_change`'s owner, since the write belongs to no content block |

## The `session.*` types

Five types name a session from the outside: its start, one snapshot of the
values it started with, and the three ways a subscriber's own stream can
end or change state. None of the five carry `macrostep`/`microstep`/
`round` - the four lifecycle types because they describe the *stream*, not
a point inside a run, and `session.datamodel` because it precedes the
first macrostep entirely (its underlying effect payload carries `macrostep`/
`microstep`/`round` internally, but this producer stays consistent with
every other `session.*` type and leaves the envelope counters `nil`).

### `session.start`

The definition message. Schema above under "`session.start`". Always
`seq: 0`.

### `session.datamodel`

Emitted exactly once per session, unconditionally - even under
`trace: false` - as the second message on the stream, right after
`session.start`, from statifier's `Statifier.Effect.DatamodelInit`
(`st-1xwh`). It carries the datamodel's starting values: spec 5.3.3's
unconditional `<data>` creation plus the four spec 5.10 system variables,
before the binding fold that follows it.

Because the snapshot precedes that fold, **every** `<data>` element appears
as `{"$undefined": true}`, not only the ones declared without a value: a
`<data id="count" expr="41 + 1"/>` is present under `count` as
`{"$undefined": true}` here, and is assigned its `42` afterwards. This
message therefore names the datamodel's variables reliably, but is not a
source for their values. The assignments that follow arrive as
`effect.datamodel_change` messages (`sui-h92`), one per successful write,
binding fold included - a consumer folds them over this snapshot to hold
the current datamodel at any point in the run.

This message keys the datamodel by variable name; `session.start`'s
`data` table keys the same elements by `d_index` and carries the `id`
that joins the two.

| Field | Type | Presence |
|---|---|---|
| datamodel | object | always - the session's starting datamodel, keyed by variable name, values encoded by the `$`-tagged value discipline |

### `session.halted`

Emitted when the session reports `{:halted, reason}` to its subscriber.

| Field | Type | Presence |
|---|---|---|
| reason | string | always - one of `"done"`, `"cancelled"`, `"budget_exhausted"` |

As of ADR-0044 (`st-r6l9`), `session.halted` is terminal for that session
id: no further messages for the same session id follow it (see "Ordering"
above). Terminal is scoped **per session id, not per mailbox** - ADR-0050
lets a subscriber observe an invoke tree of related sessions on one
mailbox, and a parent's `session.halted` does not end the stream for a
child session still running on the same mailbox.

### `session.terminated`

Emitted when the subscriber observes the session's process exit (a
monitor `:DOWN`).

| Field | Type | Presence |
|---|---|---|
| reason | string | always - `inspect/1` of the Elixir exit reason |

`reason` is a human-readable string, not structured data to branch on - an
Elixir process exit reason has no language-neutral shape, so this document
does not attempt to give it one.

Under a projected stream this is the one field whose JSON type changes: it
carries `{"$redacted": true}` instead of a string. It earns the exception
because it is `inspect/1` of an exit reason, so a crash inside a datamodel
operation can carry datamodel terms into it verbatim, and it is the one
string field on the wire whose content is genuinely unbounded. Nothing may
be branching on its shape, because the paragraph above already says not to.

### `session.unroutable`

Emitted when the session reports `{:unroutable, effect}` to its subscriber
- an effect the session could not route to a destination. Currently
unreachable in the engine as shipped, reserved for when it becomes
reachable.

| Field | Type | Presence |
|---|---|---|
| effect | object | always - the unrouted effect, encoded the same way its own `effect.*` or `trace.*` type would encode it, under a `kind` key naming that type |

## Projection

A projected stream carries the run's structure, transitions, outcomes and
ordering, and withholds its values. It exists for the second consumer of
this format: a multi-tenant host showing a run's history to the end user
whose run it is, who is not entitled to the datamodel behind it. ADR-0012 is
the record.

**Full fidelity is the default and is byte-unchanged.** A producer not asked
to project emits no `projection` key, no sentinels, and full values. Every
existing golden trace is byte-identical. Projection is something a host
turns on for a subscription, one session at a time.

**The version stays `1`.** A v1 producer never emitted `$redacted`, so no
existing stream changes; a v1 consumer meeting one renders an unfamiliar
one-key map, which is conspicuous rather than silently wrong, and the
`projection` header says why. Nothing a v1 consumer previously read
correctly is now read incorrectly, which is this document's own test for a
bump.

### The `projection` header

`session.start` carries a `projection` object whenever the stream is
projected:

```json
{"mode": "projected", "profile": "end_user_run_history"}
```

| Field | Type | Presence |
|---|---|---|
| mode | string | always, within the object - `"projected"` |
| profile | string | always, within the object - the profile's name |

Key absence means full fidelity. Distinguishability is not optional: a
capture that cannot say whether it is redacted cannot be filed by an
operator; a golden-trace comparison between a projected capture and a full
golden fails for a reason that has nothing to do with conformance, and the
header is what lets a test say so; and a datamodel pane rendering a redacted
stream must show "redacted", not "unbound".

Per-message self-announcement through the `$redacted` sentinel is kept **in
addition** to the header, not instead of it, so a consumer that joined
mid-stream or a single message pulled out of a log still says what it is.

### The closed set of value positions

Every position below is redacted unless a profile allows it back. The table
is the checklist: a value position added to this format later without a
projection rule would carry values through a projected stream silently,
which is the worst failure available here because it is invisible.

`error` carries no value position by construction: the predicator error's
rendered message - the field that would embed datamodel values - is
deliberately not on the wire (see the `error` object's fields above), so
`trace.event_dequeued`'s `error` key needs no row in this table.

| Message | Position |
|---|---|
| `session.datamodel` | every value in `datamodel` |
| `effect.datamodel_change` | `new_value`, `prior_value` |
| `trace.event_dequeued` | `event.data` |
| `trace.transitions_selected` | `event.data` |
| `trace.finalize_autoforward` | `event.data` |
| `trace.done` | `donedata` |
| `effect.done` | `donedata` |
| `effect.autoforward` | `event.data` |
| `effect.budget_exhausted` | `data` on each `pending_internal_events` entry |
| `effect.log` | `value` |
| `effect.invoke` | `params`, `content` |
| `effect.send` | `data` |
| `effect.send_delayed` | `data` |
| `session.unroutable` | every value position of the nested `effect`, recursively |
| `session.start` | `fixtures`, replaced whole; `source` when `allow_source` is false |
| `session.terminated` | `reason`, replaced whole |

`session.unroutable` wraps another type's encoding under a `kind` key, so a
projection must recurse into it rather than pattern-matching the outer type.
It is unreachable in the engine as shipped, which is exactly why it is easy
to forget.

`session.datamodel` keeps its keys. Variable names come from the chart, not
from the run, and this message's stated job is to name the datamodel's
variables reliably - which it still does.

`session.start`'s `fixtures` is a datamodel bundle by construction
(ADR-0003), so it is replaced whole rather than descended into. A host that
supplied no fixtures still omits the key, as today, and the two states stay
distinguishable.

**Redaction replaces at a key that is already present; it never creates
one.** Nine of these positions are conditionally absent, and writing a
sentinel into an absent key would assert something the run never did: an
eventless round (`trace.transitions_selected` with no `event`) becoming
evented, a first write (`effect.datamodel_change` with no `prior_value`)
acquiring a prior value, or a host that supplied no fixtures acquiring a
bundle.

### What is never projected

`type`, `session`, `seq`, `macrostep`, `microstep`, `round`, `otel`; state
indexes, `t_index`, `c_index`, `d_index`, `invokeid`, `send_id`, `state_index`,
`invoke_index`; every `session.start` table (`states`, `transitions`,
`contents`, `data`) and every `location` and `value_location` object in
them; configurations; exit and entry sequences in their engine order;
selected `t_index` lists; `kind` and `type` discriminators; owner and origin
objects; event `name`s; transition event descriptors; `label` on
`effect.log`; `src` and `invoke_type` on `effect.invoke`; `target` and
`send_type` on the send family; `location_path` and `location_source` on
`effect.datamodel_change`; `session.halted`'s `reason` (a closed three-value
set); `effect.done`'s `configuration`; and, on `trace.event_dequeued`'s
`error` object, `kind`, `span`, `location`, and `location_kind`.

That list is what leaves a projected stream worth rendering at all: the
timeline, the diagram highlighting, the click-through to source, and the
run's outcome are built entirely from fields in it.

`otel` is in that list because a trace id and a span id are randomly
generated identifiers carrying no chart vocabulary, no datamodel value, and
no source text - the same category as `seq` and `macrostep`. The residual
is real and stated rather than waved at: a trace id is a join key into a
backend that may hold what this stream withheld. The control for that is
attaching no correlation context to a subscription a projected audience
reads, which makes the key absent; there is no projection knob for it, and
ADR-0013 records why not.

`session.start`'s `data` table is already deliberately identity-only - it
carries `d_index`, `id`, `location`, and `value_location`, and no
representation of the declared value - so it needs no rule.

### Allowlists: two shapes, because there are two kinds of position

Within projected mode the default is deny.

**Located positions** - the datamodel - are allowlisted by **path prefix**,
written as arrays of segments in the same encoding
`effect.datamodel_change`'s `location_path` already uses:

```
allow_paths: [["authorization", "status"], ["account", "currency"]]
```

So `["authorization"]` allows the whole `authorization` subtree and
`["authorization", "status"]` allows one leaf. The same prefixes apply to
`session.datamodel`, whose keys are the first segment of every path. That is
why the datamodel allowlist is expressed by path and not by variable name:
one expression covers both messages, and a host that may show
`authorization.status` but not `authorization.amount_cents` can say so.

Three cases, and the third is the operator ruling of 2026-08-29 recorded on
ADR-0012:

- An allowed prefix **matches the write's leading segments** (the prefix is
  no longer than the write's path): the whole value passes.
- No allowed prefix relates to the path: the whole value is redacted.
- An allowed prefix is **longer than the write's path and extends it** - the
  write is shallower than the prefix, so the written value contains both the
  allowed leaf and its withheld siblings. The projection **descends into the
  value** and redacts selectively, so the allowed leaf passes and every
  sibling is redacted. Allowing the whole write would leak a sibling the
  profile withheld; denying it would withhold a leaf the profile allowed.

Descent applies identically to `session.datamodel`'s snapshot values. Where
a value cannot be descended into because it is a scalar rather than an
object or an array, the allowed leaf is unreachable and the value is
redacted whole.

**Unlocated positions** - payloads, which have no path - are allowlisted by
naming the position, from a closed set:

```
allow_positions: [:event_data, :log_value, :send_data,
                  :invoke_params, :invoke_content, :donedata]
```

Naming a position allows it wholesale, at every message that carries it.
There is deliberately no per-key allowlist inside a payload: an event
payload has no stable schema the way a datamodel location does, so a
key-level rule there would be a guess that silently stops matching when a
chart changes - and a redaction rule that silently stops matching is the
failure this whole section exists to avoid. A host needing finer control
over a payload narrows what the chart puts in it.

### `allow_source`

`session.start`'s `source` is verbatim SCXML. It is authored rather than run
data, and it is what the whole inspector resolves indexes against, so
projection retains it by default.

The honest caveat: the `data` table's `value_location` exists so a consumer
can recover a `<data>` element's declared initial value by slicing `source`.
So retaining `source` retains **declared** initial values, even under a
profile that redacts everything else. Runtime values are unaffected - the
binding fold's results arrive as `effect.datamodel_change` and are redacted
normally - but a chart with a literal secret in a `<data expr="...">` is not
protected by projection.

A profile may set `allow_source: false`, which replaces `source` with the
sentinel. The cost is stated plainly: without `source`, location objects
still resolve to line and column but nothing can display the text at them,
so click-through degrades to coordinates.

`trace.event_dequeued`'s `error.expression` is chart text under the same
reasoning - it is the failing expression's entity-expanded source, not run
data - so `allow_source: false` redacts it alongside `source`. `error`'s
other keys (`kind`, `span`, `location`, `location_kind`) are unaffected.

### What projection is not

**It is not anonymization.** Structure leaks. Which branch a run took, how
many rounds a macrostep needed, which transition fired on which event -
these imply things about the values that produced them, and an observer with
the chart in hand can infer a great deal from a fully redacted stream. The
guarantee is narrow and worth stating in those terms: **no datamodel value
crosses the producer boundary.** A host needing more than that needs to
withhold structure, which this format does not provide.

**It is not access control.** It shapes one stream. It does not
authenticate a subscriber, does not decide which sessions a subscriber may
see, and does not stop a host attaching a full-fidelity subscriber alongside
a projected one. Choosing the profile correctly per tenant is the host's
job, and this format cannot check it.

**A projected capture is not byte-comparable to a full one.** Golden-trace
conformance does not transfer: a profile whose output matters is tested
against its own golden, produced under that profile. The existing goldens
stay valid because the default is untouched.

`location_path`'s integer segments are resolved index expressions, so a
projected stream still reveals which array index a write landed on - a
narrow inference channel about a value the same stream redacts. It is
retained because a consumer that cannot see the path cannot fold the write
at all, which would cost the whole datamodel-shape view for very little.

## Worked example

The complete JSON Lines trace of a two-state chart with one external
transition. The producer ran with `session_id: "sess_golden"`, attached
early (`Statifier.Trace.Subscriber`'s `:subscribers`-at-`start_link` path,
`docs/plans/260817-sui-t36.3-session-subscriber-and-trace-normalizer.md`
phase 5), so it sees the initialize burst that runs to quiescence before
`Statifier.Session.start_link/2` returns. This is the same fixture phase
5's golden test compares against byte-for-byte
(`test/support/trace/two_state.jsonl`).

Chart:

```xml
<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
    <state id="a">
        <transition event="go" target="b"/>
    </state>
    <state id="b"/>
</scxml>
```

`xmlns` and `version` are required attributes on the root element
(`Statifier.Validator`); a chart missing either fails to compile, so an
example chart must carry both even though they add nothing to the
trace itself.

Driven with one external event, `"go"`, with no data, after the session
has already come up and settled into `a` on its own. Trace (one JSON
object per line, each shown here with lexicographic keys exactly as the
wire form produces - the actual bytes, not a reformatting):

```json
{"contents":[],"data":[],"seq":0,"session":"sess_golden","states":[{"children":[1,2],"index":0,"kind":"scxml","location":{"end_column":9,"end_line":6,"end_offset":178,"start_column":1,"start_line":1,"start_offset":0},"transitions":[]},{"children":[],"id":"a","index":1,"kind":"state","location":{"end_column":13,"end_line":4,"end_offset":149,"start_column":5,"start_line":2,"start_offset":78},"parent":0,"transitions":[0]},{"children":[],"id":"b","index":2,"kind":"state","location":{"end_column":20,"end_line":5,"end_offset":169,"start_column":5,"start_line":5,"start_offset":154},"parent":0,"transitions":[]}],"transitions":[{"content":[],"events":[["go"]],"location":{"end_column":44,"end_line":3,"end_offset":136,"start_column":9,"start_line":3,"start_offset":101},"source":1,"t_index":0,"targets":[2],"type":"external"}],"type":"session.start","version":1}
{"datamodel":{"_event":{"$undefined":true},"_ioprocessors":{"http://www.w3.org/TR/scxml/#SCXMLEventProcessor":{"location":"#_scxml_sess_golden"}},"_name":{"$undefined":true},"_sessionid":"sess_golden"},"seq":1,"session":"sess_golden","type":"session.datamodel"}
{"indexes":[0,1],"macrostep":1,"microstep":1,"round":0,"seq":2,"session":"sess_golden","type":"trace.entry_set"}
{"macrostep":1,"microstep":1,"round":1,"seq":3,"session":"sess_golden","t_indexes":[],"type":"trace.transitions_selected"}
{"invoke_ids":[],"macrostep":1,"microstep":1,"round":1,"seq":4,"session":"sess_golden","state_indexes":[0,1],"type":"trace.invoke_pass"}
{"configuration":[0,1],"macrostep":1,"microstep":1,"round":1,"seq":5,"session":"sess_golden","type":"trace.macrostep_stable"}
{"event":{"name":"go","type":"external"},"from":"external","macrostep":2,"microstep":0,"round":0,"seq":6,"session":"sess_golden","type":"trace.event_dequeued"}
{"event":{"name":"go","type":"external"},"finalized":[],"forwarded":[],"macrostep":2,"microstep":0,"round":0,"seq":7,"session":"sess_golden","type":"trace.finalize_autoforward"}
{"event":{"name":"go","type":"external"},"macrostep":2,"microstep":0,"round":0,"seq":8,"session":"sess_golden","t_indexes":[0],"type":"trace.transitions_selected"}
{"indexes":[1],"macrostep":2,"microstep":1,"round":0,"seq":9,"session":"sess_golden","type":"trace.exit_set"}
{"c_indexes":[],"macrostep":2,"microstep":1,"owner":{"kind":"transition","t_index":0},"round":0,"seq":10,"session":"sess_golden","type":"trace.content_executed"}
{"indexes":[2],"macrostep":2,"microstep":1,"round":0,"seq":11,"session":"sess_golden","type":"trace.entry_set"}
{"macrostep":2,"microstep":1,"round":1,"seq":12,"session":"sess_golden","t_indexes":[],"type":"trace.transitions_selected"}
{"invoke_ids":[],"macrostep":2,"microstep":1,"round":1,"seq":13,"session":"sess_golden","state_indexes":[2],"type":"trace.invoke_pass"}
{"configuration":[0,2],"macrostep":2,"microstep":1,"round":1,"seq":14,"session":"sess_golden","type":"trace.macrostep_stable"}
```

`seq` starts at `0` on `session.start` and increments by one across every
subsequent message, with no gaps - this chart never touches the `<invoke>`/
internal-`<send>` reordering seam, so a producer's live delivery order and
`(macrostep, round)` order agree throughout, and the trace above is
byte-comparable run to run. `session.datamodel` at `seq` `1` always follows
`session.start` and always precedes the first `trace.*` message, carrying
no `macrostep`/`microstep`/`round` of its own. `macrostep` `1` is the session's own
initialize burst (Appendix D's `initialize` procedure, entering `a` before
any event is ever sent - `configuration` on `trace.macrostep_stable` is
`[0, 2]` later, not `[2]`, because the synthesized root at index `0` is
always a member); `macrostep` `2` is the driven `"go"` transition into
`b`. `trace.content_executed` appears once, for the transition's own
(empty) executable content list; `trace.done` does not appear because
this run never halts through a `<final>` state - a chart reaching one
would show it in the shape its schema above describes.

## Type index

One row per type this document defines - 24 rows: 9 `trace.*`, 10
`effect.*`, and 5 `session.*` (the four lifecycle types plus
`session.datamodel`). This table's first column is a machine boundary: a
drift test parses exactly this table's backtick-quoted `type` strings and
asserts them equal to the producer's own emitted type set, so a type
documented here and not emitted, or emitted and not documented here, fails
that test rather than drifting silently.

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
| `effect.datamodel_change` | effect | a datamodel location is successfully written |
| `session.start` | session | a session's stream opens |
| `session.halted` | session | the session reports `{:halted, reason}` |
| `session.terminated` | session | the session's process exits |
| `session.unroutable` | session | the session reports an unroutable effect |
| `session.datamodel` | session | a session's datamodel is initialized |

## References

- ADR-0005 (`docs/adr/0005-language-neutral-trace-wire-format.md`) - the
  envelope, the nine `trace.*` type names, the `session.start` role, the
  JSON discipline this document restates by reference, versioning, and the
  clause naming this document as the format's normative home.
- ADR-0013 (`docs/adr/0013-otel-correlation-in-the-wire-format.md`) - the
  `otel` key: its name, its shape, the messages that may carry it, its
  projection rule, and the host-supplied seam that fills it in.
- statifier `docs/opentelemetry.md` and statifier ADR-0062 - the span
  topology the `otel` key points into, and the separate bridge package that
  produces it. This document depends on neither at runtime; it points at
  their identifiers.
- ADR-0003 (`docs/adr/0003-fixtures-as-the-example-data-contract.md`) - the
  fixtures sidecar object `session.start`'s `fixtures` field carries
  verbatim.
- ADR-0006 (`docs/adr/0006-datasets-and-expression-fixtures.md`) - the
  `datasets` and `expressions` keys the same carried object may additionally
  contain.
- `st-nbmj` - the upstream gap behind `effect.*` messages once carrying no
  `round`, superseded by `st-xb2b`, whose ADR-0046 settled it (the two ids
  name one thread of work: `st-nbmj` filed the gap, `st-xb2b` decided it);
  this producer's own propagation of `round` onto `effect.*` messages was
  `sui-67d`, above.
- `st-r6l9` - the upstream reordering seam behind the old ordering warning
  above, closed by ADR-0044.
- `st-1xwh` - the upstream effect (`Statifier.Effect.DatamodelInit`) behind
  `session.datamodel`, above.
- `st-oef3` - the upstream effect (`Statifier.Effect.DatamodelChange`)
  behind `effect.datamodel_change` - a per-write value change, distinct
  from `session.datamodel`'s one-time starting snapshot; serialized here
  by `sui-h92`.
- `sui-qay` - the gap behind `session.start`'s location tables carrying no
  attribute-level spans.
