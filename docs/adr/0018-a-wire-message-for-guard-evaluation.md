# ADR-0018: A wire message for guard evaluation

Status: accepted (2026-09-05, campaign-031; proposed 2026-09-05, campaign-031)

Adds one type to the v1 trace wire format: `trace.conds_evaluated`, the
mapping of statifier 2.5.0's `Statifier.Effect.Trace.CondsEvaluated`. It
carries a round's guard outcomes - per evaluation, which transition was
guarded, what its `cond` answered, and, when the answer was a failure, why.
No existing type is added to, removed, renamed, or reinterpreted; no field
changes its type or its meaning; **the format version stays `1`**. The
vocabulary goes from 24 types to 25. Nothing in this record ships code: the
mapping clause, the schema section, the golden and the drift-test counts
move on `sui-e41`, which is filed and blocked on this record. This record
merges at **proposed**; flipping it to accepted after `sui-e41` lands is a
separate gated change (`sui-3or`).

**Note, 2026-09-05 (campaign-031, `sui-3or`):** that separate change is the one
carrying this Note. The Status line above now reads `accepted`; `sui-e41` landed
on `main` at `ac93c18` and the 0.7.0 prep at `6beea9f`. The sentence above stands
as written and is historical: it describes the state at the recording pull
request, not the record's state today. Added by addition rather than by
rewording, so the flip removes no line but the status text.

## Context

### The gap: the engine traces guard evaluation and the format drops it

statifier 2.5.0 added a guard seam.
`Statifier.Effect.Trace.CondsEvaluated` is emitted once per selection round
in which at least one *written* `cond` was evaluated, by both
`select_transitions/2` and `select_eventless_transitions/1`
(`deps/statifier/lib/statifier/effect/trace/conds_evaluated.ex:3-14`). Its
moduledoc states why it exists in the engine at all: predicator is
deliberately telemetry-silent by its own ADR-0016, so "an evaluation that
fails, or one that quietly disables a transition a chart author expected to
fire, leaves no trace of its own anywhere in the family."

This format does not carry it. `sui-9fs`, the 0.6.1 hotfix, made the
producer **skip** it rather than refuse it:
`lib/statifier_ui/trace/normalizer.ex:130` names the closed
`@skipped_trace_effects` set, `:322` answers `:skip` for its members, and
the moduledoc's "Skipped trace effects" section (`:54-72`) records why the
set has exactly one member today - "the vocabulary has no
guard-evaluation message to map it onto, and inventing one is a wire-format
change with an ADR in front of it (`sui-e41` will add
`trace.conds_evaluated`)". That skip was the right hotfix and the wrong
resting place: before it, "a chart with a single guarded transition used to
fail the whole offline replay on its first branch"; after it, such a chart
replays, and the inspector still cannot say why a branch fired.

The two facts together are the whole context. A guarded chart is now
inspectable, and the one question a guarded chart raises - *why did this
branch fire and that one not* - is the one the stream cannot answer.

### What the effect carries, exactly

Four fields, three of them the envelope counters this format already
stamps on every `trace.*` message
(`deps/statifier/lib/statifier/effect/trace/conds_evaluated.ex:57-65`):

```elixir
@enforce_keys [:evaluations, :macrostep, :microstep, :round]
```

`evaluations` is "the ordered list of the round's guard outcomes, in walk
order - the same order `Statifier.Interpreter.Selection` raises
`error.execution` in - one entry per evaluation the round performed." Each
entry is a plain map, never a `%Statifier.Machine.Transition{}`
(`:16-17`), and its shape is the engine's own `evaluation` type (`:51-55`):

```elixir
@type evaluation :: %{
        t_index: non_neg_integer(),
        outcome: :enabled | :disabled | :error,
        reason: term() | nil
      }
```

Two absences are commitments the engine's own moduledoc makes (`:29-38`),
and this format inherits both rather than re-deriving them:

- a transition with **no** `cond` gets no entry - a `nil` `cond`
  short-circuits ahead of `Statifier.Evaluator`, so it is not an
  evaluation;
- a round that performed no evaluation emits **no effect at all**, unlike
  `Trace.TransitionsSelected`, which is emitted on every round including
  the empty one.

So a `trace.conds_evaluated` message never carries an empty `evaluations`
list, and the absence of one for a round is not the absence of information
- it means the round evaluated nothing.

