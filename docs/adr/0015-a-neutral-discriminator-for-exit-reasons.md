# ADR-0015: A neutral discriminator beside `session.terminated`'s reason

Status: proposed (2026-09-02, campaign-027)

Extends ADR-0005 additively: `session.terminated` gains one optional field,
`kind`, carrying a language-neutral token for the exit reason's class. The
existing `reason` field is unchanged - same key, same `inspect/1` string,
same "human-readable, do not branch on it" contract. No message type is
added, removed, or renamed; no existing field changes its value or its
meaning; the format version stays `1`. Nothing in this record ships code.

## Context

### The producer, exactly

`StatifierUI.Trace.Subscriber.handle_down/2`
(`lib/statifier_ui/trace/subscriber.ex:593-608`) is the only site that
builds a `session.terminated` message. It is hand-built rather than
normalized - the message does not come from an engine effect, it comes from
the monitor this subscriber established at
`lib/statifier_ui/trace/subscriber.ex:404` - and its whole payload is one
line:

```elixir
payload: %{"reason" => inspect(reason)}
```

`lib/statifier_ui/trace/subscriber.ex:598`. `reason` is whatever term OTP
put in the `:DOWN` message, and `inspect/1` is applied to it unconditionally.

The observed output, from the manual verification of `sui-t36.3` that filed
this bead:

```
Process.exit(pid, :kill)      -> {"reason": ":killed", ...}
Process.exit(pid, :shutdown)  -> {"reason": ":shutdown", ...}
exit reason {:bad, 1}         -> {"reason": "{:bad, 1}", ...}
```

A leading colon and Elixir tuple syntax, on a wire ADR-0005 calls
language-neutral.

### The neighbour that does it differently

`session.halted` sits beside it in the same stream and is produced by
`StatifierUI.Trace.Normalizer.normalize/2`
(`lib/statifier_ui/trace/normalizer.ex:152-153`):

```elixir
def normalize({:halted, reason}, ctx) when reason in [:done, :cancelled, :budget_exhausted] do
  build(ctx, "session.halted", nil, nil, nil, %{"reason" => Atom.to_string(reason)})
end
```

The guard is the closed set, the type says so
(`lib/statifier_ui/trace/normalizer.ex:97`), and `Atom.to_string/1` rather
than `inspect/1` is what keeps the colon off the wire. The documented
presence rule is `always - one of "done", "cancelled", "budget_exhausted"`
(`docs/wire-format.md:940`).

`session.terminated`'s row, eight lines below it, is
`always - inspect/1 of the Elixir exit reason`
(`docs/wire-format.md:956`), followed by the paragraph that makes the
current behaviour deliberate rather than accidental
(`docs/wire-format.md:958-960`):

> `reason` is a human-readable string, not structured data to branch on -
> an Elixir process exit reason has no language-neutral shape, so this
> document does not attempt to give it one.

**The critique in this bead is consistency, not correctness.** The document
is not wrong about an *arbitrary* exit reason. It over-applies that truth to
the reasons that actually occur, which are mostly a small conventional set.

### The projection position

`session.terminated`'s `reason` is the one field on the whole wire whose
JSON type changes under projection: it becomes `{"$redacted": true}`
(`lib/statifier_ui/trace/projection.ex:393-399`,
`docs/wire-format.md:962-967`, ADR-0012 at
`docs/adr/0012-trace-projection-and-redaction.md:289-297`, position table
row at `:270` and at `docs/wire-format.md:1054`). It earns that because
`inspect/1` of a crash reason can carry datamodel terms verbatim.

`session.halted`'s `reason` is in the opposite set - never projected,
"a closed three-value set"
(`lib/statifier_ui/trace/projection.ex:91`). The two `reason` fields are
already treated as different kinds of thing by the projection layer. That
asymmetry is a fact this record has to preserve, not one it may quietly
collapse.

### What the consumers do with it today

