# ADR-0012: Trace projection and redaction

Status: proposed (2026-08-26)

Extends ADR-0005 additively: one new reserved value shape, one new
`session.start` field, and a producer-side transform. No type is added,
removed, or renamed; no existing field changes meaning. The format
version stays `1` - see "Versioning decision" below.

## Context

Wire format v1 carries real datamodel values by design. That is the right
default for the thing the format was built for: a debugger, run by the
person who owns the chart, on a run they are entitled to see in full.
`session.datamodel` names the variables, `effect.datamodel_change` carries
`new_value` and `prior_value` for every successful write, and the payload
positions carry whatever the chart put in them. `docs/wire-format.md`
states the consequence plainly - the starting snapshot plus the sequence
of writes "reconstructs the datamodel at any point in the run from the
stream alone."

The second consumer of this format is not a debugger. A multi-tenant host
embedding the engine wants to show a run's history to the end user whose
run it is - which state it is in, which transitions fired, whether it
finished or halted, in what order - and that user is not entitled to the
datamodel behind it. Neither, in general, is the host's operator console,
and neither is the host's log aggregator, which is where a persisted
stream ends up.

Today such a host has one option, and it is the bad one: consume nothing
from this repository and build an end-user run view entirely host-side,
duplicating the timeline, the identity resolution, and the rendering that
the inspector, the event log, and the datamodel explorer already do. The
reason is not that filtering is hard. It is that there is nowhere to put
it. ADR-0005 assigns subscription and filtering to "a carrier concern,"
and a carrier sits downstream of the producer: by the time a carrier could
drop a field, the value has already been rendered into a message, has
already crossed a process boundary, and may already have been persisted
by the carrier itself. A host that cannot show a value generally cannot
store one either, so a downstream filter answers the wrong question.

Two facts about this format make the design non-obvious, and both are the
reason this is a record rather than a patch.

**The absence rule is load-bearing.** ADR-0005's three-way distinction -
key absent means unbound, JSON `null` means a stored null, and no layer
of the format may collapse them - is restated at every value position in
the spec, and `effect.datamodel_change` leans on it hardest: an absent
`prior_value` means "nothing stood at the path before this write," the
common case for a first assignment. So the obvious implementation of
redaction, dropping the key, does not withhold a value. It asserts a
different one. A projected stream built that way would report a live
datamodel as permanently unbound, and every consumer folding writes over
the starting snapshot would believe it, because the result folds cleanly
and looks right. Replacing values with `null` collapses the same
distinction from the other side. Neither omission nor `null` is a neutral
projection under this format.

**The shipped consumers do not read JSON.** ADR-0005 anticipated "two
consumers of one format from day one," and that has not happened yet.
There is one integration, Kino (`StatifierUI.Kino`), and it reads
`%StatifierUI.Trace.Message{}` structs, as do `StatifierUI.Inspector`,
`StatifierUI.EventLog`, `StatifierUI.DatamodelExplorer`,
`StatifierUI.Diagram`, and `StatifierUI.EventInjection`.
`StatifierUI.Trace.Json` - the canonical byte encoder, which "deliberately
rejects nothing" - is today used in `lib/` by one module and is otherwise
a golden-test artifact. **A projection layer placed at the JSON encoder
would redact nothing the shipped inspector actually reads.** That is a
fact about the code, and it decides the placement question below on its
own.

`sui-hmn` is the implementation bead, raised to P1 on 2026-08-26. This
record is its gate: the questions below are design questions, and
answering them inside the implementation is how a projection mode ends up
meaning three slightly different things in the producer, the Kino panes,
and the LiveView components when those arrive.

## Decision

**Projection is a producer-side transform, opt-in per session, that
replaces values in a closed set of value positions with a reserved
sentinel while leaving every identity, counter, ordering, and structural
field untouched. Full fidelity remains the default and is byte-unchanged.**

### Where it applies: the message, not the bytes

