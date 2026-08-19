---
date: 2026-08-19
planner: Claude
git_commit: b2740b79842978a24f599187508843ddf5e72537
branch: sui-o5c-data-identity-table
repository: statifier-ui
beads_issue: sui-o5c
topic: "Adding a data identity table to session.start"
tags: [plan, trace, wire-format, manifest]
status: ready
---

# Data identity table in `session.start` - Implementation Plan

## Overview

`session.start` carries three identity tables - `states`, `transitions`,
`contents` - which is what makes a state `index`, a `t_index`, and a
`c_index` resolvable to a source location by a consumer that has no
compiler. Statifier's compiler now assigns `<data>` elements a dense
`d_index` resolved through `Statifier.Machine.data/2`, and that index
already reaches the wire (the `{:data, d_index}` origin variant,
`lib/statifier_ui/trace/normalizer.ex:451-452`, documented at
`docs/wire-format.md:588`), with more of it coming when `sui-h92`
serializes `Effect.DatamodelChange`. There is no fourth table, so a
`d_index` on the wire today resolves to nothing.

Add the fourth table. Bead: sui-o5c.

## Current State Analysis

**The producer.** `StatifierUI.Trace.Manifest.build/3`
(`lib/statifier_ui/trace/manifest.ex:73-96`) builds the `session.start`
payload as a literal map of `"version"`, `"states"`, `"transitions"`,
`"contents"`, then folds in four optional caller-supplied fields through
`put_present/3`. Each table is built by walking the corresponding dense
tuple on the `%Statifier.Machine{}` - `states/1` at `:110-115`,
`transitions/1` at `:132-137`, `contents/1` at `:155-160` - and mapping
each element to a small map of identity plus spans. Nothing looks anything
up; the tuples are already in index order, so document order and array
order are the same thing.

**The source.** `%Statifier.Machine{}` carries `data_elements` as a fifth
dense tuple (`deps/statifier/lib/statifier/machine.ex:122-164`), read
element-wise by `Statifier.Machine.data/2` (`:206-207`).
`%Statifier.Machine.Data{}` (`deps/statifier/lib/statifier/machine/data.ex`)
has five fields:

- `d_index` - `non_neg_integer()`, dense from 0 across the whole machine
- `id` - `String.t()`, an enforced key (SCXML requires `id` on `<data>`)
- `value` - `Machine.expr() | {:invalid, Error.t()} | {:src, uri}`
- `location` - `Location.t()`, the `<data>` element's own span, enforced
- `value_location` - `Location.t() | nil`, the diagnostic span for the
  value, following the same "caller's choice" contract as
  `cond_location`/`expr_location`

**What the format already commits to.** ADR-0005 defines `session.start` as
carrying "the identity tables the compiled Machine retains - state index to
id and location, `t_index` and `c_index` to location", and separately
requires "identities as the engine emits them ... never resolved nodes".
`docs/wire-format.md:129-236` ("JSON discipline") then binds four rules on
anything new: the `$`-tagged value encoding, key-absence versus `null`,
`"kind"` tagging for tuple variants, and lexicographic object keys with
canonical array order.

**The golden fixture.** `test/support/trace/two_state.jsonl` is compared
byte-for-byte by `test/statifier_ui/trace/golden_trace_test.exs`, twice per
run. Its chart has no `<datamodel>`, so the new table is `[]` there and the
change to the fixture is one inserted key on line 1. The same bytes are
duplicated in `docs/wire-format.md`'s worked example
(`docs/wire-format.md:687-752`), which no test guards - it must be moved by
hand in the same commit or the spec goes stale silently.

**The drift test.** `test/statifier_ui/trace/wire_format_spec_test.exs`
compares only the "Type index" table's `type` strings to
`Normalizer.types/0`. It says nothing about payload schemas, so nothing
mechanically forces `docs/wire-format.md` to describe the new field, and
nothing catches the spec's field table disagreeing with its own worked
example. That is why the documentation carries its own reviewed criteria
rather than being an afterthought, and why the single row that would
create such a disagreement is pulled forward into phase 1.

## Desired End State

`Manifest.build/3` emits a fourth array under the payload key `"data"`,
one object per compiled `<data>` element in `d_index` order, carrying
`d_index`, `id`, `location`, and `value_location` - and deliberately not
`value`. `docs/wire-format.md`'s `session.start` section documents the
field, its row schema, and the reason `value` is absent. The golden
fixture and the worked example both carry `"data":[]` on the
`session.start` line and are otherwise unchanged. `mix quality` is green.

