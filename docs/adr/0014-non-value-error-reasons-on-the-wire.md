# ADR-0014: Non-value error reasons on the wire

Status: proposed (2026-09-02, campaign-027)

Extends ADR-0005 additively: the existing event `error` object gains a
discriminator and two optional fields, and becomes reachable for a class of
failure that is currently dropped rather than rendered. No message type is
added, removed, or renamed; no existing field changes meaning; the format
version stays `1`. Nothing in this record ships code.

## Context

### The defect, exactly

`Statifier.Interpreter.Content.raise_execution_error/4` is the single site
in the engine that names an `error.*` event for executable content, and both
of its clauses put an arbitrary term in the event's `data`:

- statifier `lib/statifier/interpreter/content.ex:283-293` - the
  ADR-0047/ADR-0048 send-rejection clause. It matches
  `{:send_rejected, send_id, kind, reason}`, destructures to
  `data: reason, sendid: send_id`, and maps `kind` to the event name through
  `error_name/1` (`:306-307`), which is the only place `error.communication`
  is produced at all.
- statifier `lib/statifier/interpreter/content.ex:295-299` - the general
  clause, `data: reason`, raising `error.execution`.

`reason` is `term()` in the `@spec` (`:265-270`) and is genuinely
unconstrained in practice.

On this side, `StatifierUI.Trace.Normalizer.put_event_data/3` has exactly
two clauses:

- `lib/statifier_ui/trace/normalizer.ex:465` - the
  `%Statifier.Evaluator.Error{}` clause `sui-czr` added, which routes the
  struct to `StatifierUI.Trace.Diagnostic.object/4`
  (`lib/statifier_ui/trace/diagnostic.ex:62`) and puts the result on the
  event's `"error"` key instead of its `"data"` key.
- `lib/statifier_ui/trace/normalizer.ex:477` - everything else,
  `put_defined(base, "data", ev.data)`, which encodes through
  `StatifierUI.Value.encode/1`.

`Value.encode/1` is closed over predicator's value domain and rejects
everything outside it: `lib/statifier_ui/value.ex:159` for a struct that is
not `Date` or `DateTime`, `lib/statifier_ui/value.ex:188` for a bare atom,
tuple, pid, reference, port, or function - both returning
`{:error, {:unsupported_value, term}}`.

That error is not contained to the field. `StatifierUI.Trace.Subscriber`
treats a normalize failure as a **dropped message**:
`lib/statifier_ui/trace/subscriber.ex:527` routes it to
`record_normalize_error/3`, which logs once per distinct reason (`:546`) and
increments an error counter. The message never reaches the buffer and never
reaches a consumer. An `error.execution` whose reason is
`{:not_iterable, 42}` therefore does not render badly - it does not render
at all, and the inspector shows a run in which the error simply is not
there.