**Projection is applied to `%StatifierUI.Trace.Message{}` structs, on the
`Trace.Subscriber` path, after `Trace.Normalizer` has built the message
and before it is buffered or fanned out to any listener.**

Not in the engine, which is not asked to change (`architecture.md`, "the
engine is not modified from here"). Not in `Trace.Json`, which stays a
dumb canonical encoder: the struct consumers listed in Context would
bypass it entirely, and a redaction only the golden tests can see is not
a redaction. Not in the carrier, and not in the consumers, both of which
are downstream of the value having been produced.

The message stage is the last point at which exactly one transform covers
every consumer that exists and every consumer that is planned. It is also
where `seq` is already stamped and the manifest is already emitted, so the
per-session profile has an obvious home.

The practical test this placement is chosen to pass: **a projected stream
may be buffered, rendered, encoded, written to disk, shipped to a log
aggregator, or replayed months later without any of those having held a
datamodel value.** A filter anywhere later passes the on-screen version of
that test and fails the real one.

### Redaction replaces; it never omits

**A redacted position carries the reserved one-key object
`{"$redacted": true}`.** It is never dropped, never `null`, never `{}`,
and never `{"$undefined": true}`.

This is the rule the rest of the record hangs on. Key absence, `null`, and
`$undefined` already mean specific things here, and every one of them is a
claim about what the run did. `$redacted` is the format's only encoding
for "a value was here and this stream is not carrying it," which is a
claim about the stream rather than about the run. A consumer can act on
that distinction; it cannot act on a lie.

`$redacted` joins `$date`, `$datetime`, `$duration`, and `$undefined` in
the `$`-prefixed reserved shape. The spec currently closes that set - any
other `$`-keyed one-key object is a producer-side spec violation - so this
record opens it by exactly one form and no more. It is legal wherever a
value is legal, including nested inside a list or map value.

**Versioning decision, recorded rather than left implicit.** Adding a
reserved value form is additive in the direction that matters. A v1
producer never emitted `$redacted`, so no existing stream changes and no
existing golden moves; a v1 consumer meeting one in a projected stream
renders an unfamiliar one-key map, which is conspicuous rather than
silently wrong, and the `projection` header below tells it why. Nothing a
v1 consumer previously read correctly is now read incorrectly, which is
the format's own test for a bump. **The version stays `1`.**

### What is projected: the closed set of value positions

The projection covers the positions the spec types as `value`, plus the
two named exceptions below. As of wire format v1 that set is:

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
| `effect.send`, `effect.send_delayed` | `data` |
| `session.unroutable` | every value position of the nested `effect`, recursively |
| `session.start` | `fixtures`, replaced whole |
| `session.terminated` | `reason`, replaced whole |

`session.unroutable` wraps another type's encoding under a `kind` key, so
projection must recurse into it rather than pattern-matching the outer
type. It is unreachable in the engine as shipped, which is exactly why it
is easy to forget.

`session.datamodel` keeps its keys. Variable names come from the chart,
not from the run, and the message's stated job is to name the datamodel's
variables reliably - which it still does. Its values are already
`{"$undefined": true}` at that point in the stream, since the snapshot
precedes the binding fold, so this row changes nothing observable today.
It is listed so that it cannot quietly start mattering.

`session.start`'s `fixtures` is a datamodel bundle by construction
(ADR-0003), so it is replaced whole rather than descended into. A host
that supplied no fixtures still omits the key, as today, and the two
states stay distinguishable.

**`session.terminated`'s `reason` is the one position where projection
changes a field's JSON type**, from string to the sentinel object. It
earns the exception: it is `inspect/1` of an Elixir exit reason, so a
crash inside a datamodel operation can carry datamodel terms into it
verbatim, and it is the one string field on the wire whose content is
genuinely unbounded. The spec already tells consumers it is
"human-readable, not structured data to branch on," so nothing may be
depending on its shape, and the sentinel is self-announcing where a fixed
replacement string would be indistinguishable from a real reason.

### What is never projected

Everything else, and specifically: `type`, `session`, `seq`, `macrostep`,
`microstep`, `round`; state indexes, `t_index`, `c_index`, `d_index`,
`invokeid`/`invoke_id`, `send_id`, `state_index`, `invoke_index`; every
`session.start` table (`states`, `transitions`, `contents`, `data`) and
every `location` and `value_location` object in them; configurations, exit
and entry sequences in their engine order (ADR-0011), selected `t_index`
lists, `kind` and `type` discriminators, owner and origin objects, event
`name`s, transition event descriptors, `label` on `effect.log`, `src` and
`invoke_type` on `effect.invoke`, `target` and `send_type` on the send
family, `location_path` and `location_source` on
`effect.datamodel_change`, `session.halted`'s `reason` (a closed
three-value set), and `effect.done`'s `configuration`.

