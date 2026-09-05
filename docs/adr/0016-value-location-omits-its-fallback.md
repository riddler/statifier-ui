# ADR-0016: `value_location` omits its element-span fallback

Status: proposed (2026-09-02, campaign-027)

Amendment status: **proposed** (2026-09-05, sui-4so: Decision 2 re-argued
against an always-present span cell, after `8119f19` falsified the "not a
schema change" limb) - see "Amendment proposed" below; the record's text
outside that section is unchanged, apart from one added item in the
Implementation list.

Narrows one field of `session.start`'s `data` table: `value_location` is
emitted only when it spans a value the author actually wrote, and is
key-absent otherwise, instead of falling back to the `<data>` element's own
span. No message type is added, removed, or renamed; no field changes its
type or its meaning where it is present; the format version stays `1`.
Nothing in this record ships code - the producer, `docs/wire-format.md`, and
`manifest_test.exs` move on a separate implementing bead filed on acceptance.

## Amendment proposed 2026-09-05 (sui-4so): Decision 2 re-argued against an always-present span cell

*Proposed 2026-09-05. Nothing in the record above or below has been
rewritten. This amendment makes two insertions outside its own section,
named here rather than left for a reader to find: the amendment status line
in the header, and item 6 of the Implementation list. No line of the record
is edited or removed, and the record's own Status line is untouched.*

**The fact that moved.** This record merged at `9942e1f` (2026-09-02
08:31 -0600). Three and a half hours later, `8119f19` (`sui-o4e`, the
payload-schema drift test) rewrote the presence cell for `value_location`
in `docs/wire-format.md`. It had read *"present only when the compiler
recorded a span for the element's value"*. It now reads, and reads on
`main` today at `docs/wire-format.md:398`, *"always - the written value's
span when the element wrote `expr` or `src`, the element's own span
otherwise; see below"*. That commit's message calls the conditional cell
stale and says the table *"now says always"*.

Two passages of the record are stated against the old cell: the Context
bullet under "What the format already says" (*"Conditional, in the
published schema, since the table existed"*) and, load-bearingly, the
second limb of Decision 2. Read the Context bullet as a statement true on
this record's own date. Decision 2 is re-argued below, and the
re-argument - not the paragraph it replaces - is what a flip to `accepted`
blesses.

### 1. The "not a schema change" limb is retracted

Decision 2's second bold claim, *"It is also not a schema change"*, is
false today, and so is the reasoning under it. The published schema now
calls `value_location` always-present. Under Option B the producer stops
emitting it on the child-content and bare variants, so the change removes a
key the schema promises. That is a schema change: a narrowing of a
published presence contract.

The direction of travel in that paragraph inverts with it. The record
argued that the producer was converging on a schema which already described
Option B. Since `8119f19` it is the schema that has converged on the
producer, and Option B now has to move both together - the cell and the
producer in one commit. That is what Implementation item 2 already provides
for, and what item 6 below makes enforceable rather than intended.

The record's supporting cite moved in the same direction.
`test/statifier_ui/trace/manifest_test.exs:419-431` still passes, because
the key still is on every row, but the reason it gives for its own
existence - *"The wire-format schema still documents the field as
conditional, so this asserts the observed behavior without binding the
format to it"* (`:423-424`) - is no longer true. Implementation item 3
already replaces that test with its converse; it must replace that
reasoning too rather than carry it across.

### 2. The version still stays `1`, argued on the bump test directly

Two things stay separated here, and the retracted limb is not one of them.

**A schema change is not by itself a version bump.** ADR-0005's rule
(`docs/adr/0005-language-neutral-trace-wire-format.md:215-222`) does not
test for schema motion. It says consumers must ignore unknown fields and
unknown `type`s, concludes that *additive* change is therefore not a bump,
and then states the test itself: *"a bump means a consumer of the old
version would misread the stream"*. Additivity is a named exemption from
having to argue that test. Everything else - this change included - argues
it directly. The record's first limb said exactly that, and it survives
unchanged.

**Would a consumer of the old version misread the stream?** No, and the
answer no longer depends on what the schema said. Take the consumer the
retracted limb could not reach: one written against today's cell, reading
`value_location` unconditionally because the document promises it. After
Option B it finds the key absent on the child-content and bare rows. In
every binding of this format an absent key is a distinguishable outcome -
`nil`, `undefined`, a missing-key error - and not a plausible wrong value.
That consumer stops, or renders nothing, at the row where its assumption
broke, with the field name in hand.

What that same consumer does *today* is the misread. It slices `source` at
a span equal to `location` and presents the whole `<data id="x"/>` element
as the element's declared value, with nothing anywhere reporting a problem.
ADR-0005's test asks which of the two is a misreading of the stream, and
the answer is the present behaviour rather than the change.

**The honest cost of the exchange.** The retracted limb claimed that no
schema-conformant consumer was affected at all. This one concedes that
every schema-conformant consumer is affected, and defends the change on the
*character* of the failure rather than on its absence. That is a real
narrowing of the argument: version `1` is now a judgement that a loud,
localized failure is not a misreading, and no longer a deduction from a
schema that already said so. The judgement is the thing being accepted. If
the operator does not take it - if a promised key going missing counts as
misreading - the honest consequence is a version bump to `2`, not a quieter
version of Option B.

**O-3 gets sharper, and stays open.** No out-of-repo consumer of the v1
wire is known; the format still has one producer and one consumer set, both
in this repository and both reading the compiled struct rather than the
wire. But since `8119f19` an out-of-repo consumer written against the
document is *entitled* to read the key unconditionally, where before the
document told it not to. If one appears before the implementing bead lands,
this judgement is re-argued rather than assumed.

### 3. The doc cell is load-bearing now, and a test enforces it both ways

`8119f19` also added
`test/statifier_ui/trace/wire_format_payload_schema_test.exs`, which parses
the presence column out of `docs/wire-format.md` and checks it against
messages the producer actually builds. A field whose cell says `always`
must be on every sample row (`:110-119`); a field whose cell is conditional
must be observed both present *and* absent (`:121-137`), so a conditional
cell that has quietly gone unconditional fails rather than passing
vacuously.

Three consequences for the implementing bead, none of which this record
could have known:

- Implementing Option B without restating `:398` fails the `always` test on
  the first bare or child-content row. Implementation item 2 was written as
  documentation hygiene; it is a hard dependency of item 1, in the same
  commit.
- Restating `:398` conditionally without implementing Option B fails the
  conditional test, which needs an absent observation the producer would
  never supply. The two edits cannot be split in either order.
- The restated cell has to begin with a spelling the parser classifies:
  `presence/1` (`:274-283`) accepts a cell starting `always`,
  `present only when`, or `omitted`, and `flunk`s anything else as
  unclassifiable.

The test's samples do **not** have to move. `@rich` (`:39-55`) already
declares `<data>` three ways - `expr`, bare, and child content - so under
Option B the `expr` row supplies the present observation and the other two
supply the absent one, both arms out of one sample. That is a correction to
the falsification analysis noted on `sui-3u6`, which expected the samples to
move with the cell.

### 4. What was re-verified, and two corrections

Every other cite in this record resolves on `main` at `2d5ca4d`
(2026-09-05): the four `build_data_value/2` clauses and the two
`data_*_location/1` helpers upstream;
`docs/adr/0005-language-neutral-trace-wire-format.md:215-222`;
`manifest_test.exs:345`, `:376` and `:419`, each starting exactly where
cited; `test/support/trace/two_state.jsonl` carrying `"data":[]` with zero
`value_location` occurrences; `lib/statifier_ui/trace/diagnostic.ex` and
`lib/statifier_ui/datamodel_explorer/scope.ex` reading the struct with a
nil-or-equal branch; `docs/wire-format.md:413-427`'s fallback note and
`:423-426`'s `cond_location` contrast; `mix.lock:29` pinning statifier
2.0.0. Nothing in that set moved, and the projection position argued in
Decision 4 is unaffected by anything in this amendment: `value_location`
remains a structural position, and a removed structural key still creates
no value position.

**The projection cite is three lines short, and the amendment does not
reach far enough to fix it in place.** The Context bullet on the
projection position cites
`docs/adr/0012-trace-projection-and-redaction.md:305` and `:320`. The
first is right - `:304-315` is the never-projected list, and `data` with
its `location` and `value_location` objects sits inside it at `:307-308`.
The second is not: `:320` is the tail of the following sentence, and the
`data` row's four fields are named at `:322-324`. The claim holds; only
the line number is wrong, so this is recorded here rather than repaired
in the bullet, which this amendment does not edit.

**The off-by-one reported against the producer does not reproduce.** The
falsification analysis on `sui-3u6` placed `data_object/1` at
`lib/statifier_ui/trace/manifest.ex:235-242` with `put_present` at
`:241`. On `2d5ca4d` the function is at `:234-241` with `put_present` at
`:240`, exactly as the record's Context bullet cites it. That correction
belongs to the analysis, not to the record: the record's line numbers are
right and need no amendment.

### 5. Decision 2, as amended

The recommendation is unchanged: Option B, format version `1`. The
supporting argument is now these two limbs and only these:

1. The change is **not additive**, so ADR-0005's must-ignore exemption does
   not reach it. Unchanged from the record.
2. The change **is a schema change**, and it is still not a version bump,
   because ADR-0005's bump test is about misreading rather than about
   schema motion, and a promised key going missing fails loudly at the row
   where it is missing while the present behaviour renders a wrong value
   silently.

Limb 2 replaces the record's *"It is also not a schema change"* paragraph
and the version-stays-`1` paragraph that rested on it. Decisions 1, 3, 4
and 5 are unaffected: none of them cites the presence cell, and the
per-variant table in Decision 3 describes the producer rather than the
document.

This pull request merges at `proposed`; a separate pull request flips this
amendment's status, and the record's own Status line, to `accepted` once
the operator has taken the judgement in limb 2 above.

## Context

### The producer, exactly

`session.start`'s `data` table is built in this repository, one row per
compiled `<data>` element:

- `lib/statifier_ui/trace/manifest.ex:234-241` - `data_object/1`. It writes
  `d_index`, `id`, and `location` unconditionally, then
  `put_present("value_location", location_object_or_nil(element.value_location))`
  at `:240`. The `put_present/3` call is the only conditional arm, and it
  fires on a `nil` `value_location`.

`element.value_location` comes off the compiled `Statifier.Machine.Data`
struct, and the upstream compiler has no clause that leaves it `nil`. Four
clauses of `build_data_value/2` produce it, and every one returns a
`Location`:

- `statifier lib/statifier/compiler.ex:1783-1790` - the `expr` clause. The
  span comes from `data_expr_location/1` (`:1812-1816`), which is
  `Map.get(attribute_locations, :expr, location)`.
- `statifier lib/statifier/compiler.ex:1792-1794` - the `src` clause, via
  `data_src_location/1` (`:1819-1823`), the same shape keyed on `:src`.
- `statifier lib/statifier/compiler.ex:1796-1802` - the child-text clause.
  Both arms - blank text and non-blank - return `data.location`.
- `statifier lib/statifier/compiler.ex:1804` - the bare clause, also
  `data.location`.

`build_data/2` (`:1765-1776`) destructures that pair straight onto the
struct's `value_location`. The clause set is identical in the version this
repository is pinned to (statifier 2.0.0, `mix.lock:29`, read at
`deps/statifier/lib/statifier/compiler.ex`) and in the sibling checkout of
statifier-ex at `3d1b8db` (version 2.4.0, `mix.exs:4`) - same four clauses,
same line numbers, no drift between the pin and upstream `main`. The
`location_object_or_nil` arm in the producer is therefore defensive rather
than reachable, which is what makes the field's presence uninformative.

### What the format already says, and what the tests pin

The schema does not promise the field is always there:

- `docs/wire-format.md:398` - the presence cell reads *"present only when
  the compiler recorded a span for the element's value"*. Conditional, in
  the published schema, since the table existed.
- `docs/wire-format.md:413-427` - the note added by `sui-o5c`'s verify walk,
  spelling out that `value_location` is *not* always a value span and that a
  consumer must compare it against `location` before slicing.
- `test/statifier_ui/trace/manifest_test.exs:376-417` - the regression test
  that pins the fallback per variant.
- `test/statifier_ui/trace/manifest_test.exs:419-431` - pins that the key is
  present on every row, and its own comment says why that is not a schema
  claim: *"The wire-format schema still documents the field as conditional,
  so this asserts the observed behavior without binding the format to it."*

The gap this record closes is therefore not between the schema and a
proposal. It is between the schema, which already declares the field
conditional, and the producer, which never exercises the absent arm.

### The `cond_location` precedent is only half a precedent

The bead's argument is that `cond_location` already spells this with
absence. It does, on one axis and not the other:

- `statifier lib/statifier/compiler.ex:813` - `nil` when the transition
  carried no `cond` at all.
- `statifier lib/statifier/compiler.ex:815-817` - when a `cond` *was*
  written, `Map.get(attribute_locations, :cond, location)`: the same
  fallback-to-the-element's-own-span shape `data_expr_location/1` has.

So `cond_location` is absent when there is no guard, and present-but-wide
when there is a guard whose attribute span was not recorded.
`docs/wire-format.md:423-426` states the contrast as *"absent when there is
no guard rather than falling back, and therefore always spans a guard when
present"* - true about guard existence, and an overstatement about span
narrowness if the parser can ever omit the `:cond` entry for a written
`cond`. That is open question **O-2** below; it is not decided here and this
record does not edit that prose.

### The Absence rule is the format's own spelling for this

`docs/wire-format.md:241-266` states the rule once and generalizes it to
every nullable field: **key absent** means *"the field has no meaningful
value at all"*, distinct from `null` and from an empty collection. A span
equal to the element's own span is exactly "no value span" - there is no
meaningful value for the field to carry. Absence is the spelling the format
already reserves for that fact, and the fallback is a second, weaker
spelling of the same fact that the format has to document its way around.

### The golden fixture does not move

The bead assumes an omit-when-equal change *"moves the golden fixture
again"*. It does not:

- `test/support/trace/two_state.jsonl:1` carries `"data":[]`. The golden
  chart declares no `<data>` elements at all, and
  `grep -c value_location test/support/trace/two_state.jsonl` returns `0`.

All three options below are byte-neutral on the current golden, and
`test/statifier_ui/trace/golden_trace_test.exs` is untouched by any of them.
That removes one of the three arguments the bead recorded against the
change.

### What the consumers do with it today

- `lib/statifier_ui/trace/diagnostic.ex:94-105` - anchors a diagnostic on
  `data.value_location` only `if data.value_location && data.value_location
  != data.location`, falling back to the node anchor otherwise.
- `lib/statifier_ui/datamodel_explorer/scope.ex:152` - a dedicated clause,
  `%Data{value_location: same, location: same}`, returning no declared
  source.

Both read the **compiled struct**, not the wire, and both already carry a
nil-or-equal branch, so neither changes under any option here. No consumer
in this repository reads the wire key: `grep -rn value_location assets/`
returns nothing, and the field appears in no JS.

### The projection position

`docs/adr/0012-trace-projection-and-redaction.md:305` places every
`session.start` table's `location` and `value_location` object in the set of
**structural positions that are never projected**, and `:320` names the
`data` row's four fields explicitly. `:336-352` records the caveat that the
table is identity-only and that a consumer must compare the two spans.
Removing a structural key does not create a value position, so the closed
position set is unchanged under every option.

### The two sibling decisions this one is next to

Both are wire decisions in this repository, both `proposed`, and all three
are recorded together so they do not drift:

- **ADR-0014** (`sui-4lr`), non-value error reasons on the wire - widens the
  event `error` object additively. Its `:126-130` already names this record
  as the other open additive wire change.
- **ADR-0015** (`sui-2s4`), a neutral discriminator beside
  `session.terminated`'s `reason` - adds one optional `kind` field.

Both of those *add* a key under the must-ignore rule. This one is the odd
member of the trio: it *removes* a key on two of four variants, which is why
the compatibility argument below is made on a different limb than theirs.

## Options considered

### Option A - keep the fallback, keep documenting it

Status quo. `value_location` is always present; `docs/wire-format.md:413-427`
carries the note; `manifest_test.exs:376` and `:419` pin it.

For: it changes nothing. The producer's shape stays congruent with the
upstream `Machine.Data` struct, no consumer written against observed
behaviour breaks, and the build-time cost stays zero.

Against: the field's presence carries no information, so *every* consumer
pays an equality check forever, and the one that forgets it does not fail -
it renders `<data id="x"/>` as the element's declared value. A silent wrong
render is the failure mode the note at `:413` exists to prevent by prose
alone, and prose is not a mechanism.

### Option B - omit `value_location` when it equals `location` (recommended)

The producer compares the two spans and writes the key only when they
differ. Key-absence becomes the signal, per the format's own Absence rule.

For: it makes the schema's already-published presence rule true; it moves
the consumer's obligation from "remember to compare" to "handle an absent
optional field", which is the obligation every other optional field in this
format already imposes; the wrong answer stops being available at all; and
the golden does not move.

Against: it is a *removal* on two variants, so it is not additive and cannot
lean on the must-ignore rule (see Decision 2); it diverges the wire row's
shape from the `Machine.Data` struct's, which always carries the field; and
it costs one `Location` comparison per `<data>` element at manifest-build
time - once per session, on a table that is already O(data elements).

### Option C - an additive boolean, `value_location_synthetic`

Keep `value_location` always present and add a boolean beside it, `true`
when the span is the element's own fallback.

For: purely additive, so it lands squarely under the must-ignore rule with
no compatibility argument to make at all; the struct and the wire stay
congruent; and it names the fact rather than leaving it to be derived.

Against, and decisive: it encodes a fact the message already carries - the
two spans are right there and comparable - so it creates a second source of
truth that a future producer bug can make disagree with the first. It also
adds a key to *every* `data` row to describe two of four variants, and it
leaves the wrong answer available: a consumer that ignores the boolean
slices exactly as wrongly as it does today. It buys naming and pays with
redundancy, and the naming is the part the format cares least about.

## Decision

Recommended, pending the operator's flip. The Status line above stays
`proposed`.

### 1. Option B: the producer omits `value_location` when it equals `location`

`data_object/1` compares `element.value_location` against `element.location`
and passes `nil` to the existing `put_present/3` call when they are equal.
The `location_object_or_nil` arm that is unreachable today becomes the
normal path for the child-content and bare variants, so the producer gains a
comparison and no new branch.

The rule keys on **the spans**, not on how the element was written. An
`expr`- or `src`-written element whose parser recorded no attribute span
falls back to `data.location` inside `data_expr_location/1`
(`statifier lib/statifier/compiler.ex:1812-1816`) and is therefore omitted
too. That is the intended reading: the field's contract is "this is where
the written value is", and an element with no recorded value span has no
answer to give, however it was written.

### 2. This is not "additive", and the version still stays `1`

The two claims have to be separated, because conflating them is the easy
mistake here.

**It is not additive.** ADR-0005's versioning rule
(`docs/adr/0005-language-neutral-trace-wire-format.md:215-222`) says
consumers must ignore *unknown fields and unknown types*, and concludes that
*additive* change is not a version bump. That rule is about keys appearing.
It says nothing about a key that stops appearing, and nothing in it protects
a consumer from a removal. A record that called this change additive would
be citing a rule that does not reach it.

**It is also not a schema change.** The presence cell at
`docs/wire-format.md:398` has read *"present only when the compiler recorded
a span for the element's value"* since the table was written. A consumer
conformant to the published schema already carries the absent branch; this
change makes the producer's behaviour converge on the schema rather than
widening the schema to fit the producer. `manifest_test.exs:419-424` says
the same thing in its own comment, and deliberately did not bind the format
to the observed behaviour.

**So the version stays `1` on the second limb of the bump test, not the
first.** ADR-0005's test is whether *"a consumer of the old version would
misread the stream"*. A schema-conformant consumer does not misread it - it
already branches on absence. A consumer coupled to the observed behaviour
does not misread it either: it finds the key missing, which is a loud
failure at the point of the mistake. What it does *today* is misread the
stream - it slices the whole `<data>` element out of `source` and shows it
as a declared value, with nothing anywhere reporting a problem. Trading a
silent wrong render for a hard absence is the substance of the
recommendation; the removal is only the mechanism.

### 3. Per variant, in full

Line numbers for the compiler are `statifier lib/statifier/compiler.ex`,
identical in the pinned 2.0.0 and in statifier-ex `3d1b8db`.

| `<data>` as written | compiler clause | `value_location` on the struct | today's wire (A) | B - omit when equal | C - boolean flag |
|---|---|---|---|---|---|
| `<data id="x" expr="1 + 1"/>` | `:1783`, span from `data_expr_location/1` `:1812-1816` | the `expr` attribute value's span, narrower than `location` | present, narrow | present, narrow - unchanged | present, narrow, plus `value_location_synthetic: false` |
| `<data id="x" src="http://..."/>` | `:1792`, span from `data_src_location/1` `:1819-1823` | the `src` attribute value's span, narrower than `location` | present, narrow | present, narrow - unchanged | present, narrow, plus `value_location_synthetic: false` |
| `<data id="x">42</data>` (child content) | `:1796`, non-blank arm, `data.location` | equal to `location` | present, equal to `location` | **key absent** | present, equal, plus `value_location_synthetic: true` |
| `<data id="x"/>` bare, or whitespace-only child text | `:1804`, and `:1796`'s blank arm | equal to `location` | present, equal to `location` | **key absent** | present, equal, plus `value_location_synthetic: true` |
| `expr`/`src` written but no attribute span recorded (see O-2) | `:1783`/`:1792`, `Map.get` default arm | equal to `location` | present, equal to `location` | **key absent** | present, equal, plus `value_location_synthetic: true` |

The four rows of `manifest_test.exs:376-417` are exactly the first four
variants, in that order, on one chart. The fifth row is not exercised by any
test in this repository today.

### 4. Projection and the golden are both untouched

`value_location` stays a structural position under ADR-0012 (`:305`,
`:320`), so no projection profile changes and no new value position is
created. `test/support/trace/two_state.jsonl` carries `"data":[]`, so the
golden trace is byte-identical before and after, and
`golden_trace_test.exs` needs no re-take.

### 5. `cond_location` is aligned on the absence axis, not claimed identical

After this change both fields spell "there is nothing here" with key
absence. They still differ in what "nothing" means - `cond_location` absent
means the transition had no guard, `value_location` absent means the element
had no distinct value span - and O-2 below may show `cond_location` keeps a
fallback arm of its own. The alignment claimed is the spelling, not the
semantics, and `docs/wire-format.md:423-426` needs rewriting to say that
much on acceptance.

## Implementation

Not in this pull request, and no bead is filed by this record. **An
implementing bead is filed on acceptance**, and it moves these together in
one commit:

1. `lib/statifier_ui/trace/manifest.ex:234-241` - the span comparison in
   `data_object/1`.
2. `docs/wire-format.md:413-427` - the fallback note is replaced by an
   absence note, and `:398`'s presence cell is restated in terms of a
   *written* value rather than a recorded span.
3. `test/statifier_ui/trace/manifest_test.exs:376-417` - the four-variant
   test inverts on its last two rows, `:345-365` narrows to the `expr` rows,
   and `:419-431` is replaced by its converse.
4. The code comments that cite the note by line - at least
   `lib/statifier_ui/trace/diagnostic.ex:94-97` (which cites
   `docs/wire-format.md:411-424`, already one line-range stale) and
   `lib/statifier_ui/datamodel_explorer/entry.ex:35` - are re-pointed.
5. A `changelog.d/` fragment, since a documented wire behaviour changes.
6. `test/statifier_ui/trace/wire_format_payload_schema_test.exs` - the
   presence-column drift test `8119f19` added after this record merged. It
   ties `docs/wire-format.md:398` to what the producer builds, so items 1
   and 2 have to land in the same commit or it fails either way; see the
   2026-09-05 amendment, section 3.

`lib/statifier_ui/trace/diagnostic.ex:103` and
`lib/statifier_ui/datamodel_explorer/scope.ex:152` need no change: both read
the struct, and both already handle nil-or-equal.

## Consequences

- A consumer can stop comparing spans. Presence of `value_location` becomes
  the answer to "is there a written value to show", which is the question
  every consumer of the table was asking through a two-key comparison.
- The silent wrong render stops being reachable. A consumer that slices
  without checking gets a missing key rather than the element's own text
  presented as a value.
- The wire row and the `Machine.Data` struct diverge in shape. That is a
  cost, and it is the same cost the table already pays by carrying no
  `value` at all (`docs/wire-format.md:400-411`): this format is a
  projection of the struct, not a serialization of it.
- A consumer written against observed behaviour rather than the published
  schema breaks loudly. This format has one such consumer set, in this
  repository, and it is on the struct side; a second interpreter written
  against `docs/wire-format.md` was never promised the key.
- ADR-0005's must-ignore rule gains a limit that is now written down: it
  covers additions only, and a removal has to argue the bump test directly.
  That is a precedent this repository will have to apply again.
- One `Location` comparison per `<data>` element at manifest-build time,
  once per session.

## Open questions

- **O-1.** Should the implementing bead land before or after ADR-0014's and
  ADR-0015's? All three are byte-neutral on the current golden
  (`"data":[]`), so ADR-0014's "re-take the capture once rather than twice"
  argument (`docs/adr/0014-non-value-error-reasons-on-the-wire.md:126-130`)
  does not bind them together. Ordering is free.
- **O-2.** Can the parser record a `<data>` with an `expr` or `src`
  attribute, or a transition with a `cond`, and *not* record the matching
  entry in `attribute_locations`? Both `data_expr_location/1` and
  `cond_location/1` carry a `Map.get` default that says yes, and no test in
  this repository exercises it. If the answer is no, the fifth row of the
  per-variant table is unreachable and
  `docs/wire-format.md:423-426`'s claim about `cond_location` is exact. If
  yes, both statements need softening. This is an upstream question
  (statifier owns the parser and the compiler) and is a `st-` bead, not
  work to do from here (ADR-0010).
- **O-3.** Does any out-of-repo consumer of the v1 wire read
  `value_location` unconditionally? None is known; the format has one
  producer and one consumer set today. If the answer changes before the
  implementing bead lands, the bump test in Decision 2 is re-argued rather
  than assumed.

## Notes

- The question was raised, and deliberately not answered, during `sui-o5c`'s
  deferred-verification walk. That pass corrected
  `docs/wire-format.md` to describe what the producer actually does and left
  the design question to this bead, `sui-v8o`.
- Sibling wire records, both `proposed`: **ADR-0014** (`sui-4lr`) and
  **ADR-0015** (`sui-2s4`).
- Cites resolve against statifier 2.0.0 as pinned in `mix.lock:29` and
  vendored at `deps/statifier/`, cross-checked against the statifier-ex
  checkout at `3d1b8db` (2.4.0); the four `build_data_value/2` clauses and
  the two `data_*_location/1` helpers sit at the same line numbers in both.