Verified by: `mix test test/statifier_ui/trace/golden_trace_test.exs`
passing with `git diff --numstat test/support/trace/two_state.jsonl`
reporting exactly `1  1`; new `ManifestTest` assertions over a chart that
declares `<data>` elements; and full `mix quality`.

### Key Discoveries:

- `Manifest.build/3`'s payload literal is at
  `lib/statifier_ui/trace/manifest.ex:78-83`; the three existing table
  builders are at `:110-115`, `:132-137`, `:155-160`, and the shared
  helpers `location_object/1`, `location_object_or_nil/1`, `put_present/3`
  at `:194-213`. The new table is a fourth instance of an established
  four-line pattern, not a new mechanism.
- `%Statifier.Machine.Data{}` is
  `deps/statifier/lib/statifier/machine/data.ex`; `Machine.data/2` is
  `deps/statifier/lib/statifier/machine.ex:206-207` and `data_elements` is
  the tuple behind it (`:122-128`).
- `transitions[].cond_location` (`manifest.ex:150`, documented
  `docs/wire-format.md:284`) is the exact precedent for `value_location`:
  an optional diagnostic span, emitted through `put_present/3`, present
  only when the compiler recorded one - and emitted *without* the
  expression it spans. The `transitions` table has never carried the
  `cond` source or its compiled program.
- `StatifierUI.Trace.Json.encode/1` sorts object keys lexicographically at
  every level (`lib/statifier_ui/trace/json.ex:30-36`), so the insertion
  order of the payload literal does not affect bytes. `"data"` lands
  between `"contents"` and `"seq"` on the wire.
- `test/statifier_ui/trace/manifest_test.exs:20-45` already has an
  `@all_content_kinds` chart declaring two `<data>` elements
  (`items`, `x`), so the non-empty case has a chart in place; `@two_state`
  (`:9-17`) covers the empty case.
- ADR-0005's versioning rule: "additive change is therefore not a version
  bump". `"version"` stays `1`.
- ADR-0011 (exit/entry sets are sequences) and the canonical-order rule
  (`docs/wire-format.md:212-236`): `data_elements` is a dense tuple in
  document order, which is `d_index` order, so emitting it in tuple order
  satisfies both the "engine order" and the "ascending index" readings.
  No sorting step is needed or wanted.

## What We're NOT Doing

- **Not carrying `value` across the wire.** See "The `value` decision"
  under Implementation Approach. This is the plan's one substantive design
  call and it is settled here, not deferred to the implementer.
- **Not carrying a `value_source` / `kind` discriminator** naming which of
  the four `value` variants a row has (`expr`, `src`, inline text, none).
  It is defensible - it tells a consumer *why* a row has no value without
  exposing one, and a `{:src, uri}` element is known to always fail at
  binding time - but it is not identity, the bead does not ask for it, and
  ADR-0005 makes an additive field a non-breaking change at any later date.
  If a consumer turns out to need it, it costs one field and no version
  bump. Adding it now costs a `"kind"` enumeration this repo would have to
  keep in step with the compiler's precedence rules for no consumer.
- **Not serializing `Effect.DatamodelChange`.** That is `sui-h92`, which
  this bead unblocks. Nothing in this plan touches
  `lib/statifier_ui/trace/normalizer.ex`.
- **Not adding attribute-level spans.** `docs/wire-format.md:337-346`
  already records that finer granularity lives on `Document`, not
  `Machine`, and tracks it as `sui-qay`. `value_location` is a `Machine`
  field and is in scope; nothing beyond it is.
- **Not bumping the `session.start` `version`.** Additive, per ADR-0005.
- **Not re-baselining the golden fixture.** The only permitted movement is
  the `session.start` line. Any other line moving is a signal to stop.
- **Not correcting the three passages `docs/research/260819-...:661-668`
  flags as false in `docs/wire-format.md`** (`:57-65`, `:100-114`). They
  are outside this bead and belong to the beads that consume each change.

## Implementation Approach

Two phases. Phase 1 is the wire change and everything the wire change
forces to move in the same breath - the producer, its unit tests, the
golden fixture, the worked-example bytes that duplicate the fixture, and
the one-row addition to the `session.start` field-presence table that
keeps the spec from contradicting its own worked example. Phase 2 is the
new normative prose: the row schema, the identity-only rationale, and the
cross-references.