That list is the bead's "structure, transitions, outcomes" made concrete,
and it is what leaves a projected stream worth rendering at all: the
timeline, the diagram highlighting, the click-through to source, and the
run's outcome are built entirely from fields in it.

`session.start`'s `data` table is already deliberately identity-only - it
carries `d_index`, `id`, `location`, and `value_location`, and no
representation of the declared value - so it needs no rule.

**On timestamps.** The bead brief asks that timestamps be preserved. Wire
format v1 carries no wall-clock field at all; ordering is `seq` plus the
`(macrostep, round)` counters, all of which projection preserves. The
requirement is met as the format stands. Whether a host-facing run history
needs a wall clock is a separate question, and this record does not open
it.

### Chart source is retained by default, and that is a real residual

`session.start`'s `source` is verbatim SCXML. It is authored rather than
run data, and it is what the whole inspector resolves indexes against, so
projection retains it by default.

The honest caveat: the `data` table's `value_location` exists so a
consumer can recover a `<data>` element's declared initial value by
slicing `source`. So retaining `source` retains **declared** initial
values, even under a profile that redacts everything else. Runtime values
are unaffected - the binding fold's results arrive as
`effect.datamodel_change` and are redacted normally - but a chart with a
literal secret in a `<data expr="...">` is not protected by projection.

Rather than special-case the slicing path, a profile may set
`allow_source: false`, which replaces `source` with the sentinel. The
cost is stated plainly: without `source`, location objects still resolve
to line and column but nothing can display the text at them, so
click-through degrades to coordinates. Hosts that keep secrets out of
chart source keep `source`; hosts that cannot, pay that cost knowingly.
Note that a consumer slicing `value_location` must compare it against the
element's own `location` first, since it falls back to that when the
element has no written value.

### Allowlist granularity: two shapes, because there are two kinds of position

Within projected mode the default is deny: every position in the table
above is redacted. A profile may allow specific values back, and the
allowlist has two parts because the format's value positions divide
cleanly in two.

**Located positions** - the datamodel - are allowlisted by **path
prefix**, written as arrays of segments in the same encoding
`effect.datamodel_change.location_path` already uses:

```
allow_paths: [["order", "status"], ["user", "tier"]]
```

A prefix matches a write when it matches the write's leading segments, so
`["order"]` allows the whole `order` subtree and `["order", "status"]`
allows one leaf. The same prefixes apply to `session.datamodel`, whose
keys are the first segment of every path. That is why the datamodel
allowlist is expressed by path and not by variable name: one expression
covers both messages, and a host that may show `order.status` but not
`order.total` can say so.

**Unlocated positions** - payloads, which have no path - are allowlisted
by naming the position, from a closed set:

```
allow_positions: [:event_data, :log_value, :send_data,
                  :invoke_params, :invoke_content, :donedata]
```

Naming a position allows it wholesale, at every message that carries it.
There is deliberately no per-key allowlist inside a payload: an event
payload has no stable schema the way a datamodel location does, so a
key-level rule there would be a guess that silently stops matching when a
chart changes - and a redaction rule that silently stops matching is the
failure this whole record exists to avoid. A host needing finer control
over a payload narrows what the chart puts in it.