### The reason term has two shapes, not one

This is the fact that decides the projection question, and it is easy to
get wrong from the type alone. `reason` is typed `term()`, but the engine
produces exactly two shapes for it
(`deps/statifier/lib/statifier/interpreter/selection.ex:317-328`):

```elixir
{:ok, other} -> {:error, {:non_boolean_cond, other}}
{:error, %Evaluator.Error{} = error} -> {:error, error}
```

The first embeds a **datamodel value** verbatim - `other` is whatever the
expression evaluated to. The second is a predicator evaluator error, which
carries the **chart text** of the `cond` and a span into it. Spec 5.9.1
joins the two into one `:error` outcome with one consequence, which is why
the engine's `outcome` has three values and not four; but on the wire the
two shapes render differently and are governed by different projection
knobs. A decision that says "the reason renders as a `class: "reason"`
object" would be wrong for half the traffic.

### Why this needs a record and not just a mapping clause

Three things move that a clause cannot decide on its own: a new type joins
a vocabulary whose size is a machine boundary (a drift test parses
`docs/wire-format.md`'s type-index table and asserts it equal to the
producer's emitted set); a new payload position has to be placed under
ADR-0012's projection contract before a producer emits it; and the
format's `version` field is a claim about consumers, settled by ADR-0005,
not by whoever writes the clause.

## Options considered

### Option A - keep skipping, and revisit at v2

Rejected. The skip is a stopgap whose own comment names its replacement,
and "revisit at v2" is a promise this format has no scheduled v2 to keep.
ADR-0005's must-ignore-unknown rule exists precisely so that a new type
does not have to wait for one.

### Option B - fold the outcomes into `trace.transitions_selected`

Rejected on two counts. It would change an accepted schema that consumers
read today, which is the format's own test for a version bump; and the two
are not co-extensive - `trace.transitions_selected` is emitted on every
round including rounds that evaluated nothing, while the guard effect is
emitted only on rounds that evaluated something. Merging them would put an
always-present field on a message where it is usually absent, and would
lose the ordering guarantee the engine states, which is per-evaluation and
not per-selected-transition.

### Option C - a new type carrying the round's outcomes (recommended)

Chosen. It is a strictly additive type, it maps the engine's payload
one-for-one so there is nothing to keep in sync, and it inherits the
envelope and the ordering guarantee unchanged.

### Option D - emit only the failures

Rejected. `disabled` is the outcome the diagnostic question is usually
about: a chart author whose branch did not fire wants to see that the
guard was evaluated and answered false, which is exactly the case an
error-only message renders as silence, indistinguishable from "the guard
was never reached". The engine already accumulates all three outcomes
under `trace: true` and allocates nothing under `trace: false`, so there
is no cost to carry to save.

## Decision

### 1. One new type, `trace.conds_evaluated`, one message per effect

The producer maps each `Statifier.Effect.Trace.CondsEvaluated` to exactly
one message. The envelope is this format's standard `trace.*` envelope -
`type`, `session`, `seq`, plus `macrostep`, `microstep`, `round` from the
effect's own stamped counters. The payload beyond the envelope is one key:

| Field | Type | Presence |
|---|---|---|
| evaluations | array of evaluation objects | always - and never empty |

Never empty is a schema commitment, not an accident: the engine emits no
effect for a round that evaluated nothing (Context above), so a message
with an empty list would describe a round that cannot exist. A consumer
may rely on it.

### 2. One entry per evaluation: `t_index`, `outcome`, and `reason` on error

| Field | Type | Presence |
|---|---|---|
| t_index | integer | always - resolves through `session.start`'s `transitions` table, like every other `t_index` in this format |
| outcome | string | always - one of `"enabled"`, `"disabled"`, `"error"`, a closed set |
| reason | error object (decision 3) | only when `outcome` is `"error"`; **absent**, never `null`, otherwise |

`outcome` is the atom's name, lowercased as written: the engine's
`:enabled`/`:disabled`/`:error` map to `"enabled"`/`"disabled"`/`"error"`.
It is a closed discriminator, in the sense ADR-0012 uses the word: a
consumer may branch on it, and a value outside the set is a producer
defect rather than something to tolerate.

`reason` uses this format's `put_present/3` rule rather than
`_event.data`'s three-way rule: the engine spells "no failure here" as a
plain `nil`, with no way to distinguish it from a genuinely null reason,
so `nil` is absence (`lib/statifier_ui/trace/normalizer.ex:38-52`). The
key's presence is therefore redundant with `outcome == "error"`, and
deliberately so - a consumer may test either.

Per outcome, in full - the form ADR-0014 decision 6 and ADR-0016 decision 3
use, so a consumer reads one row rather than assembling three claims:

| `outcome` | Engine result | `reason` | Under a projected stream |
|---|---|---|---|
| `"enabled"` | `{:ok, true}` | absent | `t_index` and `outcome` in the clear; nothing redacted |
| `"disabled"` | `{:ok, false}` | absent | `t_index` and `outcome` in the clear; nothing redacted |
| `"error"` | an evaluation error, or a non-boolean result - spec 5.9.1 joins the two | present, the object of decision 3 | `reason.reason` redacted unconditionally; `reason.expression` under `allow_source`; everything else in the clear |

**Array order is load-bearing.** The entries are in the engine's walk
order, which is the order that round raises `error.execution` events in.
A consumer joining a `trace.conds_evaluated` entry to the round's
`error.execution` events pairs the *n*th `"error"` entry with the *n*th
raised event; the engine's own moduledoc states the correspondence, and
this format restates it rather than re-deriving it. This is the same
posture ADR-0011 took for exit and entry sets: a sequence stays a
sequence.

### 3. `reason` is the ADR-0014 error object, **both** classes

`reason` is the object ADR-0014 defines - the same shape `event.error`
carries, discriminated by `class` - and **both** of its classes are
reachable here, which is what the two engine shapes in Context require:

| Engine reason term | `class` | `kind` | Other fields |
|---|---|---|---|
| `{:non_boolean_cond, value}` | `"reason"` | `"non_boolean_cond"` | `reason` (the term, `inspect/1`ed); `location`/`location_kind: "node"` when anchorable |
| `%Statifier.Evaluator.Error{}` | `"expression"` | the predicator error name | `expression`, `span`, and `location`/`location_kind` per ADR-0014's presence table |

The producer renders it through the existing
`StatifierUI.Trace.Diagnostic.reason_object/4` with the origin
`{:transition, t_index}` taken from the entry itself. That origin is not a
new one: it is the `"transition"` row of this format's origin table
(`docs/wire-format.md:906`, "the platform raised the event about a
transition's own `cond`"), and `Diagnostic.anchor/3` already has its clause
(`lib/statifier_ui/trace/diagnostic.ex:193-196`), which resolves the
transition's `cond_location` and falls back to the transition's own
`location`. No new diagnostic surface is added, and nothing about ADR-0014
is amended: this record places an existing object at a new position.

`kind` stays derived structurally from the term's shape, per ADR-0014
decision 2. This record adds no table of engine tags, and
`"non_boolean_cond"` above is what that derivation produces for the
engine's tuple today, not a mapping this record fixes.

### 4. Projection: `evaluations[].reason` projects exactly like `event.error`

The reason term is a **value position** in ADR-0012's sense: it is
`inspect/1` of a term that embeds a datamodel value verbatim. It joins the
**unconditionally redacted** set the way `error.reason` did in ADR-0014
decision 5 (`docs/adr/0014-non-value-error-reasons-on-the-wire.md:320-338`),
and for the same reason - there is no profile under which it is safe, so it
is not a `positions/0` entry, because a position is something a profile can
allow back.

Field by field, the rule is ADR-0014's rule unchanged, applied at the new
position:

| Field | Under a projected stream |
|---|---|
| reason (`class: "reason"`) | `{"$redacted": true}`, unconditionally, under every profile |
| expression (`class: "expression"`) | chart text - governed by the existing `allow_source` knob, exactly as `event.error.expression` is |
| class, kind, span, location, location_kind, content_path | never projected - closed discriminators and location data, the categories ADR-0012's "What is never projected" already covers |
| the entry's own `t_index` and `outcome` | never projected - `t_index` is an index into `session.start`'s `transitions`, `outcome` is a closed discriminator; both are already covered by ADR-0012's list |

The traversal has a precedent, and `sui-e41` should follow it rather than
invent one. `effect.budget_exhausted` already projects a position that
sits inside an **array of objects** - `data` on each
`pending_internal_events` entry, ADR-0012's table row at
`docs/adr/0012-trace-projection-and-redaction.md:267` - and it does so by
mapping the per-object projector over the list
(`lib/statifier_ui/trace/projection.ex:354-358`):

```elixir
replace_present(payload, "pending_internal_events", fn events ->
  Enum.map(events, &project_event(&1, profile))
end)
```

`trace.conds_evaluated` is the same shape one function down: map over
`evaluations` and apply the existing `project_error/2`
(`lib/statifier_ui/trace/projection.ex:436-441`) to each entry's `reason`
where present. This record fixes the rule; how the traversal is spelled is
the implementing bead's.

`trace.conds_evaluated` therefore **does not** gain a row in ADR-0012's
closed table of value positions
(`docs/adr/0012-trace-projection-and-redaction.md:252-273`). It joins the
unconditional set beside `session.terminated`'s `reason` and
`error.reason`, and this record does not amend ADR-0012 to say so - the
precedent is ADR-0014, which added `error.reason` to that set in its own
Decision 5 and left ADR-0012's text untouched. `t_index` and `outcome`
need no new rule at all: ADR-0012 already names `t_index` and `kind`/
`type` discriminators in its "What is never projected" list
(`:302-315`).

### 5. The version stays `1`, and the conformance clause still names nine

A new `type` is additive. ADR-0005 settles it in terms this record does
not reopen: consumers "must ignore unknown fields and unknown `type`s;
additive change is therefore not a version bump, and a bump means a
consumer of the old version would misread the stream"
(`docs/adr/0005-language-neutral-trace-wire-format.md:215-218`). Nothing a
v1 consumer previously read correctly is now read incorrectly - a consumer
that has never heard of `trace.conds_evaluated` skips it, which is the
behaviour the rule requires of it. **The version stays `1`.**

This is settled precedent in this format, not a fresh argument.
`effect.datamodel_change` joined after v1 had already shipped with 23
types, and `docs/wire-format.md:890-895` records the same conclusion in
the same terms - "unlike `session.datamodel`, which kept version 1
because its type string was already reserved, this one keeps it because
new types never bump the version at all." ADR-0014 decision 7 reached it
once more for a widened field. This record follows both and does not
reopen the question.

The conformance clause is the half that is easy to get wrong, so this
record decides it explicitly. `docs/wire-format.md:20` says a conformant
producer MUST emit "the nine `trace.*` types at the phase boundaries
Appendix D names". `trace.conds_evaluated` is **not** one of them: it is
not an Appendix D phase boundary, it is a seam inside selection, and it is
emitted only when a round evaluated a written `cond`. It joins the **MAY**
half of the conformance clause (`:23-25`), beside the `effect.*` families.
The MUST list stays nine; `sui-e41` may reword the clause so that "nine"
reads unambiguously as the Appendix-D nine rather than as a count of all
`trace.*` types, and must not add a tenth MUST.

### 6. The vocabulary goes 24 -> 25, and that count is a machine boundary

`StatifierUI.Trace.Normalizer.types/0` returns 25 sorted strings after
`sui-e41`, and `docs/wire-format.md`'s type index carries 25 rows - 10
`trace.*`, 10 `effect.*`, 5 `session.*`. The drift test parses that
table's backtick-quoted type strings and asserts them equal to the
producer's emitted set
(`test/statifier_ui/trace/wire_format_spec_test.exs:9-34`), so the table
and the producer move together or the test fails, which is the point.

The count appears in more places than the bead's file map names, and every
one of them is `sui-e41`'s to move. They are not interchangeable:

| Site | Today | After `sui-e41` |
|---|---|---|
| `lib/statifier_ui/trace/normalizer.ex:132-157` (`@types`) | 24 entries | 25 entries |
| `test/statifier_ui/trace/normalizer_test.exs:718-721` | "exactly 24", `length(types) == 24` | 25 |
| `docs/wire-format.md:1387-1388` (type index) | "24 rows: 9 `trace.*`, 10 `effect.*`, and 5 `session.*`" | 25 rows: 10 `trace.*` |
| `docs/wire-format.md:533` (schemas heading) | "The nine `trace.*` schemas" | ten |
| `docs/wire-format.md:20` (conformance MUST) | "the nine `trace.*` types at the phase boundaries Appendix D names" | **still nine** - decision 5 |
| `docs/wire-format.md:9` and `:1425` | "ADR-0005 settled ... the nine `trace.*` type names" | **still nine** - these describe what ADR-0005 settled, which this record does not change |

## Implementation

`sui-e41` implements this record; this record ships no code. Its shape,
stated here only so the record's claims are checkable against it:

- `lib/statifier_ui/trace/normalizer.ex` - the `:skip` clause at `:322`
  becomes a `trace_message/2` clause, and `@types` gains the string.
  `@skipped_trace_effects` at `:130` loses its only member; whether the
  constant stays declared-and-empty or retires with its moduledoc section
  is `sui-e41`'s call. Either way the fallthrough that refuses an
  *unknown* trace effect stays, and stays untouched.
- `lib/statifier_ui/trace/projection.ex` - a `project_payload/3` clause
  for the new type, mapping the existing `project_error/2` over
  `evaluations`.
- `lib/statifier_ui/trace/subscriber.ex` and the replay path need **no**
  change beyond the vocabulary count: both already have a `:skip` arm
  beside their `{:ok, _}` arm (`lib/statifier_ui/trace/subscriber.ex:535`,
  `lib/statifier_ui/trace/replay.ex:276`), so an effect that used to answer
  `:skip` now takes the `{:ok, _}` path every other trace effect takes.
- `docs/wire-format.md` - a schema section for the type, its type-index
  row, and the count sites in decision 6's table.
- A golden over a chart with a guarded transition, round-tripping through
  `StatifierUI.Trace.Json`, so the message's bytes are proved by a live
  session and not only by a struct literal.
- A `changelog.d` fragment, on `sui-e41`. This record takes none: a
  decision record is not a user-visible change.

A chart that exercises it, in the campaign's signup-wizard-with-A/B-testing
domain: a `<transition event="continue" cond="variant == 'b'">` beside a
`<transition event="continue">` fallback. The first round after `continue`
evaluates one written `cond` and emits one entry - `outcome: "enabled"` for
the visitor in variant B, `"disabled"` for the visitor in variant A - which
is precisely the difference an inspector today renders as two identical
streams.

### Note 2026-09-05 (sui-51o): two Implementation claims that went stale

*A note, not an amendment. Nothing above or below it has been edited and
this record's Status line has not been changed - it is still `proposed`,
and it flips only by its own gated pull request (`sui-3or`), after the
0.7.0 prep. This note annotates two of the descriptive bullets in the
section above; it touches no numbered decision, and every decision 1-6
landed as written.*

**Note, 2026-09-05 (campaign-031, `sui-3or`):** that gated pull request has
landed, and the Status line now reads `accepted`. The paragraph above stands as
written and is historical: it describes the state at the recording pull request.
Its two substantive claims are unaffected by the flip - nothing above or below
the `sui-51o` note was edited by it, and every numbered decision 1-6 was
re-verified against `main` before this flip.

`sui-e41` implemented this record on `main` at `ac93c18` (PR 126). Two
statements in this section describe the implementation rather than decide
it, and both went stale when it landed. They are recorded here rather than
edited away, because what the record predicted and what the gate permitted
are two different facts and the second is the interesting one.

**The `:skip` arm did not stay: the mechanism retired end to end.** The
third bullet above says `lib/statifier_ui/trace/subscriber.ex` and the
replay path need no change beyond the vocabulary count, because each
already carries a `:skip` arm beside its `{:ok, _}` arm. Under this
repository's gate that shape was not writable. With the guard-evaluation
effect mapped onto a `trace_message/2` clause, `@skipped_trace_effects` had
no members left, and the empty form does not survive the gate: a guard over
an empty list warns that its clause cannot match and an unused module
attribute warns on its own, both fatal under `warnings_as_errors`; and with
no clause producing `:skip`, dialyzer reported each caller's `:skip` arm as
a pattern that can never match. So the delegated choice this section leaves
open - "whether the constant stays declared-and-empty or retires with its
moduledoc section" - resolved to **retire**, and the answer retired with
its last member. `:skip` is out of `normalize/2`'s spec
(`lib/statifier_ui/trace/normalizer.ex:188`) and out of both callers, each
of which now carries a comment where its arm was, recording that a future
skipped effect reinstates the answer together with the clause that produces
it (`lib/statifier_ui/trace/replay.ex:272-275`,
`lib/statifier_ui/trace/subscriber.ex:529-534`); the module's own "The
retired third answer" section (`normalizer.ex:54-77`) states the same. What
this section and the Consequences promise either way is intact: the
fallthrough that refuses an *unknown* trace effect is untouched, and is now
the only half of the pair with members
(`normalizer.ex:255-256` and `:323-324`, `{:error, {:unknown_effect, _}}`).

**Two vocabulary-count sites decision 6's table does not list.** Both
became false at 25 types, and `sui-e41` moved them:
`lib/statifier_ui/trace/replay.ex:128-129`, "nine of the format's
twenty-four types" -> "ten of the format's twenty-five types"; and
`docs/wire-format.md:790`, whose "`trace.*` are the nine Appendix D phase
boundaries" was reworded to name the tenth rather than to raise the count -
"the nine Appendix D phase boundaries plus `trace.conds_evaluated`, the
guard seam inside selection" - which is decision 5's distinction restated
in prose, nine boundaries and ten types, not an amendment to it.
(`lib/statifier_ui/trace/projection.ex:31` also moved, sixteen key paths to
seventeen. It counts the key paths projection touches rather than the
format's types, so it is outside decision 6's subject and is named here
only so the search is not repeated.)

## Consequences

- The inspector can answer "why did this branch fire" from a persisted
  stream, live or offline (ADR-0017's producer emits the same vocabulary,
  so it gains the type for free).
- The `@skipped_trace_effects` set empties. That is a small loss: the
  mechanism `sui-9fs` built - a closed, named set of deliberately uncarried
  trace effects, distinct from the fallthrough that refuses unknown ones -
  is worth keeping even with no members, and `sui-e41` decides whether to
  keep the constant empty or retire it with its moduledoc section. Either
  way the *refusal* path for an unconsidered effect stays.
- A projected stream over a guarded chart shows `outcome` and `t_index` in
  the clear and `{"$redacted": true}` where a reason would be. A host
  reading only projected streams therefore learns *that* a guard failed and
  on which transition, and not what value it failed on. That is the
  intended trade and it is the same one `error.reason` already makes.
- A `class: "expression"` reason carries the `cond`'s text, so a host that
  withholds chart source withholds this too, through `allow_source` and
  with no new knob. A host that allows source sees the failing expression,
  which is the point of that knob.
- Consumers pinned to the 24-type vocabulary are unaffected at runtime by
  the must-ignore rule, but a consumer that *asserts* the count - the first
  production embedder carries such a pin - fails until it is re-pinned. The
  pin is outside this repository and outside this campaign; it moves on the
  embedder's own bead after `statifier_ui` 0.7.0 publishes.

## Notes

This record merges at **proposed**. `sui-e41` implements it; `sui-3or`
flips it to accepted afterwards, as a separate change through the same
gate, once every claim above has been checked against the code that
landed. That ordering is this repository's convention for a record that
decides a wire-format shape before the shape exists: ADR-0016 and ADR-0017
each merged at proposed and were flipped in a later, separately gated
change (`9942e1f` then `9592f0e`; `0f3c083` then `35a388a`).

**Note, 2026-09-05 (campaign-031, `sui-3or`):** the flip landed in the pull
request that carries this Note, and the Status line above reads `accepted`. The
paragraph above stands as written and is historical. The check it asks for was
performed against `main` at `6beea9f`: every numbered decision 1-6 holds as
written, and the two Implementation bullets that did not are the ones the
`sui-51o` note above already records.

The two engine facts this record leans on hardest - that no entry exists
for a `cond`-less transition, and that no message exists for a round that
evaluated nothing - are the engine's commitments, not this format's. If a
future statifier changes either, this format's "never empty" schema
commitment in decision 1 is what breaks, and it breaks loudly, in the
golden. That is the intended failure mode.

### Note 2026-09-06 (`sui-u30`): cite errata, and what the empty form warns

*A note, not an amendment. Nothing above it has been edited: no numbered
decision, no sentence, and not the Status line. It repoints locators that
slid under later commits, records the ones this pull request itself moved,
and corrects one description of a compiler warning. The `sui-51o` and
`sui-3or` notes above stand as written.*

**Five cites that slid.** The prose citing them is unchanged and still
correct; only the line numbers moved, under `sui-e41` (`ac93c18`, which
took `docs/wire-format.md` from 1458 lines to 1518) and `sui-if3`
(`41b26ed`, which added to `lib/statifier_ui/trace/replay.ex` after the
`sui-51o` note merged).

| Cited above as | Resolves today at | The cited text |
|---|---|---|
| `docs/wire-format.md:906`, decision 3, the origin table's `"transition"` row | `docs/wire-format.md:964` | "the platform raised the event about a transition's own `cond`" |
| `docs/wire-format.md:890-895`, decision 5, the versioning precedent | `docs/wire-format.md:948-953` | "unlike `session.datamodel`, which kept version 1 because its type string was already reserved" |
| `docs/wire-format.md:1425`, decision 6's table, the "still nine" row | `docs/wire-format.md:1485` | "envelope, the nine `trace.*` type names, the `session.start` role" |
| `lib/statifier_ui/trace/replay.ex:272-275`, the `sui-51o` note | `lib/statifier_ui/trace/replay.ex:345-348` | the four-line comment standing where the `:skip` arm was |
| `lib/statifier_ui/trace/replay.ex:128-129`, the `sui-51o` note | `lib/statifier_ui/trace/replay.ex:167-168` | "ten of the format's twenty-five types missing, silently" |

The companion locator in that same table row, `docs/wire-format.md:9`,
still resolves, and so does the conformance-MUST row's
`docs/wire-format.md:20`.

**Four cites this pull request moved itself.** The moduledoc correction
below adds three lines to `lib/statifier_ui/trace/normalizer.ex` above
every locator the `sui-51o` note takes into that file, so each moves down
by three. As merged:

| Cited above as | Resolves at | The cited text |
|---|---|---|
| `normalizer.ex:54-77` | `normalizer.ex:54-80` | the "The retired third answer" moduledoc section |
| `normalizer.ex:188` | `normalizer.ex:191` | `normalize/2`'s `@spec`, without `:skip` |
| `normalizer.ex:255-256` | `normalizer.ex:258-259` | the two `decompose/2` fallthroughs |
| `normalizer.ex:323-324` | `normalizer.ex:326-327` | the `trace_message/2` fallthrough |

**What the empty form actually warns.** The `sui-51o` note above says "a
guard over an empty list warns that its clause cannot match and an unused
module attribute warns on its own, both fatal under `warnings_as_errors`",
and `normalizer.ex`'s own section said the same. Both halves are real
warnings and the conclusion - retire - is unaffected, but the description
is wrong twice, and a reader reproducing it would not see what it
describes.

The two warnings are alternatives, not a pair, and neither is a warning
about the guard. Keeping the empty constant *and* its clause
(`when module in @skipped_trace_effects` over `[]`) expands the guard to
`false`, so the pattern's own binding goes unread, and Elixir 1.18.3
answers with an unused-*variable* warning naming `module`, not a
cannot-match warning naming the clause. Dropping the clause and keeping
the constant is the other arm, and is where the unused-attribute warning
comes from. Each was reproduced under this repository's toolchain (Elixir
1.18.3, Erlang/OTP 27) on the two-clause shape `sui-e41` replaced. The
moduledoc section in `lib/statifier_ui/trace/normalizer.ex` is corrected
to say this, in the same pull request as this note; the note above is
left as written, as a note.

**Cites deliberately not repointed.** The Implementation section's
locators into `normalizer.ex` (`:130`, `:132-157`, `:322`), its two
`:skip`-arm locators (`lib/statifier_ui/trace/subscriber.ex:535` and
`lib/statifier_ui/trace/replay.ex:276`, the arms the `sui-51o` note above
records as gone), and the "Today" column of decision 6's table all
describe the code as it stood *before* `sui-e41` landed. They are
historical by construction - the `sui-51o` note is what records that they
went stale - and repointing them at today's lines would make them name
text they do not describe.

Every other `path:line` in this record was machine-checked against `main`
at `7c14f79` as amended by this pull request, and resolves to the text it
is cited for. Two resolve loosely rather than exactly: decision 4's
`lib/statifier_ui/trace/projection.ex:354-358` and `:436-441` each open on
a blank line and carry the clause they cite one line further down. That is
a wrapping artefact, not a slide, and is recorded here rather than
repointed.
