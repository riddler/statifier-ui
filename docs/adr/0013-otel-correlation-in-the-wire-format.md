# ADR-0013: OTel correlation in the trace wire format

Status: accepted (2026-09-01, campaign-025; unqualified direction-agent verdict)

Extends ADR-0005 additively: one new optional envelope key, reserved by
name, carried on the message families that already carry the step counters.
No type is added, removed, or renamed; no existing field changes meaning;
no existing stream changes a byte. The format version stays `1` - see
"Versioning decision" below.

## Context

Statifier's OpenTelemetry design landed upstream: statifier ADR-0062 puts
the bridge in a separate package, `opentelemetry_statifier`, and statifier's
`docs/opentelemetry.md` fixes the span topology the bridge implements. Two
of its decisions are the ones this record is downstream of:

- **A macrostep is a span.** The bridge opens a span on
  `[:statifier, :session, :macrostep, :start]` and closes it on the matching
  `:stop`, named `statifier.macrostep`, with the chart vocabulary as
  attributes rather than in the span name.
- **One trace per macrostep, stitched with links.** There is deliberately no
  session-lifetime span and no session-lifetime trace: a session can live
  for days behind a persistence host, so each macrostep span is the root of
  its own trace, linked to the previous macrostep's span and, for a child
  session's `:initialize`, to the invoking parent's.

This project renders the same runs those spans describe. A host that runs
statifier under a production APM backend and also shows an operator this
package's inspector has two accounts of one run - a timeline of `trace.*`
and `effect.*` messages here, and a set of macrostep traces there - with
nothing in either account naming the other. An operator looking at a
misbehaving macrostep in the inspector cannot get to its trace, and one
looking at a slow `statifier.macrostep` span cannot get to the phase-by-phase
detail that would explain it. The join is the point of doing either.

The operator ruling of 2026-09-01 (campaign-025 ruling R25-2, recorded as a
dated note on `sui-b94`) settled the question this record's bead was filed to
ask, and left one thing open:

> wire format v1 carries one optional additive key per macrostep for OTel
> correlation (trace/span id); absent when no bridge is attached; no format
> version bump. Exact field naming is this bead's ADR's to fix.

So the *whether* is decided and not reopened here. What is open, and what
this record decides, is the key's name, its shape, where in a message it
sits, which messages carry it, what a projected stream does with it, and
what the producer must be given to fill it in.

Two constraints inherited rather than argued:

- **Nothing in this repository calls an OTel API.** statifier
  `docs/opentelemetry.md` states it for the engine ("no OTel API call
  anywhere but the bridge"), and this package is in the same position for
  the same reasons. ADR-0004 additionally makes every integration here
  optional at compile time; an `opentelemetry_api` dependency would be
  neither optional nor, in a component library a host mounts, its own call
  to make.
- **This record does not adopt statifier ADR-0040.** ADR-0002 considered the
  session telemetry event contract for its adopted list and declined it, and
  nothing here changes that: this package still consumes the effect stream at
  the ADR-0003 / ADR-0012 seams and reads no telemetry event. The
  correlation ids reach this producer as opaque strings a host hands it,
  never by this package subscribing to `[:statifier, :session, ...]`.

## Decision

### The key is `otel`, and it sits in the envelope

A message may carry an `otel` object beside the step counters:

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

Both are the W3C Trace Context hex encodings, which is what makes the key
readable by a consumer that knows the standard and not this format: a
`trace_id` is exactly 32 lowercase hex digits, a `span_id` exactly 16, with
no `0x` prefix, no dashes, and no uppercase. They identify the
`statifier.macrostep` span that covers this message's macrostep, and the
trace that span roots.

The object is never partial. A producer that can name a span but not its
trace, or the reverse, omits the key entirely rather than writing half of
it - a `span_id` without its `trace_id` cannot be looked up in any backend,
so half the pair is not a degraded correlation but an unusable one.

**The name.** `otel` beat three alternatives:

- `trace_context`, after the W3C standard the values encode, is the closest
  call and loses on collision. "Trace" is already this format's own word: the
  nine `trace.*` message types, the engine's `trace: true` knob, the
  "trace wire format" in this repository's name for the thing being extended.
  A key called `trace_context` in an envelope that also carries a
  `trace.entry_set` `type` invites exactly one misreading - that it is
  context about *this* trace family - and that misreading is silent.
- `correlation`, or any other generic name, states a category rather than a
  contract, and a generic slot is an invitation to put other things in it.
  The key holds OTel span identity and nothing else; a second tracing system
  arriving later gets its own key rather than a shared one whose meaning
  quietly widens.
- `span`, alone, names half its own contents and reads as though the format
  had a concept of spans of its own. It does not.

`otel` names the ecosystem the ids come from, matches the upstream package
name `opentelemetry_statifier` (statifier ADR-0062), and is not a word this
format already spends on something else. That it is not vendor-neutral is
the intended reading: this key is the OpenTelemetry join and makes no claim
to be a general correlation mechanism.

`otel` joins `type`, `session`, `seq`, `macrostep`, `microstep`, and `round`
as a reserved word: no payload may use it for anything else, in any message,
at the message's top level.

### It is legal exactly where `macrostep` is legal

The `otel` key may appear on `trace.*` and `effect.*` messages - the two
families that carry the step counters - and on no others. `session.start`,
`session.datamodel`, `session.halted`, `session.terminated`, and
`session.unroutable` never carry it.

That rule is inherited rather than chosen. Upstream has no session-lifetime
span and no session-lifetime trace, so there is no id for a session-scoped
message to carry; a `session.*` message stamped with whichever macrostep
span happened to be open would assert a containment upstream deliberately
does not claim. A consumer wanting the trace a session ended inside reads
the last `trace.*` or `effect.*` message before the lifecycle message, which
is a true statement about the run rather than an invented one.

### The value is per macrostep, and it is repeated

Every message of one macrostep in one session carries the same `otel` value,
because upstream opens one span for the whole macrostep. The key is
therefore per-macrostep by *value* and per-message by *position*.

Carrying it once per macrostep - on the first message, or on
`trace.macrostep_stable` - would be smaller and is rejected for the reason
this document already gives for keeping the `$redacted` sentinel alongside
the `projection` header: a consumer that joined mid-stream, or a single
message pulled out of a log by an operator, still has to be able to say what
it is. A correlation id that is only correct when you have the whole stream
in order is not much of a correlation id. `trace.macrostep_stable`
specifically would also be the worst carrier available, since it is the
message that arrives *last* in a macrostep and the one a budget-exhausted
macrostep never emits at all.

The cost is bytes, on streams that opted into carrying the ids at all.
Accepted, and named here so nobody has to rediscover that it was weighed.

### Versioning decision: the version stays `1`

Adding a field is not a version bump under ADR-0005's MUST-ignore rules,
restated in this document's conformance section and applied twice already
(`round` on the remaining `effect.*` envelopes; the whole
`effect.datamodel_change` type). This is the same case and the reasoning is
not re-derived: a v1 consumer ignores a key it does not recognize, and
nothing it previously read correctly is now read incorrectly, which is this
format's own test for a bump.

Absence stays meaningful in exactly the way the format's absence rule
already requires. No bridge attached, no context resolvable, or a producer
that predates this record: the key is absent. It is never `null` and never
`{}` - both of those mean something else here, and neither means "there is
no span".

### A projected stream carries `otel` unchanged

`otel` is added to what is never projected (ADR-0012). A trace id and a span
id are randomly generated identifiers that carry no chart vocabulary, no
datamodel value, no source text, and nothing derived from any of them - they
are in the same category as `seq` and `macrostep`, and redacting them would
break the correlation for the reader most likely to need it while protecting
nothing.

The residual is stated rather than waved at: a trace id is a join key into a
backend, so anyone holding a projected stream *and* access to that backend
can reach data the projection withheld. That is a statement about who has
the backend, not about this stream, and the honest control for it is the
control that already exists - a host that does not want an audience holding
correlation ids attaches no context for that subscription, and the key is
absent. Projection profiles do not gain a knob for this; the bridge seam
below is where it belongs, and a profile-level switch would only give a host
two places to get the same decision wrong.

### The producer is given the ids; it never reads them

This package resolves nothing itself. `session.start` gains no OTel field
and no configuration; the subscriber gains one option, and its value comes
from the host:

    otel_context: (session_id, macrostep ->
                     {:ok, %{trace_id: binary, span_id: binary}} | :none)

The producer calls it when it stamps a message that may carry the key, and
writes `otel` only on `{:ok, _}` with both ids present and well-formed. On
`:none`, on a malformed pair, or on the option being absent - the default -
the key is omitted. A resolver that raises is treated as `:none` for that
message; correlation metadata is not worth failing a run over, and this is
the one place in this package where that trade is the right one.

Two things follow, and both are deliberate:

- The dependency direction is preserved. A 2-arity function is not an OTel
  API; hosts that already depend on `opentelemetry_statifier` supply one,
  hosts that do not pass nothing, and this package's dependency list is
  unchanged (ADR-0004).
- **The lookup this resolver needs is the bridge's to provide, and it does
  not exist yet.** The resolver's arguments are `(session_id, macrostep)`
  and not "the currently open span", because this package's subscriber is
  its own process consuming messages asynchronously: by the time it stamps a
  message, the session process may have moved on, and "current" would
  silently stamp the wrong macrostep under lag. statifier
  `docs/opentelemetry.md` already has the bridge holding per-`session_id`
  span context in an ETS table it owns, but it is keyed for the bridge's own
  link-stitching, not for a keyed `(session_id, macrostep)` read, and the
  same document notes that `macrostep` is only authoritative on a span's
  stop half. Making that lookup answerable is `opentelemetry_statifier`'s
  decision in `opentelemetry_statifier`'s repository, under this repo's
  cross-repo rule (ADR-0010, `CLAUDE.md`) - it is not built from here, and
  this record does not presume its answer.

  This format degrades correctly while that is open, which is why it is a
  dependency and not a blocker: with no answerable lookup the host supplies
  no resolver, the key is absent, and every consumer behaves exactly as it
  does today.

### Golden traces are captured with no resolver attached

Span and trace ids are random per run, so a stream carrying them is not
byte-comparable run to run and cannot be a golden. This is not a defect to
work around: the golden-trace conformance mechanism ADR-0005 names is a
statement about the *format's* determinism, and the ids are by construction
the one thing in a message that is not derived from the run.

The rule is therefore that golden captures attach no resolver, exactly as
they carry no `projection` header today, and the full-fidelity default stays
byte-unchanged. A test that wants to assert the key's shape asserts it
against a stub resolver returning fixed ids, in its own test, and never
against a golden.

## Consequences

- An operator moving between this package's inspector and an APM backend has
  a join in both directions, per macrostep, and it is present on any message
  they happen to be looking at rather than only on the stream's structure.
- The wire format spends a reserved word (`otel`) and a documented key it has
  no producer for yet. The spec is ahead of the code deliberately: the ruling
  behind this record is that reserving the shape before v1 hardens is cheap
  and doing it afterwards is not.
- The emit half is a follow-up in this repository - the `:otel_context`
  option, the stamping point in the producer, and the tests for both. Nothing
  in this record ships code.
- The bridge-side lookup is a genuine open dependency on
  `opentelemetry_statifier`, recorded above rather than assumed. If it is
  answered differently - if, say, the ids end up travelling with the effect
  stream through an upstream contract change instead of through a host
  resolver - the wire-format half of this record is unaffected: the key, its
  shape, its position, and its projection rule are decided independently of
  how the ids are obtained.
- `session.*` messages are permanently outside the correlation story, which
  is a real gap for a consumer that wants to know which trace a session died
  in. It is the honest consequence of upstream having no session-lifetime
  span, and closing it here would mean this format asserting a topology the
  engine's own bridge declines to.
- A projected stream now carries an unredacted join key into a system that
  may hold what the projection withheld. Named above, controlled by not
  attaching a resolver, and not by a projection profile.