A profile is a named pair of those two lists plus `allow_source`, chosen
per session at subscription. Profiles are a producer input; where a host
stores them and how it picks one per tenant is host business.

### A projected stream is distinguishable from a full one, always

**`session.start` carries a `projection` object whenever the stream is
projected**, naming the mode and the profile:

```json
{"mode": "projected", "profile": "end_user_run_history"}
```

Key absence means full fidelity, so today's streams are unchanged and
every existing golden trace is byte-identical. Adding a field is not a
version bump under the format's own MUST-ignore rule.

Distinguishability is not optional, for three reasons. A capture that
cannot say whether it is redacted cannot be filed by an operator, and the
safe assumption makes it useless. A golden-trace comparison between a
projected capture and a full golden fails for a reason that has nothing to
do with conformance, and the header is what lets a test say so. And a
datamodel pane rendering a redacted stream must show "redacted," not
"unbound" - a distinction that decides whether a user reads the chart as
broken.

Per-message self-announcement through the sentinel is kept **in addition**
to the header, not instead of it. A consumer that joined mid-stream, or a
single message pulled out of a log, still says what it is.

### Flow-through to consumers

The consumers read projected `%Message{}` structs without opting in, which
is the point of the placement. What this record still requires of them:

- Render `{"$redacted": true}` as an explicit redaction affordance -
  never as unbound, null, empty, or a literal one-key map. This reaches
  `DatamodelExplorer`, `EventLog`'s labels, and the Kino panes.
- Fold `effect.datamodel_change` over `session.datamodel` as usual. A
  fold across a redacted write yields a slot holding the sentinel; that
  is the correct answer, not an error and not a gap.
- Disable value-editing affordances when the stream is projected -
  notably the datamodel explorer's authoring-mode in-place editing
  (`architecture.md`, "the datamodel explorer's two modes"), which has no
  meaning over values it cannot see, and `EventInjection`'s payload
  composition where it is seeded from observed values.
- Surface the profile name where the mode is surfaced, so a user asking
  "why can't I see this" has something to quote.

### Default unchanged

A producer not asked to project behaves exactly as it does today: no
`projection` key, no sentinels, full values, identical bytes. The type
index's 24 rows are unchanged and the drift test that parses them is
unaffected. Projection is something a host turns on for a subscription,
one session at a time.

## Consequences

- `docs/wire-format.md` grows a "Projection" section carrying the position
  table, the allowlist shapes, and the `projection` header; `$redacted`
  joins the value-encoding section's reserved shapes and the sentence
  closing that set is amended to admit it; `session.start`'s field table
  gains one row. All additive; `version` stays `1`.
- `sui-hmn` can be implemented against this without reopening the design.
  The closed position table is the work list, the two allowlist shapes are
  the configuration surface, and `Trace.Subscriber` is the seam.
- **A projected capture is not byte-comparable to a full one.** That is
  the point, but it means golden-trace conformance (ADR-0005) does not
  transfer: a profile whose output matters is tested against its own
  golden, produced under that profile. The existing goldens stay valid
  because the default is untouched.
- **Every value position now has two producer paths**, and the standing
  drift risk is a value position added to the format later without a
  projection rule, which would carry values through a projected stream
  silently - the worst failure available here, because it is invisible.
  The mitigation is that the closed set above is defined by the spec's own
  `value`-typed rows, so the spec table is the checklist. A test asserting
  that every `value`-typed position in a projected stream is either
  allowlisted or a sentinel is the honest version of that, and it belongs
  with the type-index drift test rather than beside it.
- **Projection is not anonymization, and this record does not claim it
  is.** Structure leaks. Which branch a run took, how many rounds a
  macrostep needed, which transition fired on which event - these imply
  things about the values that produced them, and an observer with the
  chart in hand can infer a great deal from a fully redacted stream. The
  guarantee is narrow and worth stating in those terms: **no datamodel
  value crosses the producer boundary.** A host needing more than that
  needs to withhold structure, which this record does not provide.