- `StatifierUI.EventLog.Markdown.footer_line/1` has two clauses for this
  message (`lib/statifier_ui/event_log/markdown.ex:147-154`): a sentinel
  clause guarded on `is_map(reason)`, because interpolating the redaction
  map raises, and a string clause. Both print the field verbatim.
- `StatifierUI.Live`'s `effect_summary/1`
  (`lib/statifier_ui/live.ex:534-536`) renders it through
  `payload_suffix(payload, ["reason"])`, which names the keys it wants.

Neither branches on the string's shape, which is what the document asked
for. Neither can say anything about *what kind* of exit it was, which is
what this bead is about.

### No schema stands in the way of a new key

`StatifierUI.Trace.Message.validate/1` rejects exactly one thing: a payload
key that collides with the envelope's reserved set,
`type session seq macrostep microstep round otel`
(`lib/statifier_ui/trace/message.ex:48`). `kind` is not among them, and it
is already used as a payload key elsewhere in the format -
`session.unroutable` wraps another type's encoding under a `kind` key
(`docs/wire-format.md:1056-1058`), and the event `error` object uses `kind`
for the same discriminating job.

### What an exit reason actually looks like

An OTP `:DOWN` reason is `term()` and genuinely unconstrained. The classes
below are what a subscriber sees in practice, and each one is reachable
through this producer:

| Term | How it arises | Reachable here |
|---|---|---|
| `:normal` | the session process returns | yes |
| `:shutdown` | a supervisor shuts the session down | yes |
| `{:shutdown, term}` | a supervised shutdown carrying a payload | yes |
| `:killed` | `Process.exit(pid, :kill)` | yes - observed in the bead |
| `:noproc` | the monitor at `subscriber.ex:404` is established on a pid that is already dead | yes |
| `{exception, stacktrace}` | any raise inside the session - the standard OTP crash shape | yes |
| a tagged tuple (`{:bad, 1}`) | an application `exit/1` | yes - observed in the bead |
| a bare atom, string, number, pid, list | any other `exit/1` | yes |

Two things fall out, and both constrain the decision.

1. **The set is conventional, not closed.** `:normal`, `:shutdown`,
   `:killed`, and `:noproc` are OTP conventions; nothing prevents a term.
   Unlike `session.halted`'s three values, no guard can enumerate this.
2. **A reason can embed a datamodel value.** `{:shutdown, term}` and the
   `{exception, stacktrace}` crash shape both can. That is the whole basis
   of the projection exception above, and any decision here must leave it
   standing.

### The two sibling decisions this one is next to

- **`sui-4lr` / ADR-0014**, merged to `main` as `2071776` at Status
  **proposed**. It decides the wire shape for a non-value `error.*` reason:
  a `class` discriminator, a structurally derived `kind` token, and an
  `inspect/1` `reason` string beside it, with `reason` unconditionally
  redacted. It names this bead explicitly and states the coupling: "if
  `sui-2s4` decides `inspect/1` output must be normalized or tagged as
  opaque on the wire, the same treatment applies to this field". **Answering
  it consistently is a requirement on this record, not a nicety**, and the
  consistency statement is decision 7 below.
- **`sui-v8o`** asks whether `session.start`'s `value_location` should omit
  its fallback. It is the other open additive wire change; it is listed so
  the three do not drift, and it is not decided here.

## Options considered

All three are compatible with ADR-0005's must-ignore rule
(`docs/adr/0005-language-neutral-trace-wire-format.md:55-56, 215-218`), so
none of them is a version bump. The choice is made on what a consumer can do
with the result, and on which of them is genuinely *additive*.

### Option A - map the closed common set in place

Keep one `reason` field and change what it contains: `:normal` becomes
`"normal"`, `:killed` becomes `"killed"`, `{:shutdown, term}` becomes
`"shutdown"`, and anything else keeps `inspect/1`. This is the shape the
bead proposes first.

For: the field a consumer already reads becomes neutral for the
overwhelmingly common cases, with no new key, and `session.halted`'s style
is matched exactly.

Against, and decisive on two counts.