The split is real: phase 1 is Elixir with a full gate behind it, phase 2
touches no Elixir and commits on review of the diff (CLAUDE.md's
`git commit` row). Neither phase leaves the repo self-contradictory. After
phase 1 the producer, the fixture, the worked example, and the field table
all agree that `session.start` carries a `data` array; the spec is then
merely incomplete - it names the field without yet specifying the row -
and incompleteness in a document that is still being written is a
different thing from a document that disagrees with itself. Phase 2
completes it.

The line between the phases is therefore "bytes and facts already true"
versus "prose newly written", not "code" versus "docs" - which is why one
small documentation edit rides along in phase 1.

### The `value` decision

**The table is identity-only: `d_index`, `id`, `location`,
`value_location`. `value` does not cross the wire.**

The argument, from the format's own rules rather than from taste:

1. **ADR-0005 scopes the definition message to identity.** It names what
   `session.start` carries: "the identity tables the compiled Machine
   retains - state index to id and location, `t_index` and `c_index` to
   location. This is what makes indexes on later messages resolvable by a
   consumer that has no compiler, and it is why events themselves stay
   small." A fourth table added to that list inherits that scope. The
   bead's own title and framing agree: this is an identity table whose job
   is resolving a `d_index` to a source location.

2. **The sibling tables already answer this question.** `transitions`
   carries `cond_location` and not the `cond` expression;
   `contents` carries `c_index`, `kind`, and `location` and not a
   `<log>`'s `expr`, a `<send>`'s `event`, or an `<assign>`'s target path.
   Every compiled expression in the machine is currently represented on
   the wire by its span alone. A `value` field on `data` would be the
   single exception, and an exception in the definition message is exactly
   the kind of local convenience ADR-0005's failure-mode section warns
   about.

3. **Three of the four variants have no honest encoding.**
   `{:compiled, Predicator.Compiled.t(), source}` holds a predicator
   instruction program - an Elixir struct that is not part of the value
   domain `StatifierUI.Value` is closed over, and squarely the "atoms,
   MapSets, and module names are not a contract another stack can meet"
   failure ADR-0005 names. `{:invalid, error}` holds a
   `Statifier.Compiler.Error`, which this format has no encoding for at
   all. `{:src, uri}` would need `"kind"` tagging
   (`docs/wire-format.md:193-211`) invented for a fourth variant set.
   Only `{:static, v}` maps cleanly, through the `$`-tagged value codec -
   and shipping one variant of four is worse than shipping none, because
   a consumer cannot tell "this element has no static value" from "this
   producer declined to encode it".

4. **`{:static, nil}` is genuinely ambiguous.** The upstream moduledoc is
   explicit that "no value source at all is `{:static, nil}`", and that
   non-blank child text is *also* folded to `{:static, _}`. So a `nil`
   static value means either "declared with no value" or "declared with a
   literal null-valued body". The absence rule
   (`docs/wire-format.md:166-192`) demands a consumer be able to tell
   those apart, and the `Data` struct as it stands does not let the
   producer do so. Encoding `value` would therefore require *inventing* a
   distinction the engine does not make - a design decision that belongs
   upstream in an `st-` bead, not here (CLAUDE.md: the engine is not
   modified from here).

5. **The consumer's need is already met, twice over.** A consumer wanting
   to *show* a `<data>` element's declared value has `source` (the SCXML
   text, on the same message) plus `location` and `value_location`, and
   slices the declared text out of it - the text-first principle
   (ADR-0007), and precisely how a consumer already displays a
   transition's `cond`. A consumer wanting the element's *runtime* value
   has `session.datamodel` for the starting snapshot and, once `sui-h92`
   lands, `trace`/`session` datamodel-change messages for every assignment
   after it. Neither need requires the compiled declaration on the wire.

6. **The decision is reversible in the cheap direction only.** ADR-0005
   makes adding a field later a non-event: additive change is not a
   version bump and consumers must ignore unknown fields. Removing a field
   consumers have started reading is the expensive direction. Identity-only
   is the choice that keeps the cheap door open.

### The field name

**`"data"`.**

The sibling tables are named for the entity class their rows are, and the
first two are the SCXML element tag pluralized (`<state>` -> `states`,
`<transition>` -> `transitions`); `contents` names the executable-content
class the `c_index` family covers. `<data>` gives `data`, which is already
the plural of datum and reads correctly as "the data elements". `datas` is
not English and `data_elements` imports the Elixir struct field's name into
a format that is meant to be language-neutral.