`sui-czr` (merged as sui PR #66) closed one arm of that and recorded the
rest as an open question. This record is that question's bead, `sui-4lr`.

### What a reason actually looks like

Not hypothetical. The terms below are every reason the engine as shipped
puts in `data`, read from statifier 2.0.0 - the version this repository's
`mix.lock` pins, readable under `deps/statifier/`, and with these line
numbers unchanged on statifier `main` as of 2026-09-02.

| Reason term | Site | What the payload carries |
|---|---|---|
| `%Statifier.Evaluator.Error{}` | `if.ex:154` (a branch `cond` that failed to evaluate, drained through `pending_errors`) | chart text - already handled by `sui-czr` |
| `{:non_boolean_cond, other}` | `if.ex:152` | `other` is a **datamodel value** |
| `{:system_variable, name}` | `foreach.ex:158` | chart vocabulary |
| `{:illegal_index_name, index}` | `foreach.ex:166` | chart vocabulary |
| `{:not_iterable, value}` | `foreach.ex:188` | `value` is a **datamodel value** |
| `{:invalid_delay, other}` | `send.ex:293` | `other` is a **datamodel value** |
| `{:unsupported_type, type}`, `{:invalid_target, target}` | `send.ex:248,251` | the inner reason of an `:execution` send rejection |
| `{:unreachable_target, target}` | `send.ex:254` | the inner reason of the one `:communication` rejection |
| `{:nested_content, c_index, reason}` | `if.ex:176,179`, `foreach.ex:335,338` | recursive; the innermost `reason` may itself be an `%Evaluator.Error{}` |

Four things fall out of that list, and each one constrains the decision.

1. **A reason is a tagged tuple, almost always.** No bare atom reaches
   `data` from the engine as shipped. A bare atom is nonetheless reachable
   in principle - `reason` is `term()`, `foreach.ex:154-160` takes its
   `illegal_reason` from the caller, and this format is meant to serve
   producers other than this one (ADR-0005) - so the vocabulary needs an
   answer for it rather than an assumption about it.

2. **A reason frequently embeds a datamodel value.** `{:not_iterable, value}`
   carries the value that was not iterable, verbatim. That makes this an
   ADR-0012 question and not only an ADR-0005 one, and it is the reason the
   projection rule below is not an afterthought: today no datamodel value
   escapes through this path *because the whole message is dropped*.
   Un-dropping it without a projection rule would put a hole in ADR-0012's
   one stated guarantee ("no datamodel value crosses the producer
   boundary", `lib/statifier_ui/trace/projection.ex:111`).

3. **`{:nested_content, _, _}` re-opens the arm `sui-czr` closed.** A node
   that fails with an `%Evaluator.Error{}` *inside* an `<if>` partition or a
   `<foreach>` body is wrapped by `if.ex:179` / `foreach.ex:338` before it
   reaches `data`. The struct is then a tuple element rather than the
   `data` term, `normalizer.ex:465` does not match, and the message is
   dropped exactly as it was before `sui-czr`. The expression-diagnostic
   arm is therefore only fixed for failures at the top of a block. Any
   answer here that treats the wrapper as opaque leaves that half broken.

4. **`error.communication` is not a distinct payload shape.** It differs
   from `error.execution` in exactly one way: which of `error_name/1`'s two
   strings the event's `name` carries. The `data` term is produced by the
   same destructuring in the same clause. Nothing in the reason vocabulary
   can be conditioned on the event name, and the per-variant table below
   says so by having identical rows.

### Two sibling decisions this one is next to

Both are open in this repository and both are recorded here so the three do
not drift apart. Neither is decided by this record.

- **`sui-2s4`** asks whether `session.terminated`'s `reason` should stop
  being bare `inspect/1` output (`docs/wire-format.md:956-960`), on the
  grounds that it is the one place a leading colon and Elixir tuple syntax
  reach a wire ADR-0005 calls language-neutral. This record adopts that same
  `inspect/1` precedent for a *fallback* field, deliberately, and the
  interaction is discussed under "The `inspect/1` question" below.
- **`sui-v8o`** asks whether `session.start`'s `value_location` should omit
  its fallback. It is listed only because it is the other open additive wire
  change: if both land, the golden capture is re-taken once rather than
  twice.

## Options considered

Three shapes were on the table. All three are additive under ADR-0005 and
none of them is a version bump, so the choice is made on what a consumer
has to do with the result rather than on compatibility.

### Option A - the same `error` object, discriminated (recommended)

The reason renders as the event's existing `error` object, discriminated so
a consumer can tell an expression failure from a reason term, with a
neutral `kind` token and an `inspect/1` string beside it.

For: there is exactly one wire shape and one renderer path for "this event
is an error", which is what a reader of the timeline actually wants to
know; the object `sui-czr` shipped is reused rather than shadowed; the
event object's `data`/`error` alternation (`docs/wire-format.md:547-548`)
stays a two-way choice rather than a three-way one; and `kind` gives the
branchable token that `reason` deliberately is not.

Against: `kind` now means two different vocabularies depending on `class`,
and the object's presence rules become conditional (`expression` is no
longer unconditionally present). Both are the cost of one object doing two
jobs, and both are paid explicitly by the `class` key rather than left for
a consumer to infer.

### Option B - a sibling key beside `data` and `error`

A third top-level key on the event object - `"reason"` - used when the data
is neither a value nor an evaluator error.

For: it changes nothing that exists. Every current object stays
byte-identical, presence rules stay unconditional, and the producer clause
is trivial.

Against, and decisive: it makes the event object's payload a three-way
alternation with no discriminator at all, so every consumer that wants to
ask "did this event fail?" checks two keys instead of one, forever, and a
fourth failure class later makes it three. It also splits the rendering
path for one user-visible thing, which is how the `sui-czr` defect stayed
invisible: the drop was silent because nothing downstream was looking for
the case at all.

### Option C - a typed sub-object per reason class

A schema per engine tag - `{"not_iterable": {"value": ...}}`,
`{"system_variable": {"name": "_x"}}` - so every reason is structured data.

For: it is the only option that makes a reason fully machine-readable, with
no `inspect/1` anywhere, which is the outcome ADR-0005's language-neutral
premise would ideally want.

Against, and decisive: the vocabulary is not this repository's to enumerate.
The tags belong to statifier, they arrive with statifier ADRs (ADR-0047 and
ADR-0048 added three between them), and this repository does not modify the
engine and does not track its internals field by field (`CLAUDE.md`,
ADR-0002). A schema table here would be stale on the next upstream ADR, and
a producer meeting an unknown tag would need a fallback - which is Option A,
reached through a table that has to be maintained to stay wrong less often.
Option C is also not foreclosed: a tag that earns structure can gain typed
fields on the same object later, additively, without reopening this record.

## Decision

### 1. One widened `error` object, discriminated by `class`

A non-value reason renders as the event's `error` object, the same key
`sui-czr` shipped, with a `class` discriminator saying which of the two
things the object describes:

```json
{"type": "trace.event_dequeued", "session": "sess_1", "seq": 12,
 "macrostep": 2, "microstep": 0, "round": 1,
 "event": {"name": "error.execution", "type": "platform",
           "error": {"class": "reason",
                     "kind": "not_iterable",
                     "reason": "{:not_iterable, 42}"}}}
```

and the object `sui-czr` already produces gains `"class": "expression"`:

```json
{"error": {"class": "expression", "kind": "undefined_variable",
           "expression": "amount < limit",
           "span": {"start_line": 1, "start_column": 1,
                    "end_line": 1, "end_column": 7},
           "location": {"start_line": 4, "start_column": 22,
                        "end_line": 4, "end_column": 28},
           "location_kind": "resolved"}}
```

Presence, by class:

| Field | `class: "expression"` | `class: "reason"` |
|---|---|---|
| class | always - `"expression"` | always - `"reason"` |
| kind | always - the predicator error name (unchanged) | always - the reason's tag, or `"unknown"` |
| expression | always | never |
| span | only when the evaluator error carries one | never |
| location | only when the producer could anchor | only when the producer could anchor |
| location_kind | only alongside `location` | only alongside `location` |
| reason | never | always |
| content_path | only when the failure was wrapped | only when the failure was wrapped |

`class` is explicit on both arms rather than absent-means-expression. The
asymmetric spelling would keep every existing object byte-identical, which
is worth something, and it is rejected anyway: a discriminator a consumer
has to infer from a key's absence is the same defect `sui-2s4` names when it
asks for a way to tell a known reason from an opaque one "without
string-sniffing". The cost of being explicit is near zero here, for a
reason stated under "Golden-fixture impact" below.

### 2. `kind` carries the branchable part, and it is derived structurally

`kind` is the object's language-neutral discriminator and stays a lowercase
snake_case token in both classes. For `class: "reason"` it is derived from
the term's shape, not from a table this repository maintains:

| Term shape | `kind` |
|---|---|
| `{tag, ...}` where `tag` is an atom | `Atom.to_string(tag)` - `"not_iterable"`, `"system_variable"`, `"invalid_target"` |
| a bare atom | `Atom.to_string(atom)` |
| anything else (a bare string, a number, a pid, a list) | `"unknown"` |

Derivation rather than enumeration is the point. The tags belong to
statifier, they are added by statifier ADRs - ADR-0047 and ADR-0048 added
three between them - and this repository does not modify the engine
(`CLAUDE.md`, ADR-0002). A table here would be stale on the next upstream
ADR and would give a producer nothing to do when it met an unknown tag.

`kind` is not unique across classes: a hypothetical engine tag `:parse`
would collide with the predicator error name `"parse"`. `class` is what
disambiguates, which is a second reason it is explicit rather than inferred.

### 3. `reason` is human-readable, and the format says not to branch on it

`reason` is `inspect/1` of the whole reason term, present on every
`class: "reason"` object and on no other. It exists so an operator can see
*which* value was not iterable, which `kind` alone cannot say.

It is documented, in `docs/wire-format.md` and here, as human-readable text
rather than structured data to branch on - the same wording
`session.terminated`'s `reason` already carries
(`docs/wire-format.md:958-960`).

**The `inspect/1` question.** This does put Elixir syntax on a wire ADR-0005
calls language-neutral, and `sui-2s4` is open about exactly that trade for
`session.terminated`. Three things make it the right call here and not a
contradiction:

- The branchable content is not in this field. `session.terminated`'s
  `reason` is that message's only field, so a consumer that cannot branch on
  it cannot branch at all. Here `kind` carries a neutral token for every
  variant, and `reason` is the human overflow beside it. That split is the
  shape `sui-2s4`'s third acceptance criterion asks for, so this record is
  evidence for that bead's direction rather than a precedent against it.
- The term is genuinely open. `reason` is `term()` and can nest arbitrary
  datamodel values; there is no neutral encoding of an arbitrary Elixir term
  that is not just a worse `inspect/1`. `Value.encode/1` already declines to
  invent one (`lib/statifier_ui/value.ex:31-38`), and that refusal is the
  behaviour this record is working around, not one it should quietly
  reverse.
- If `sui-2s4` decides `inspect/1` output must be normalized or tagged as
  opaque on the wire, the same treatment applies to this field without
  reopening anything decided above: `class`, `kind`, the position, and the
  projection rule are all independent of how `reason`'s string is produced.
  The coupling is recorded so the two fields move together.

### 4. `{:nested_content, _, _}` is peeled, and the chain is kept

The producer unwraps `{:nested_content, c_index, inner}` repeatedly,
collecting each `c_index` in order into an optional `content_path` array of
integers, and then classifies the innermost term by the rules above. A
wrapped `%Evaluator.Error{}` therefore renders as
`class: "expression"` with its span and location intact, plus a
`content_path`; a wrapped tuple renders as `class: "reason"` for the
innermost tag, plus a `content_path`.

`content_path` is absent when nothing was wrapped, per the format's absence
rule. Its integers are `c_index` values, which is a `session.start` identity
table index and therefore already part of this format's vocabulary and
already never projected
(`lib/statifier_ui/trace/projection.ex:79-92`).

Treating the wrapper as opaque - `kind: "nested_content"` and the whole term
in `reason` - was the simpler option and is rejected on fact 3 above: it
would leave every expression failure inside an `<if>` or `<foreach>`
rendering as an opaque string, which is the defect `sui-czr` was filed to
fix, re-created one level down and harder to notice.

### 5. `reason` is redacted under every projection profile

`error.reason` is added to ADR-0012's unconditionally-redacted set, beside
`session.terminated`'s `reason`
(`lib/statifier_ui/trace/projection.ex:393-399`): under any projected stream
it carries `{"$redacted": true}` instead of a string. It is not governed by
`allow_source`, because it is not chart text, and it is not a new
projection position, because there is no profile under which it is safe -
`inspect/1` of `{:not_iterable, value}` embeds a datamodel value verbatim.

`class`, `kind`, and `content_path` join the never-projected discriminators
already listed for this object (`lib/statifier_ui/trace/projection.ex:99-104`).
They are engine and chart vocabulary and derive from no datamodel value.

This is the half of the implementation that must not be skipped. Today the
projection guarantee holds for these messages only because they are dropped
before projection ever sees them. `lib/statifier_ui/trace/projection.ex:422-423`
(`project_error/2`) is the exact function that has to move in the same
commit as `normalizer.ex:477`.

### 6. Per variant, in full

The two event names and the four term classes, with no row conditioned on
the name - fact 4 above:

| Event | `data` term | Today | Under this record |
|---|---|---|---|
| `error.execution` | `%Evaluator.Error{}` | renders as the error object (`sui-czr`) | unchanged, plus `"class": "expression"` |
| `error.execution` | bare atom (e.g. `:no_route`) | message dropped | `class: "reason"`, `kind` = the atom, `reason` = `":no_route"` |
| `error.execution` | tagged tuple (`{:not_iterable, 42}`) | message dropped | `class: "reason"`, `kind: "not_iterable"`, `reason` = `inspect/1` |
| `error.execution` | other term (bare string, list, pid) | message dropped | `class: "reason"`, `kind: "unknown"`, `reason` = `inspect/1` |
| `error.execution` | `{:nested_content, c, inner}` | message dropped | peeled; classified as `inner`, plus `content_path: [c, ...]` |
| `error.communication` | `%Evaluator.Error{}` | renders as the error object (`sui-czr`) | unchanged, plus `"class": "expression"` |
| `error.communication` | bare atom | message dropped | as `error.execution` above |
| `error.communication` | tagged tuple (`{:unreachable_target, t}`) | message dropped | `class: "reason"`, `kind: "unreachable_target"`, `reason` = `inspect/1` |
| `error.communication` | other term | message dropped | as `error.execution` above |
| `error.communication` | `{:nested_content, c, inner}` | message dropped | as `error.execution` above; unreachable today (see below) |

Two notes on reachability, so the table is not read as a claim about what
the engine emits. First, `error.communication` is produced only by the
`{:send_rejected, _, :communication, reason}` clause, whose inner `reason`
is `{:unreachable_target, target}` and nothing else as shipped - the other
`error.communication` rows are what the format promises a future or
non-Elixir producer, not observed traffic. Second, the send-rejection clause
is reachable from the fatal arm only, so no `{:send_rejected, _, _, _}` is
ever wrapped in `{:nested_content, _, _}` by the drain path; the wrapped
`error.communication` row exists because `if.ex:179` wraps a fatal `<send>`
failure inside an `<if>` partition, which is the same term arriving through
a different route.

The rows are identical across the two event names by construction, and that
identity is the decision: a consumer branches on `class` and `kind`, never
on which `error.*` event carried them.

### 7. The format version stays `1`

Adding fields is not a version bump under ADR-0005's MUST-ignore rules
(`docs/adr/0005-language-neutral-trace-wire-format.md:55-56, 215-218`), the
same reading applied by ADR-0013 for `otel` and before it by `round` on the
remaining `effect.*` envelopes. A v1 consumer that does not know `class`
ignores it and reads the expression object exactly as it does today.

The one behaviour that changes for an existing consumer is that messages it
never received now arrive. That is the defect being fixed, not a
compatibility break: a consumer's handling of an `error.execution` it never
saw cannot have been correct.

## Golden-fixture impact

Smaller than it looks, and checked rather than assumed.

- The repository has one golden trace, `test/support/trace/two_state.jsonl`.
  It contains no `error` object at all - `grep -c error` on it returns 0 -
  so adding `class` to the expression arm moves **no golden bytes**. This is
  the fact that makes the explicit discriminator cheap enough to prefer over
  the absent-means-expression spelling.
- The assertions that do move are unit-level: the error-object tests in
  `test/statifier_ui/trace/normalizer_test.exs` and
  `test/statifier_ui/trace/projection_test.exs` gain `class` and gain
  coverage for the new arm. Those are ordinary test edits, not a re-capture.
- A golden that exercises the new arm should be added by the implementing
  work, and it is deterministic: unlike ADR-0013's `otel` ids, every field
  here derives from the run. A `<foreach>` over a non-iterable is the
  cheapest fixture that produces one.
- If `sui-v8o` also lands, it moves `session.start` in the same golden.
  Sequencing the two so the capture is taken once is a scheduling note, not
  a dependency.

## Implementation

Deliberately not filed. **An implementing bead is filed on acceptance**,
after the operator flips this record's Status, and it covers, together in
one change: the third `put_event_data/3` clause in
`lib/statifier_ui/trace/normalizer.ex`, the `class`/`reason`/`content_path`
fields in `StatifierUI.Trace.Diagnostic`, the redaction of `reason` in
`project_error/2`, the `docs/wire-format.md` error-object table
(`:548`, `:556`), and a golden exercising the reason arm.

`docs/wire-format.md` is deliberately untouched by this record: it documents
what the producer does, and until the implementing bead lands the producer
drops these messages.

## Consequences

- An `error.execution` or `error.communication` carrying a non-value reason
  reaches a consumer at all, which it does not today. The inspector stops
  silently omitting a class of failure, and the subscriber's normalize-error
  counter stops being the only evidence that it happened.
- The expression-diagnostic arm `sui-czr` shipped becomes correct for
  failures nested inside an `<if>` or `<foreach>`, which it is not today.
  That was not this bead's stated scope; it is a consequence of decision 4
  and it is the larger of the two fixes by reachability.
- The wire gains a field (`reason`) that is explicitly not machine-readable,
  in a format whose whole premise is language neutrality. It is the second
  such field, it is bounded by a neutral `kind` beside it, and it is coupled
  to `sui-2s4` so the two are decided consistently rather than separately.
- `error.reason` is a new unconditional redaction, so a projected stream
  carries `{"$redacted": true}` where a full-fidelity stream carries the
  operator's most useful diagnostic. A host that projects gets `kind` and
  `content_path` and nothing else about the failure. That is the correct
  trade under ADR-0012 and it is a real loss of diagnostic value for
  projected audiences.
- The producer takes on a small amount of structural derivation it did not
  have - tag extraction and wrapper peeling - in a component library that
  otherwise renders what the engine hands it. Bounded to this object, and
  named here so it is not read as licence to reflect over other terms.
- `class` is spent as a field name inside the error object. It is not
  reserved at the message's top level and does not join `type`, `session`,
  `seq`, `macrostep`, `microstep`, `round`, and `otel` in that set.

## Notes

- 2026-09-02 (campaign-027, `sui-4lr`): recorded at Status **proposed**. The
  flip to accepted is the operator's, and follows as its own docs-only
  change. Line numbers in this record were resolved against
  `statifier-ui` `662a6f6` and statifier 2.0.0 as vendored under
  `deps/statifier/`; the statifier lines were confirmed unchanged against
  the statifier working checkout at `7057e0e`.