First, **it is not purely additive, and the record should say so plainly**.
ADR-0005's rule is about *adding* fields and types: a consumer must ignore
what it does not know, so new keys are free
(`docs/adr/0005-language-neutral-trace-wire-format.md:217-218`). It says
nothing that makes a *changed value under an existing key* free, and the
document's own test for a bump - "nothing a v1 consumer previously read
correctly is now read incorrectly" (`docs/wire-format.md:996-998`, and the
same wording at `:188`) - is not obviously passed: a consumer displaying
`":killed"` in a run history begins displaying `"killed"`. The
saving grace is narrow and worth naming rather than leaning on: the field's
*documented* contract is human-readable text nobody may branch on
(`docs/wire-format.md:958-960`), so a conforming consumer cannot have been
depending on the exact string. The change is therefore permissible under the
field's contract but is a value change, not an addition, and it is the only
option here that has to argue the point at all.

Second, **it fails the bead's third acceptance criterion**. With one field,
a consumer distinguishes a mapped reason from an `inspect/1` fallback only
by sniffing for a leading colon or a brace - exactly the string-sniffing the
bead asks to remove. The bead itself anticipates this ("if the fallback
stays, consider distinguishing the two cases on the wire").

### Option B - a neutral `kind` beside the unchanged `reason` (recommended)

Add one field. `kind` carries the language-neutral token; `reason` keeps
`inspect/1` and its existing contract as the human overflow.

For: it is purely additive in the strict sense - every existing message
stays byte-identical, every existing assertion and consumer keeps passing,
and the projection position table does not move. It gives the branchable
token the bead wants *and* keeps the full detail an operator debugging a
crash actually needs (`{:bad, 1}` says which tag; `"unknown"` alone does
not). And it is the same shape ADR-0014 chose for the same problem one
message over, so the format gains one idiom rather than two.

Against: the message now carries two fields where one would do, and a naive
consumer that renders every payload key shows both. That is the cost of
keeping `reason` byte-identical, and it is small: `session.terminated` is a
terminal, once-per-session message.

### Option C - leave it as documented

For: the document already explains itself, the behaviour is deliberate, and
no wire moves.

Against, and decisive: it concedes the bead's point without acting on it. A
consumer that wants to distinguish a clean stop from a kill - the single
most common question asked of this message - has no way to do it except by
parsing Elixir syntax, in a format whose premise is that no consumer should
have to know Elixir. It also leaves the format internally inconsistent in
the way ADR-0014 has now made conspicuous: the `error` object gets a neutral
`kind`, and the exit reason does not.

## Decision

### 1. One additive `kind`, and `reason` untouched

`session.terminated` carries a `kind` string alongside its existing
`reason`:

```json
{"type": "session.terminated", "session": "sess_1", "seq": 41,
 "kind": "killed", "reason": ":killed"}
```

```json
{"type": "session.terminated", "session": "sess_1", "seq": 41,
 "kind": "unknown", "reason": "{%RuntimeError{message: \"boom\"}, []}"}
```

| Field | Type | Presence |
|---|---|---|
| kind | string | always - a lowercase token for the reason's class, or `"unknown"` |
| reason | string | always - unchanged; `inspect/1` of the Elixir exit reason |

`kind` is unconditionally present. Absence-means-unknown would keep the
common message one key shorter and is rejected for the reason ADR-0014
rejected the same spelling: a discriminator a consumer infers from a key's
absence is the string-sniffing this bead exists to remove, one level up.

### 2. `kind` is derived structurally, by ADR-0014's rule verbatim

| Term shape | `kind` |
|---|---|
| a bare atom | `Atom.to_string(atom)` - `"normal"`, `"shutdown"`, `"killed"`, `"noproc"` |
| `{tag, ...}` where `tag` is an atom | `Atom.to_string(tag)` - `"shutdown"` for `{:shutdown, term}` |
| anything else (a bare string, a number, a pid, a list, `{exception, stacktrace}`) | `"unknown"` |

This is the same derivation ADR-0014 decision 2 specifies for the `error`
object's `kind`, deliberately identical so that a consumer learns one rule.
Derivation rather than a curated table is the point twice over: an exit
reason is `term()` with no closed set to enumerate (Context, fact 1), and
`Atom.to_string/1` on the tag is precisely what `session.halted` already
does at `normalizer.ex:153`.

`kind` stays lowercase snake_case, which for an Elixir atom tag it already
is.

**The named residual: the OTP crash shape lands in `"unknown"`.** A raise
inside the session exits with `{exception, stacktrace}`, whose first element
is a struct rather than an atom, so the rule above yields `"unknown"` for
the single most informative failure a run can have. That is accepted here
rather than special-cased, because the alternative is a shape rule about
Elixir exception structs living in a language-neutral format, and because
the loss is bounded - `reason` still carries the full `inspect/1`, and a
later `"crashed"` classification can be added additively without reopening
anything decided here. It is called out because it is the row a reader will
otherwise assume was overlooked.

### 3. `reason` keeps `inspect/1` and keeps its warning

`reason` is unchanged in value, presence, and contract. The paragraph at
`docs/wire-format.md:958-960` stays true as written and stays in place: the
field is human-readable text, not structured data to branch on.

What changes is that the paragraph stops being the *only* thing the message
says. Today "do not branch on this" leaves a consumer with nothing to branch
on at all; under this record it means "branch on `kind`, read `reason`".

This is the answer to ADR-0014's open coupling, and it is a "no" to
normalizing `inspect/1` output itself: the fix is a neutral field beside it,
not a neutered field in place of it.

### 4. Projection: `kind` is never projected, `reason` stays redacted

`kind` joins the never-projected discriminators listed in
`StatifierUI.Trace.Projection`'s moduledoc
(`lib/statifier_ui/trace/projection.ex:88-104`), beside `session.halted`'s
`reason` and the `error` object's `kind`. It is derived from an atom tag
alone and never from a term the tag wraps, so `{:shutdown, secret_value}`
projects as `kind: "shutdown"` with no part of `secret_value` reachable
through it.

`reason` keeps its existing unconditional redaction, unchanged:
`project_payload("session.terminated", ...)` at
`lib/statifier_ui/trace/projection.ex:393-399` continues to replace it whole
with `{"$redacted": true}`. It is not a new position in `positions/0` and
the ADR-0012 table row (`docs/wire-format.md:1054`,
`docs/adr/0012-trace-projection-and-redaction.md:270`) does not move.

The consequence is the useful one: **a projected stream gains information it
does not have today.** A host projecting a run history can say the session
was killed rather than stopping cleanly, which is a legitimate thing for the
end user whose run it is to know, without seeing a byte of the reason term.

### 5. Per variant, in full

Before is what the wire carries today; after is what it carries under this
record. `reason` is identical in both columns by construction - that is
decision 3 - so the before column is stated once as the `reason` value.

| Exit reason term | `reason` (before and after) | `kind` (after) | Projected `kind` |
|---|---|---|---|
| `:normal` | `":normal"` | `"normal"` | `"normal"` |
| `:shutdown` | `":shutdown"` | `"shutdown"` | `"shutdown"` |
| `{:shutdown, :restart}` | `"{:shutdown, :restart}"` | `"shutdown"` | `"shutdown"` |
| `{:shutdown, %{token: "s3cret"}}` | `"{:shutdown, %{token: \"s3cret\"}}"` | `"shutdown"` | `"shutdown"` |
| `:killed` | `":killed"` | `"killed"` | `"killed"` |
| `:noproc` | `":noproc"` | `"noproc"` | `"noproc"` |
| `{:bad, 1}` | `"{:bad, 1}"` | `"bad"` | `"bad"` |
| `{%RuntimeError{message: "boom"}, []}` | `"{%RuntimeError{message: \"boom\"}, []}"` | `"unknown"` | `"unknown"` |
| `"a string"` | `"\"a string\""` | `"unknown"` | `"unknown"` |
| `42` | `"42"` | `"unknown"` | `"unknown"` |

Under a projected stream every `reason` cell in the middle column becomes
`{"$redacted": true}`, exactly as it does today. The fourth column is the
new information a projected consumer gains, and the `{:shutdown, %{token:
...}}` row is the one that proves the derivation is safe: the tag survives
projection, the payload does not.

The bead's third acceptance criterion is met by the `"unknown"` token rather
than by string inspection: a consumer asking "is this a reason I recognise?"
reads one key and compares it to tokens it knows, and never parses
`reason` at all.

`kind` is not unique across the format - `session.unroutable`'s `kind`
carries a message type, and the `error` object's carries an error name. It
is scoped by the message type it appears on, as those two already are.

### 6. The format version stays `1`

Adding a field is not a bump
(`docs/adr/0005-language-neutral-trace-wire-format.md:55-56, 215-218`), the
same reading ADR-0013 applied for `otel` and ADR-0014 applied for `class`. A
v1 consumer that does not know `kind` ignores it and reads `reason` exactly
as it does today - byte for byte, which is the property Option A could not
offer.

### 7. Consistency with ADR-0014, stated

ADR-0014 asked this record a question and this record answers it. The two
are consistent, in this shape:

| | ADR-0014 (`error` object) | ADR-0015 (`session.terminated`) |
|---|---|---|
| neutral token | `kind`, always present | `kind`, always present |
| how derived | atom tag, else `"unknown"` | atom tag, else `"unknown"` - identical |
| human overflow | `reason`, `inspect/1` | `reason`, `inspect/1` - and unchanged |
| "do not branch" wording | adopted from `session.terminated` | kept where it already is |
| projection of the overflow | new unconditional redaction | existing unconditional redaction, unmoved |
| projection of the token | never projected | never projected |
| second discriminator | `class`, because one object serves two payload shapes | none - this message has one shape |

**There is no divergence to declare.** ADR-0014 kept `inspect/1` as a
fallback field on the explicit condition that a neutral token sit beside it,
and cited this bead's third acceptance criterion as the shape it was
satisfying. This record adopts that same split for the field ADR-0014 took
the precedent from, which closes the loop rather than opening one. The only
asymmetry is `class`, and it is absent here because it is not needed: the
`error` object describes either an expression failure or a reason term,
while `session.terminated` describes exactly one thing.

## Golden-fixture impact

None, and checked rather than assumed.

- The repository has one golden trace,
  `test/support/trace/two_state.jsonl`. It contains **zero**
  `session.terminated` messages - the fixture's session stops cleanly and is
  never monitored to death - so **no golden bytes move**. That is the same
  fact that made ADR-0014's explicit discriminator cheap, verified
  independently here.
- The assertions that move are unit-level and all of them *gain* rather than
  change: `test/statifier_ui/trace/projection_test.exs:457-459` (which
  projects `%{"reason" => ":normal"}` and asserts the sentinel) keeps
  passing untouched and gains a `kind`-survives-projection case;
  `test/statifier_ui/trace/projection_drift_test.exs:139` keeps passing;
  `test/statifier_ui/trace/subscriber_test.exs:264-281`, which kills a
  session and reads the reason back, gains a `kind == "killed"` assertion;
  `test/statifier_ui/trace/projection_consumers_test.exs:139-170` gains the
  projected-token case.
- Under Option A those same assertions would have had to change rather than
  extend, which is the practical face of the additive argument in decision 6.

## Implementation

Deliberately not filed. **An implementing bead is filed on acceptance**,
after the operator flips this record's Status, and it covers, together in
one change:

- the `kind` derivation and the payload map at
  `lib/statifier_ui/trace/subscriber.ex:593-608`;
- the never-projected note in `StatifierUI.Trace.Projection`'s moduledoc
  (`lib/statifier_ui/trace/projection.ex:88-104`) - `project_payload/3` at
  `:393-399` needs no change, which is the point;
- the `session.terminated` field table and prose at
  `docs/wire-format.md:949-967`;
- whether `StatifierUI.Live`'s `effect_summary/1`
  (`lib/statifier_ui/live.ex:534-536`) and
  `StatifierUI.EventLog.Markdown.footer_line/1`
  (`lib/statifier_ui/event_log/markdown.ex:147-154`) should surface `kind` -
  a rendering call, not a format one, and the reason the two are named here
  rather than left to be found;
- the unit assertions listed under "Golden-fixture impact".

`docs/wire-format.md` is deliberately untouched by this record: it documents
what the producer does, and until the implementing bead lands the producer
emits `reason` alone.

## Consequences

- A consumer can tell a clean stop from a kill, a supervisor shutdown, or a
  crash without knowing that a leading colon means anything. That is the
  bead's whole ask, and it is the first time this message says anything a
  non-Elixir consumer can act on.
- A projected stream carries strictly more than it does today: `kind`
  survives projection where the reason string never will. The end-user run
  history gains an outcome it could not previously be told.
- The wire keeps a field that is explicitly not machine-readable, in a
  format whose premise is language neutrality. That was already true; this
  record declines to fix it and bounds it instead, which is the same trade
  ADR-0014 made and is now made twice on purpose rather than once by
  accident.
- The `{exception, stacktrace}` crash shape reports `kind: "unknown"`. The
  most interesting failure gets the least specific token, and only `reason`
  distinguishes it - which under projection is redacted, so a projected
  consumer sees a crash and an application `exit("boom")` identically. This
  is the record's weakest point and it is recorded as such.
- `kind` is spent as a payload key on `session.terminated`. It is not
  reserved at the envelope level (`lib/statifier_ui/trace/message.ex:48` is
  unchanged) and it is now the third distinct meaning `kind` carries in this
  format, after `session.unroutable`'s message type and the `error` object's
  error name.
- The producer takes on a small amount of structural derivation - one tag
  extraction - in a subscriber that otherwise passes terms through. Bounded
  to this message and named here so it is not read as licence to reflect
  over other terms.
- `session.terminated` and `session.halted` still answer different
  questions and still differ under projection (`halted`'s reason is
  never projected, `terminated`'s is always redacted). This record narrows
  the gap in vocabulary without collapsing a distinction ADR-0012 depends
  on.

## Notes

- 2026-09-02 (campaign-027, `sui-2s4`): recorded at Status **proposed**. The
  flip to accepted is the operator's, and follows as its own docs-only
  change. No code, no `docs/wire-format.md` edit, and no implementing bead
  accompany this record; all three follow the flip.
- **`sui-2s4`'s first acceptance criterion selects Option A, and this record
  recommends against it.** The bead was written in 2026-08 as an
  implementation bead, and its criterion "`:normal`, `:shutdown`,
  `{:shutdown, term}` and `:killed` emit bare lowercase reason strings
  matching `session.halted`'s style" describes Option A: the bare token
  replaces `reason`'s value. Decision 1 puts the bare token in `kind` and
  leaves `reason` alone instead, which satisfies the bead's *second* and
  *third* criteria more cleanly and satisfies the first only in substance -
  the bare lowercase string exists on the wire, under a different key. The
  divergence is deliberate, it is argued under Option A above, and it is
  flagged here rather than buried so that flipping this record's Status is
  understood as also re-scoping the bead's first criterion.
- **A named alternative the operator may prefer over decision 2**: derive
  `kind` from a curated allowlist of conventional OTP reasons (`normal`,
  `shutdown`, `killed`, `noproc`, `timeout`) and emit `"other"` for every
  tag outside it, so `kind` distinguishes a *recognised* exit from a merely
  *shaped* one - today `{:bad, 1}` yields `"bad"`, which reads as a known
  reason and is not. It is not recommended, because the list is a second
  vocabulary to maintain against a set OTP never actually closed, and
  because it discards a tag an operator can use; it is recorded because it
  is a live reading of the bead's third acceptance criterion and the choice
  is the operator's.
- Line numbers in this record were resolved against `statifier-ui`
  `2071776`, the commit that merged `sui-4lr` / ADR-0014 and the commit this
  branch is cut from. ADR-0014 was already on `main` when this branch was
  created, so its README index row is inherited rather than merged around.