The objection is that `data` occupies value positions elsewhere in the
format (`_event.data`, `<send>`'s resolved `data`), so a reader might
expect an object. That collision is positional and the format already
lives with it: `source` is the SCXML text on `session.start` and the
owning state's index on a `transitions` row. Positional reuse of a common
word is not ambiguity when each occurrence has a schema. The `d_index`
naming also lines the four families up cleanly - `index`, `t_index`,
`c_index`, `d_index` against `states`, `transitions`, `contents`, `data`.

---

## Phase 1: The producer, its tests, and the golden bytes

### Overview

`Manifest.build/3` grows a fourth table. The golden fixture, the
worked-example JSON block, and the `session.start` field-presence table
move by exactly the one key that adds, in the same commit.

### Changes Required:

#### 1. The producer

**File**: `lib/statifier_ui/trace/manifest.ex`
**Changes**: add the `Data` alias, add `"data"` to the payload literal, and
add a fourth table-builder section modeled on `contents/1`.

Alias block (`:42-47`), in alphabetical position - between `Statifier.Machine.Content` (`:43`) and `Statifier.Machine.State` (`:44`):

```elixir
alias Statifier.Machine.Data
```

Payload literal (`:78-83`) gains one key. Insertion order is irrelevant to
the bytes (`Json.encode/1` sorts), but keep it in the same order the
document's schema table will list, after `"contents"`:

```elixir
%{
  "version" => @manifest_version,
  "states" => states(machine),
  "transitions" => transitions(machine),
  "contents" => contents(machine),
  "data" => data(machine)
}
```

A new section after `-- contents --` and before `-- Locations --`:

```elixir
# -- data ---------------------------------------------------------------------

@spec data(Machine.t()) :: [map()]
defp data(%Machine{data_elements: data_elements}) do
  data_elements
  |> Tuple.to_list()
  |> Enum.map(&data_object/1)
end

@spec data_object(Data.t()) :: map()
defp data_object(%Data{} = element) do
  %{
    "d_index" => element.d_index,
    "id" => element.id,
    "location" => location_object(element.location)
  }
  |> put_present("value_location", location_object_or_nil(element.value_location))
end
```

Note the local is `element`, not `data` - a variable named `data` next to a
private `data/1` and an aliased `Data` module is the kind of shadowing that
reads badly in review even where the compiler tolerates it.

`element.id` is not routed through `put_present/3`: `:id` is an enforced
key on `%Statifier.Machine.Data{}` typed `String.t()`, and SCXML requires
`id` on `<data>`. This differs from `states[].id`, which is genuinely
optional. `element.location` is likewise enforced and always a full span,
so it uses `location_object/1` directly; only `value_location` is nullable
and therefore takes the `cond_location` treatment.

**Moduledoc**: the first paragraph (`:3-8`) enumerates the resolvable
index families as "(state `index`, `t_index`, `c_index`)". Add `d_index`.
Do not extend the `Content.Script`/`Content.Assign` gotcha section - it is
about executable content and nothing here changes it.

#### 2. Unit tests for the new table

**File**: `test/statifier_ui/trace/manifest_test.exs`
**Changes**: add a `describe "build/3 - data table"` block alongside the
existing per-table blocks. Cover:

- **The empty case.** `@two_state` declares no `<datamodel>`, so
  `message.payload["data"] == []` - present and empty, never absent. This
  is the case the golden fixture exercises, and it is the one an
  implementer is most likely to break by reaching for `put_present/3` on
  the table itself.
- **The populated case.** `@all_content_kinds` (`:20-45`) declares
  `<data id="items" expr="[1, 2, 3]"/>` and `<data id="x" expr="0"/>`.
  Assert two rows, `d_index` `0` and `1` in that order, `id` `"items"` and
  `"x"`, and that the `d_index` values are exactly `Enum.to_list(0..1)` -
  density and document order in one assertion.
- **Every row resolves back through the engine.** For each row, assert
  `Machine.data(machine, row["d_index"]).id == row["id"]` - the property
  the table exists to provide, asserted against the resolver itself rather
  than against a transcribed literal. This one belongs in the existing
  `describe "build/3 - index round-trip"` block
  (`test/statifier_ui/trace/manifest_test.exs:147`), whose single test
  already covers `Machine.at/2`, `transition/2`, and `content/2`: extend
  that test and its name to the fourth resolver rather than starting a
  parallel one. `Machine` is already aliased in this file (`:4`).
- **`location` is a full six-field span** on every row, matching how the
  other tables' location assertions are written in this file.
- **`value_location` is present** on both rows of `@all_content_kinds`
  (both are written with an `expr` attribute, so the compiler records the
  attribute value's span) and is a six-field span, not a string. The
  string check is deliberate: it is the `Content.Assign` class of bug the
  moduledoc already documents once, and asserting the shape rather than
  the mere presence is what catches it.
- **No `value` key.** Assert `Map.has_key?(row, "value") == false` on
  every row. This is the plan's design decision made mechanical, so a
  later well-meaning addition trips a test and re-reads this document.
- **Canonical bytes.** Assert that `"data"` lands between `"contents"` and
  `"seq"` in the encoded line - `Json.encode_message(message)` over the
  `@two_state` machine should contain the substring
  `"contents":[],"data":[],"seq":0`. There is no exact precedent for this
  assertion in the file (the nearest, the fixtures block, checks a byte
  substring but not ordering), so it is written from scratch rather than
  copied. It is worth writing: it is the only test that pins the new key's
  canonical position, and it is the assertion the golden fixture would
  otherwise be the sole guard of.

If a chart producing a `nil` `value_location` cannot be written (the
compiler falls back to the `<data>` node's own location when no attribute
span exists), do **not** invent one with a hand-built struct: the
`location_object_or_nil(nil)` branch is already exercised by
`cond_location`. Note the absence in the test's comment instead.

#### 3. The golden fixture

**File**: `test/support/trace/two_state.jsonl`
**Changes**: regenerate. The chart has no `<datamodel>`, so the only
change is `"data":[],` inserted on line 1 between the `"contents":[]` and
`"seq":0` keys. Line 1 is the only line that may move.

Regenerate rather than hand-edit. The chart lives as a module attribute
inside the test and the fixture's byte offsets were captured from that
exact text (`golden_trace_test.exs:22-24`), so the only safe regeneration
is the test's own `run_trace/0` path. Add a temporary test to
`golden_trace_test.exs`:

```elixir
@tag :regen
test "regenerates the fixture" do
  File.write!(@fixture_path, run_trace())
end
```

run it with
`mix test test/statifier_ui/trace/golden_trace_test.exs --only regen`,
then **delete the temporary test before committing** - a fixture that
rewrites itself on demand is one careless `--include` away from being no
fixture at all. Deriving the bytes from a copy of the chart pasted
anywhere else risks exactly the offset drift the fixture's comment warns
about.

Then check the diff before anything else:

```bash
git diff --numstat test/support/trace/two_state.jsonl   # must be exactly: 1  1
git diff -U0 test/support/trace/two_state.jsonl | grep -c '^[+-]{"'  # must be 2
```

`1  1` - one line added, one removed - is the whole permitted diff. Any
other pair of numbers means a line other than `session.start` moved, and
that is an engine behavior change to trace, not part of this bead. Stop
and investigate; do not accept the new bytes.

`@full_seq` in `golden_trace_test.exs` does **not** change: no message is
added or removed, only one key on an existing message.

#### 4. The worked example's bytes, and the field-table row

**File**: `docs/wire-format.md`
**Changes**: two edits, both minimal, both here rather than in phase 2.

First, the worked example's JSON block (`:687-752`) duplicates the fixture
verbatim. Replace its `session.start` line - the first line of the ```json
fence - with the regenerated line 1, byte for byte. No other line in the
block changes.

Second, the `session.start` field-presence table (`:245-254`) gains one
row after `contents`:

```
| data | array of objects | always |
```

"always" is correct and load-bearing: a chart with no `<datamodel>` emits
`[]`, never key-absence. That is the empty-collection arm of the absence
rule (`:166-192`), and it is worth one clause of prose beneath the table
saying so.

Both edits live in phase 1 rather than phase 2 on purpose. The worked
example's bytes are a copy of the fixture, not documentation of the
schema, and letting them diverge for even one commit puts a false trace in
the normative spec with no test to catch it. The field-table row travels
with them for the same reason: shipping the worked example showing
`"data":[]` while the normative table forty lines above it does not list
`data` as a field leaves the spec disagreeing with itself, and no test
catches that either (see Open Question 4). One row is cheap enough that
there is no reason to carry the inconsistency across a commit boundary.

What stays in phase 2 is everything that is genuinely new prose: the row
schema, the identity-only rationale, and the cross-references. Nothing in
this phase changes any other prose in the file.

### Success Criteria:

#### Automated Verification:
- [ ] `mix quality` (full) is green - no stage red, coverage at or above
      the 80% floor in `coveralls.json`
- [ ] No stage newly reports `○`; the only two skipped stages are Gettext
      and Sobelow, per CLAUDE.md
- [x] `mix test test/statifier_ui/trace/golden_trace_test.exs` passes with
      no edit to that file beyond the temporary regeneration test being
      added and removed
- [x] `git diff --numstat test/support/trace/two_state.jsonl` reports
      exactly `1	1`
- [x] `head -1 test/support/trace/two_state.jsonl | grep -c '"contents":\[\],"data":\[\],"seq":0'`
      returns `1` - the new key is present, empty, and in canonical
      position
- [x] `grep -c '"data":\[\]' docs/wire-format.md` returns `1` - the worked
      example's session.start line moved with the fixture
- [x] `grep -c '^| data | array of objects | always |' docs/wire-format.md`
      returns `1` - the field-presence table names the field the worked
      example now shows
- [x] `diff <(head -1 test/support/trace/two_state.jsonl) <(grep -m1 '^{"contents"' docs/wire-format.md)`
      is empty - the worked example and the fixture are the same bytes
- [x] `mix test test/statifier_ui/trace/manifest_test.exs` passes, and
      `grep -c 'data table' test/statifier_ui/trace/manifest_test.exs`
      returns at least `1`
- [x] `git diff --stat` shows exactly four files changed:
      `lib/statifier_ui/trace/manifest.ex`,
      `test/statifier_ui/trace/manifest_test.exs`,
      `test/support/trace/two_state.jsonl`, `docs/wire-format.md`
- [x] `grep -c '@manifest_version 1' lib/statifier_ui/trace/manifest.ex`
      returns `1` - the version is untouched (additive change, ADR-0005)
- [x] `grep -c 'regen' test/statifier_ui/trace/golden_trace_test.exs`
      returns `0` - the temporary regeneration test was removed

#### Manual Verification:
- [ ] The regenerated fixture's `session.start` line, read against the
      previous one, differs only by the inserted `"data":[],` - confirmed
      by eye on `git diff --word-diff`, not only by the numstat count
- [ ] No test expectation elsewhere in the suite was widened or relaxed to
      accommodate the new key
- [ ] The `data_object/1` row shape matches this plan's row-schema table
      (phase 2, change 2) field for field - checked against the plan, not
      against `docs/wire-format.md`, which does not carry that table until
      phase 2
- [ ] No `value`, `value_source`, or `kind` field appears on a `data` row

**Implementation Note**: Use `mix quality --profile loop` between edits;
run full `mix quality` as the phase gate. In interactive execution, pause
here for the human to confirm the manual items before phase 2. In looped
execution the Automated Verification gates advancement and the Manual
items are deferred to the end.

---

## Phase 2: The normative schema

### Overview

Document the new table in `docs/wire-format.md`'s `session.start` section,
including the reason `value` is absent - the part a second interpreter's
author most needs and the part no test can supply.

### Changes Required:

Phase 1 has already added the `data` row to the `session.start`
field-presence table and moved the worked example's bytes, so this phase
starts from a file that is internally consistent and merely incomplete.

#### 1. The row schema

**File**: `docs/wire-format.md`
**Changes**: a `**data**` subsection after the `**contents**` one
(`:286-317`), before the location-object subsection, following the same
shape as its three siblings - one sentence of framing, then a presence
table:

> **`data`** is one object per compiled `<data>` element, in `d_index`
> order (document order across the whole chart, not per `<datamodel>`
> block):

| Field | Type | Presence |
|---|---|---|
| d_index | integer | always |
| id | string | always - SCXML requires `id` on `<data>` |
| location | location object | always - the `<data>` element's own span |
| value_location | location object | present only when the compiler recorded a span for the element's value |

Then the paragraph that carries the design decision, in the same
explanatory register as the `contents` section's `<script>` note:

> This table is deliberately **identity only**: it resolves a `d_index` to
> an id and a source span, and carries no representation of the element's
> declared value. A consumer wanting to display the declared value reads
> it out of `source` at `value_location`, the same way it reads a
> transition's guard out of `source` at `cond_location`; a consumer
> wanting a *runtime* value reads `session.datamodel` for the starting
> snapshot and the datamodel-change messages after it. The compiled value
> itself is a predicator instruction program, a compile error, or an
> unresolved `src` URI depending on how the element was written, and none
> of the three has a language-neutral encoding in this format. Adding a
> value field later would be an additive change and therefore not a
> version bump (ADR-0005), so this document commits to the narrow shape
> now rather than to an encoding it would have to keep.

#### 2. The origins cross-reference

**File**: `docs/wire-format.md`
**Changes**: the "Origins" table row for the `data` variant (`:588`) reads
"the platform raised the event about a `<data>` element that failed to
bind" and leaves the `d_index` unexplained. Add a sentence under that
table pointing at the new resolver, matching how the other index families
are cross-referenced: a `d_index` anywhere in this format resolves through
`session.start`'s `data` table.

The `session.datamodel` section (`:634-642`) is the second place worth one
clause: that message keys the datamodel by *variable name*, while the new
table keys the same elements by `d_index` and carries the `id` that joins
the two. Say so, and leave the rest of that paragraph alone -
`Effect.DatamodelChange` is still unserialized and `sui-h92` still owns
it, both of which remain true after this bead.

#### 3. The location-granularity caveat

**File**: `docs/wire-format.md`
**Changes**: the caveat at `:337-346` lists what the `Machine` layer does
and does not carry, naming `cond_location` as the one sub-element span
available. Add `value_location` beside it, so the caveat stays true.
Nothing else in that paragraph moves - `sui-qay` is still open and
attribute-level spans are still absent.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` (full) is green (this phase changes no Elixir, so the
      gate is a regression check rather than a review of new code)
- [x] `mix test test/statifier_ui/trace/wire_format_spec_test.exs` passes
      with no edit to that file, and the type index still has 23 rows:
      ``grep -c '^| `[a-z._]*` |' docs/wire-format.md`` returns `23`
- [x] `grep -c '^| d_index | integer | always |' docs/wire-format.md`
      returns `1`
- [x] `grep -c 'value_location' docs/wire-format.md` returns at least `3`
      - the schema row, the identity-only paragraph, and the granularity
      caveat
- [x] `git diff --stat` shows exactly one file changed,
      `docs/wire-format.md`
- [x] Every field name in the new schema table appears in
      `lib/statifier_ui/trace/manifest.ex`'s `data_object/1`:
      `for f in d_index id location value_location; grep -q "\"$f\"" lib/statifier_ui/trace/manifest.ex; end`
      exits 0

#### Manual Verification:
- [ ] The documented row schema matches the emitted one field for field,
      checked against `head -1 test/support/trace/two_state.jsonl` for the
      empty case and against a locally-run `Manifest.build/3` over a chart
      with `<data>` elements for the populated case
- [ ] The identity-only paragraph is intelligible to someone who has never
      read this plan or ADR-0005 - it states the decision, the consumer's
      alternative, and the reason, without requiring either
- [ ] The file's existing typography and heading conventions are matched
      (CLAUDE.md's house-style rule; this file already uses hyphens, so
      keep hyphens)
- [ ] No Elixir module, struct, or field name from statifier leaked into
      the normative prose beyond the existing, deliberate producer notes

**Implementation Note**: This phase touches no Elixir, so per CLAUDE.md's
`git commit` row it has no gate to run of its own and may commit on review
of the diff - but run full `mix quality` anyway, because the drift test
reads this file.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_ui/trace/manifest_test.exs` - the new
  `build/3 - data table` block: empty table on a chart with no
  `<datamodel>`, two dense rows in `d_index` order on
  `@all_content_kinds`, every row round-tripping through
  `Machine.data/2`, full six-field `location` on every row,
  `value_location` present and span-shaped, and no `value` key.
- `test/statifier_ui/trace/golden_trace_test.exs` - unchanged, and that is
  the point: it is the byte-comparison that proves the change is confined
  to one line of one message.
- `test/statifier_ui/trace/wire_format_spec_test.exs` - unchanged; it
  guards the type index, which this bead does not touch. Noted here so the
  implementer does not go looking for a schema drift test that does not
  exist.

### Manual Testing Steps:

1. Compile a chart with a mixed `<datamodel>` - one `<data expr=...>`, one
   `<data src="http://example.com/x.json"/>`, one `<data>` with inline
   text, one bare `<data id="n"/>`, and one with a deliberately broken
   `expr` (which the compiler captures as `{:invalid, _}` rather than
   failing the build) - and call `Manifest.build/3` on it. Confirm all
   five rows appear, dense from `d_index` 0, and that none of the five
   value variants leaks a field.
2. Slice the chart source at each row's `value_location` and confirm the
   span covers the written value - this is the consumer path the
   identity-only decision rests on, and it is worth confirming once by
   hand rather than assuming.
3. Read the regenerated `session.start` line and the worked example's
   first line side by side; confirm they are identical strings.

## References

- Bead: `sui-o5c` (blocks `sui-h92`, the `:datamodel_change` serializer)
- Related ADRs: `docs/adr/0005-language-neutral-trace-wire-format.md`
  (the format and its versioning rule),
  `docs/adr/0011-exit-and-entry-sets-are-sequences.md` (engine order is
  preserved, not re-sorted), `docs/adr/0007-text-first-authoring.md`
  (source is the source of truth, which is what makes a span sufficient
  where a value would be redundant),
  `docs/adr/0003-fixtures-as-the-example-data-contract.md` (the `version`
  convention `session.start` reuses)
- Spec: `docs/wire-format.md:237-346` (`session.start`),
  `:129-236` (JSON discipline), `:687-752` (worked example)
- Producer: `lib/statifier_ui/trace/manifest.ex:73-96` and the three
  existing table builders at `:110-115`, `:132-137`, `:155-160`
- Source structs: `deps/statifier/lib/statifier/machine/data.ex`,
  `deps/statifier/lib/statifier/machine.ex:122-128,206-207`
- Research: `docs/research/260819-sui-bpb-statifier-and-predicator-9-refresh-surface.md:386-397`
  (the gap this bead closes), `:655-658` (why it was filed)
- Fixture-regeneration precedent:
  `docs/plans/260819-sui-bpb-refresh-statifier-and-predicator-9.md:320-395`

## Open Questions

None of these block implementation; each is recorded because it was
decided without a human in the loop and a human may want to revisit it.

1. **The field name `"data"`.** Decided on the sibling-derivation rule
   (element tag pluralized) and on the `index`/`t_index`/`c_index`/`d_index`
   symmetry. The runner-up was `data_elements`, which is unambiguous
   against the format's other `data` fields but imports the Elixir struct
   field's name. If the name is to change, phase 1 is the cheap moment;
   after a consumer reads it, it is a breaking change.
2. **Omitting a `value_source` discriminator.** Recorded under "What We're
   NOT Doing" with its reasoning. It is the most likely thing a consumer
   asks for next, and ADR-0005 makes adding it free. Flagged so the choice
   is visible rather than invisible.
3. **Whether `value_location` can ever be `nil` in practice.** The
   upstream moduledoc says the compiler falls back to the `<data>` node's
   own location, which suggests never - but the struct's default and type
   both allow `nil`, so the producer handles it through `put_present/3`
   and the schema documents it as conditional. If it is provably always
   present, the schema row could tighten to "always" later; documenting it
   as conditional is the safe direction and costs a consumer one null
   check.
4. **No schema drift test.** `wire_format_spec_test.exs` guards only the
   type index, so nothing mechanically ties `docs/wire-format.md`'s
   payload schemas to the producer. This bead adds the fourth table
   without closing that gap - phase 2's criteria substitute a `grep`-level
   check. A real payload-schema drift test is worth its own bead, and this
   plan does not file one.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The regenerated fixture's `session.start` line, read against the
      previous one, differs only by the inserted `"data":[],` - confirmed
      by eye on `git diff --word-diff`, not only by the numstat count
- [ ] No test expectation elsewhere in the suite was widened or relaxed to
      accommodate the new key
- [ ] The `data_object/1` row shape matches this plan's row-schema table
      (phase 2, change 2) field for field - checked against the plan, not
      against `docs/wire-format.md`, which does not carry that table until
      phase 2
- [ ] No `value`, `value_source`, or `kind` field appears on a `data` row

**Implementation Note**: Use `mix quality --profile loop` between edits;
run full `mix quality` as the phase gate. In interactive execution, pause
here for the human to confirm the manual items before phase 2. In looped
execution the Automated Verification gates advancement and the Manual
items are deferred to the end.

---

### Phase 2

- [ ] The documented row schema matches the emitted one field for field,
      checked against `head -1 test/support/trace/two_state.jsonl` for the
      empty case and against a locally-run `Manifest.build/3` over a chart
      with `<data>` elements for the populated case
- [ ] The identity-only paragraph is intelligible to someone who has never
      read this plan or ADR-0005 - it states the decision, the consumer's
      alternative, and the reason, without requiring either
- [ ] The file's existing typography and heading conventions are matched
      (CLAUDE.md's house-style rule; this file already uses hyphens, so
      keep hyphens)
- [ ] No Elixir module, struct, or field name from statifier leaked into
      the normative prose beyond the existing, deliberate producer notes

**Implementation Note**: This phase touches no Elixir, so per CLAUDE.md's
`git commit` row it has no gate to run of its own and may commit on review
of the diff - but run full `mix quality` anyway, because the drift test
reads this file.

---