- **Projection is not access control.** It shapes one stream. It does not
  authenticate a subscriber, does not decide which sessions a subscriber
  may see, and does not stop a host attaching a full-fidelity subscriber
  alongside a projected one. Choosing the profile correctly per tenant is
  the host's job, and this format cannot check it.
- `location_path`'s integer segments are resolved index expressions, so a
  projected stream still reveals which array index a write landed on -
  a narrow inference channel about a value the same stream redacts. It is
  retained because a consumer that cannot see the path cannot fold the
  write at all, which would cost the whole datamodel-shape view for very
  little. Recorded as an accepted residual rather than hidden.
- The reserved-shape collision ADR-0005 accepted widens by one key, and
  unlike the other four, `$redacted` is a shape a host might plausibly
  write itself while building its own redaction. Same accepted price,
  higher odds.
- No engine change and no `st-` bead. Everything here is producer-side in
  this repository, which is what ADR-0005 established when it placed the
  Elixir producer here and statifier-ex declared the wire format a
  non-goal.
- Persistence, retention, and transport are untouched. A projected stream
  is safer to store; how long a host stores it is not this format's
  business.

**Alternatives considered:**

- **Filter in the consumers** (render-time): cheapest, and what a host
  would reach for first. Rejected because it answers the wrong question -
  the value has already been produced, buffered, and possibly logged. The
  bead's requirement is that end-user run views be possible without the
  host holding the values, and only a producer-side transform delivers
  that.
- **Filter in the carrier**, extending ADR-0005's "subscription and
  filtering are a carrier concern": more plausible, since it is where
  ADR-0005 pointed. Rejected for the same boundary reason one step later,
  plus a worse one - every carrier would implement it separately and they
  would disagree, giving the format a redaction story per transport rather
  than one.
- **Project at `Trace.Json`**, the serialization boundary ADR-0005 names:
  the tidiest place on paper, and rejected on evidence. Every shipped
  consumer reads `%Message{}` structs and never passes through that
  encoder, so the redaction would be visible only to the golden tests.
  This is the alternative that would have been chosen by reading ADR-0005
  without reading `lib/`.
- **Omit redacted keys** rather than replacing them: rejected as the
  central hazard named in Context. Omission already means unbound, and a
  stream reporting a live datamodel as permanently unbound is not
  withholding information, it is producing false information.
- **Use `null` for redacted values**: collapses the same three-way
  distinction from the other side, and the spec forbids any layer
  collapsing it. Rejected.
- **A parallel `projected.*` type namespace, or version 2**: doubles the
  type set and every schema, breaks the type index's one-row-per-type
  contract and the drift test built on it, and misdescribes the thing - a
  projected stream is the same stream with values withheld, not a
  different protocol. Rejected.
- **Allowlist by message type only** ("keep `effect.log`, drop
  `effect.datamodel_change`"): far simpler, rejected as too coarse to be
  usable. The realistic host case is one or two safe datamodel fields
  alongside a dropped remainder of the same message family, which a
  type-level rule cannot express.
- **Hash or tokenize values instead of dropping them**, keeping equality
  and change-detection visible: genuinely useful for "did this field
  change" views, and rejected for now on two grounds - a stable hash is a
  correlation handle across tenants, and a low-cardinality field (a
  status, a boolean, a tier) is trivially re-identified by precomputing
  its domain. Nothing has asked for it. If something does, it is a further
  reserved value shape alongside `$redacted`, not a change to anything
  decided here.
- **Ask the engine to emit redacted effects**: rejected on
  `architecture.md`'s standing rule, and on merit - the engine's effect
  list is how the interpreter works, and a host-facing privacy policy has
  no business in it. Projection belongs at the boundary where the run
  stops being internal.
