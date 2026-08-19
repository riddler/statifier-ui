---
date: 2026-08-19
planner: Claude
git_commit: e7bc8abc78016d6477613231513f4f145fb40208
branch: sui-bpb-refresh-statifier-predicator
repository: statifier-ui
beads_issue: sui-bpb
topic: "Refreshing statifier to main and predicator to 9.0"
tags: [plan, dependencies, trace, wire-format]
status: ready
---

# Refresh statifier and predicator to 9.0 - Implementation Plan

## Overview

Move `mix.lock` from statifier `71499a5` (2026-08-16, 141 commits behind main)
to a current main commit, which drags predicator from 8.0.0 to 9.0.0 because
statifier main declares `{:predicator, "~> 9.0"}`. Absorb the three upstream
breaks the move lands on this repo, leave the gate fully green, and leave the
package emitting no normalize-error warning on an ordinary session. Bead:
sui-bpb.

This plan is grounded in
`docs/research/260819-sui-bpb-statifier-and-predicator-9-refresh-surface.md`
and, unlike that read-only research stage, in an **executed** trial bump: the
pins were moved, the suite was run, the effect stream was observed from a live
session, and `mix quality` was run to completion. Every "will fail" below is a
failure that was watched, not predicted. The trial was reverted; the tree is
clean.

## Current State Analysis

`mix.lock` pins `statifier` at git `71499a5be3cd90a683398ebaa7012c58ddb1d10d`
and `predicator` at hex `8.0.0`. `mix.exs` declares statifier as a bare git
dep with no version requirement (ADR-0004: the SHA in the lock *is* the pin
until statifier publishes to hex), so **no `mix.exs` edit is needed** - the
whole bump is a lockfile move.

The engine surface this repo consumes is narrow and concentrated in four
modules: `Trace.Normalizer` (the entire effect vocabulary),
`Trace.Manifest` (the compiled `%Statifier.Machine{}` walk), `Trace.Subscriber`
(two `Statifier.Session` calls), and `StatifierUI.Value` (a hand-written codec
that calls no predicator function - predicator appears in `lib/` only as a
value-domain *definition*).

**Observed on the trial bump** (`mix deps.update statifier` resolved statifier
to `1d0c6ba18e48cfb6bec3f866702cf15993bbdff7` and predicator to `9.0.0`;
`telemetry 1.4.2` was already in the lock via phoenix, so statifier's new
telemetry dependency adds no lock entry):

- `lib/` compiles unchanged. `mix quality`'s Format, Compile, Dependencies,
  Doctor, Credo, and Dialyzer stages **all pass** against the new engine. Only
  the Tests stage is red.
- `test/` does not compile until the struct literals are repaired: ten core
  effect payloads gained `round` and both `Trace.EntrySet` / `Trace.ExitSet`
  gained `configuration`, all in `@enforce_keys`.
- With the literals repaired, exactly **two** tests fail, both in
  `subscriber_test.exs`'s `"normalize errors"` block
  (`:275` and `:293`), because every session now opens with an
  `Effect.DatamodelInit` the normalizer rejects, inflating `stats.errors` by
  one. The gate cannot be made green by the pin move plus literal repair
  alone.
- The golden fixture is **byte-identical** under the bump. Research open
  question 4 is now answered by observation rather than reasoning:
  `record_normalize_error/3` does not touch `seq`, and all fourteen fixture
  lines are `session.start` plus `trace.*` messages whose payloads the two
  widened trace structs do not change.

The live stream, observed directly from a subscriber process:

```
{:datamodel_init, %DatamodelInit{datamodel: %{"_event" => :undefined,
   "_ioprocessors" => %{...}, "_name" => :undefined,
   "_sessionid" => "sess_probe"}, macrostep: 1, microstep: 1, round: 0}}
```

It arrives first, on every `initialize/2`, **including under `trace: false`**
(a `trace: false` session was observed delivering exactly this one message and
nothing else). `Effect.DatamodelChange` was observed only on a chart carrying
`<data>` or `<assign>`; no test in this repo starts a live session over such a
chart, so it never fires in the suite today.

## Desired End State

`mix.lock` pins statifier to a current main commit and predicator to 9.0.0. A
bare `mix quality` is green with no stage weakened and no threshold moved. A
subscriber attached to an ordinary session records `errors: 0` and logs no
warning. `docs/wire-format.md` is true about what this producer emits and
about what the engine now does. Every changed test expectation is traceable in
this document to a named upstream ADR or bead.

Verification: `mix quality` green; `grep` for `normalize error` in a test run's
output returns only the two deliberately-broken cases in
`subscriber_test.exs`'s `"normalize errors"` block.

### Key Discoveries:

- **The bump is one atomic phase, not three.** The pin move alone leaves
  `test/` uncompilable; the pin move plus literal repair leaves two tests red
  on the datamodel-init error. There is no intermediate state with a green
  gate, so per the phase-sizing rule these combine into one phase rather than
  splitting.
- **`"session.datamodel"` is already in the vocabulary.**
  `lib/statifier_ui/trace/normalizer.ex:91` lists it in `@types`, and
  `docs/wire-format.md`'s type index carries it marked reserved, precisely so
  "a future implementation of `st-oef3` has an uncontested type string to emit
  into" (`docs/wire-format.md:652-662`). Emitting it therefore changes **no**
  type string, so `test/statifier_ui/trace/wire_format_spec_test.exs:9-27` is
  untouched and ADR-0005's version stays at 1 (adding a field or a type is not
  a version bump, `docs/adr/0005-language-neutral-trace-wire-format.md:137-144`).
- **`StatifierUI.Value.encode/1` already handles the datamodel map.** It is a
  string-keyed host map whose values include the `:undefined` sentinel;
  `lib/statifier_ui/value.ex` encodes `:undefined` as `%{"$undefined" => true}`
  and recurses host maps. The prototype encoded a real session's datamodel with
  no error and no new codec code.
- **ADR-0046 lands on ten core payloads**: `Send`, `SendDelayed`, `Cancel`,
  `Invoke`, `CancelInvoke`, `Autoforward`, `Done`, `Log`, `DatamodelChange`,
  `DatamodelInit`. Verified by reflection against the bumped engine, not read
  off the diff. For *readers* it is additive, so `Normalizer`'s literal `nil`
  round at `:252, :260, :289, :295, :306, :319, :337, :345` keeps compiling and
  simply stays wrong - that is sui-t36.5's work (st-xb2b), not this bead's.
- **`configuration` on `Trace.EntrySet` / `Trace.ExitSet`** is a `MapSet`, so
  ADR-0011's rule assigns it ascending serialization when sui-t36.4 serializes
  it. `indexes` is still `[non_neg_integer()]` in engine emission order, so
  ADR-0011 survives the bump unchanged.
- **Predicator 8.0.0 to 9.0.0 is one behavioral line.** The research read the
  complete `v8.0.0..v9.0.0` `lib/` diff: three files, 30 lines, the only
  behavioral change being `duration` seeding `Duration.new()`
  (`predicator-ex/lib/predicator/evaluator.ex:1831`). Nothing renamed, removed,
  or deprecated; Elixir requirement unchanged at `~> 1.18`. **sui-bpb's third
  acceptance criterion is satisfied with nothing new to file** - see
  "Predicator review outcome" below.

## What We're NOT Doing

- **Not propagating `round` onto `effect.*` messages.** ADR-0046 makes the
  data available and `Normalizer`'s eight `nil` literals now understate it, but
  that is st-xb2b mirrored as **sui-t36.5**, which is the bead that owns the
  `effect.*` schemas. Doing it here would move golden bytes for a reason that
  is not the refresh. Phase 2 corrects the *documentation* of the upstream
  fact; the producer change waits for sui-t36.5.
- **Not serializing `configuration` on `trace.entry_set` / `trace.exit_set`.**
  st-ntf5 mirrored as **sui-t36.4** owns it.
- **Not serializing `:datamodel_change`.** It needs a new type string, a
  payload schema, and a way for a consumer to resolve its `d_index` - and
  `session.start` has no data table (see the follow-up beads below). It also
  never fires in this repo's suite, so deferring it leaves no red gate and no
  warning on any session the tests observe. The deferral is deliberate and
  bounded: a chart with `<data>` or `<assign>` driven through a live subscriber
  will log one `{:unknown_effect, :datamodel_change}` warning until the
  follow-up lands. That warning is ADR-0005's drift alarm doing its job on an
  effect we have consciously deferred with a bead behind it, which is different
  from the `:datamodel_init` case where the alarm fires on *every* session and
  would make the refresh dishonest.
- **Not consuming `attribute_locations`, `Location.resolve_span/4`,
  `Session.subscribe/3`, `Replay.run/1`, or `Session.invocations/1`.** All are
  additive and all belong to waiting beads (sui-qay, sui-czr, sui-t36.8).
- **Not adopting statifier ADR-0040 (telemetry).** ADR-0002's adopted list
  excludes it and this repo consumes no telemetry.
- **Not filing the follow-up beads.** They are proposed at the end of this
  document for the orchestrating session to file, per this bead's instructions.
- **Not touching `mix.exs`.** ADR-0004 makes the lockfile SHA the pin; the
  git dep declaration is already correct and predicator arrives transitively.
- **Not splitting Phase 1 further.** A reviewer will reasonably ask whether the
  lockfile move could be its own commit. It cannot: the trial bump showed
  `test/` failing to compile on the pin move alone, and still two tests red
  after the struct literals are repaired. Recorded here because the question is
  worth answering once rather than re-litigating at implementation time.
- **Not re-baselining anything to make a gate green.** If the fixture bytes
  move for a reason not named in Phase 1, that is upstream information to trace
  to an ADR or bead and report, never an artifact to regenerate quietly
  (ADR-0005, ADR-0011).

### Predicator review outcome (acceptance criterion 3)

sui-bpb's third acceptance criterion reads "Predicator 9.0.0 breaking changes
are reviewed and any beyond the duration key set are filed." **The review is
complete and the answer is that there is nothing to file.** The full
`v8.0.0..v9.0.0` diff of `predicator-ex/lib/` is three files and 30 lines; the
one behavioral change is the eight-key duration seeding, already tracked as
px-69c and mirrored here as sui-cw0. The four predicator-adjacent surfaces
that carry no version bead - the Provider `functions/0` behaviour (sui-t36.7),
`:undefined` / null shape inference (closed sui-t36.2), `Predicator.Types.span()`
(sui-czr), and free-standing expression evaluation (sui-bob) - were each checked
against that diff and are untouched. This paragraph is the criterion's
discharge; the implementer records it on the bead rather than filing anything
upstream.

## Implementation Approach

Two phases. Phase 1 is atomic by necessity - there is no way to split the pin
move, the struct-literal repair, and the `:datamodel_init` handling and leave
an intermediate commit with a green gate, and the phase-sizing rule says
combine rather than split in exactly that situation. Phase 2 is a
documentation-truth pass that is independently committable and cannot go red.

The `:datamodel_init` handling takes the minimum honest option. Three were
considered:

1. **Adjust the two `errors ==` assertions upward.** Rejected outright. That
   is pinning around a red gate, which this bead's own description forbids.
2. **Teach `normalize/2` a third "known but deliberately not serialized"
   outcome and skip the effect.** Rejected. It needs a new outcome in
   `normalize/2`'s contract plus a branch in `Subscriber.emit_normalized/2`,
   it throws away data the engine went to some trouble to emit, and it
   contradicts the reason `Normalizer` returns `{:error, {:unknown_effect, _}}`
   in the first place (`normalizer.ex:109-112`).
3. **Emit the already-reserved `session.datamodel` type.** Chosen. It costs one
   `decompose/1` clause and one six-line payload builder, adds no type string,
   leaves the drift test and ADR-0005's version untouched, needs no new codec
   code, and it is exactly what the reserved name was reserved *for*. Measured
   against the prototype: it turns the two red tests green and puts exactly
   three others red - the golden fixture, and two `subscriber_test.exs`
   assertions that hard-code the fourteen-message count - all three of which
   move for a reason this document names.

`session.datamodel` carries no envelope `macrostep` / `microstep` / `round`,
matching how every other `session.*` type is built (`normalizer.ex:118, :130`)
and the envelope table at `docs/wire-format.md:41-48`.

---

## Phase 1: Move the pins and absorb the three upstream breaks

### Overview

One commit: the lockfile move, the struct-literal repair the two widened
`@enforce_keys` force, the `session.datamodel` emission that keeps an ordinary
session error-free, the regenerated golden fixture, and the wire-format
schema for the type being un-reserved.

### Changes Required:

#### 1. The pin move

**File**: `mix.lock`
**Changes**: `mix deps.update statifier`. Expect statifier to move from
`71499a5be3cd90a683398ebaa7012c58ddb1d10d` to a current main commit (the trial
resolved `1d0c6ba18e48cfb6bec3f866702cf15993bbdff7`) and predicator from
`8.0.0` to `9.0.0`. `telemetry` is already present via phoenix and should not
change. `mix.exs` is **not** edited.

If the resolved commit is newer than `1d0c6ba` and the gate shows a break
beyond the three this plan names, that break is upstream information: trace it
to an upstream ADR or bead, record it in a bead note, and report it. Do not pin
to an older SHA to route around it and do not adjust an expectation to absorb
it.

#### 2. Struct literals: `round` on ten core effects (ADR-0046, st-xb2b)

**File**: `test/statifier_ui/trace/normalizer_test.exs`
**Changes**: add `round:` to every core-effect struct literal. In the
per-type tests: `:184` (`%Log{}`), `:205` (`%Done{}`), `:251` (`%Invoke{}`),
`:273` / `:377` / `:387` (`%CancelInvoke{}`), `:284` (`%Autoforward{}`),
`:300` (`%Send{}`), `:322` (`%SendDelayed{}`), `:348` (`%Cancel{}`).
`%BudgetExhausted{}` at `:217` and `:235` already carries `round`. In the
`maximal/2` coverage fixtures (`:633-781`): `:701`, `:705`, `:720`, `:735`,
`:739`, `:749`, `:764`, `:780`.

Use `round: 0` unless the surrounding test is asserting a specific counter.
`expected_keys/2` (`:783-816`) does **not** change - `round` is an envelope
field, not a payload key, and this producer still emits `nil` for it on
`effect.*` until sui-t36.5.

**File**: `test/statifier_ui/trace/subscriber_test.exs`
**Changes**: add `round:` to the four `%Log{}` literals at `:200`, `:227`,
`:272`, `:349`.

#### 3. Struct literals: `configuration` on the two set effects (st-ntf5)

**File**: `test/statifier_ui/trace/normalizer_test.exs`
**Changes**: add `configuration: MapSet.new([...])` to `%Trace.ExitSet{}` at
`:85`, `:569`, `:654` and `%Trace.EntrySet{}` at `:113`, `:668`. The value is
the configuration **after** the named set is applied. `expected_keys/2` does
not change - this producer does not serialize the field until sui-t36.4, and
the coverage test's second assertion is precisely the alarm that will fire when
it should.

#### 4. Emit `session.datamodel` for `:datamodel_init` (st-1xwh)

**File**: `lib/statifier_ui/trace/normalizer.ex`
**Changes**: add the alias, one `decompose/1` clause before the catch-all at
`:178`, and one payload builder. The `@doc` on `types/0` (`:94-101`) loses the
words "the reserved, not-yet-emitted" and says instead that
`session.datamodel` is emitted once per session from
`Statifier.Effect.DatamodelInit`. The count of 23 does not change.

```elixir
alias Statifier.Effect.DatamodelInit

# ... in the decompose/1 dispatch, before the catch-all:
defp decompose({:datamodel_init, payload}), do: datamodel_message(payload)

# The engine emits exactly one DatamodelInit per initialize/2 - first in
# the stream, unconditionally, even under `trace: false` (st-1xwh). It
# lands on the type `docs/wire-format.md` reserved for st-oef3, so the
# vocabulary does not grow and ADR-0005's version stays at 1. Like every
# other `session.*` message the envelope counters stay nil, even though
# the payload struct carries them.
@spec datamodel_message(struct()) :: {:ok, decomposed()} | {:error, term()}
defp datamodel_message(%DatamodelInit{} = p) do
  with {:ok, encoded} <- Value.encode(p.datamodel) do
    {:ok, {"session.datamodel", nil, nil, nil, %{"datamodel" => encoded}}}
  end
end
```

`:datamodel_change` is deliberately left to the catch-all at `:178`; see
"What We're NOT Doing".

**File**: `test/statifier_ui/trace/normalizer_test.exs`
**Changes**: add a `session.datamodel` test alongside the other `session.*`
tests, covering a datamodel map that carries `:undefined` (which must encode
as `%{"$undefined" => true}`, ADR-0005) and a nested host map. Do **not** add
`{:datamodel_init, DatamodelInit}` to `@coverage` (`:26-45`) - that table's
comment scopes it to the nine trace payloads and nine core effects, and
`expected_keys/2` is organized around `effect.*` / `trace.*` payloads.

#### 5. The messages that shift because of change 4

**File**: `test/support/trace/two_state.jsonl`
**Changes**: regenerate. The diff is exactly one inserted `session.datamodel`
line at `seq: 1` and a `+1` renumbering of the thirteen `trace.*` lines that
follow. **Every other byte on every line must be unchanged** - if any
`macrostep`, `round`, `indexes`, or `configuration` value moves, stop: that is
an engine behavior change to trace, not part of this refresh (ADR-0011).

**File**: `test/statifier_ui/trace/golden_trace_test.exs`
**Changes**: `@full_seq 14` becomes `15`. Without this the test can race the
last message.

**File**: `test/statifier_ui/trace/subscriber_test.exs`
**Changes**: `@full_seq 14` becomes `15` and its comment (`:25-28`) updates.
The attach-path assertion at `:47` gains the new message:
`[%{type: "session.start", seq: 0}, %{type: "session.datamodel", seq: 1},
%{type: "trace.entry_set", seq: 2} = burst | _]`, with its comment
(`:44-46`) updated. Re-check the mid-stream-listener offsets at `:119-131`,
which use a literal `5` for "the initialize burst has flowed by": the burst is
now six messages, not five.

#### 6. Un-reserve the type in the spec

**File**: `docs/wire-format.md`
**Changes**: replace the `session.datamodel` paragraph under "Reserved and not
yet emitted" (`:652-662`) with a real `### session.datamodel` schema section
alongside the other `session.*` types: emitted exactly once per session, first
on the stream, from statifier's `Effect.DatamodelInit` (st-1xwh); one payload
field `datamodel`, an object, always present, its values encoded by the
`$`-tagged value discipline so an unassigned `<data>` element appears as
`{"$undefined": true}`. Note that it is emitted even when tracing is disabled.
If "Reserved and not yet emitted" is left with no entries, remove the heading.
Update the worked-example JSON block to the regenerated fixture bytes.

Three further passages in the same file say "reserved" and must move with it:

- The `## Type index` preamble (`:729-737`) calls `session.datamodel` "the
  reserved `session.datamodel`" and then claims it "is excluded from that
  equality on the emitted side, since this document states above that no
  producer emits it yet." **That second sentence is already false today** -
  `Normalizer.types/0` includes `session.datamodel` (`normalizer.ex:91`) and
  `wire_format_spec_test.exs` asserts plain set equality with no exclusion.
  Delete the exclusion sentence and drop "reserved" from the count sentence.
  The row count stays 23.
- The type index **row** for `session.datamodel` keeps existing - deleting it
  turns the drift test red - but its "Emitted when" cell becomes real: a
  session's datamodel is initialized.
- The References list at the bottom (`:778-779`) has an `st-oef3` entry reading
  "the upstream gap behind `session.datamodel` being reserved rather than
  emitted". The gap is closed; either drop the entry or restate it as the
  upstream bead this type's payload comes from.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` (full) is green, with the Tests stage reporting 0 failures
      and coverage at or above the 80% floor in `coveralls.json`
- [x] No stage newly reports `○`; the only two skipped stages are Gettext and
      Sobelow, per CLAUDE.md
- [x] `grep '"statifier"' mix.lock` no longer contains
      `71499a5be3cd90a683398ebaa7012c58ddb1d10d`, and
      `grep '"predicator"' mix.lock` contains `"9.0.0"`
- [x] `git diff --stat mix.exs` is empty
- [x] `mix test test/statifier_ui/trace/wire_format_spec_test.exs` passes with
      no edit to that file, and the type index still has 23 rows:
      ``grep -c '^| `[a-z._]*` |' docs/wire-format.md`` returns 23 (it
      returns 23 today, verified before this plan was written)
- [x] `mix test test/statifier_ui/trace/golden_trace_test.exs` passes, and
      `git diff --numstat test/support/trace/two_state.jsonl` reports exactly
      `14  13` - fourteen lines added, thirteen removed, which is the one
      inserted `session.datamodel` line plus the thirteen renumbered `trace.*`
      lines and nothing else. Any other pair of numbers means a byte moved
      that this plan did not predict; stop and trace it.
- [x] `mix test 2>&1 | grep -c 'datamodel_init'` returns `0` - no session in
      the suite logs a normalize error for the effect this phase handles

#### Manual Verification:
- [ ] Every changed test expectation in the diff is traceable to ADR-0046 /
      st-xb2b, st-ntf5, or st-1xwh, and no expectation was widened merely to
      absorb a failure
- [ ] The `session.datamodel` payload for a real chart with a `<data>` element
      is readable and correct: system variables present, an unassigned `<data>`
      appearing as `{"$undefined": true}`
- [ ] The regenerated fixture's non-`seq` bytes are unchanged from the
      committed version, line for line
- [ ] `docs/wire-format.md`'s new section reads as a specification a second
      interpreter could implement from, not as a changelog entry

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the bare `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before moving
to the next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Phase 2: Correct the two now-false engine claims in the spec

### Overview

Two passages in `docs/wire-format.md` assert upstream gaps that the refresh
closed. Neither is caught by the drift test, which compares only the type
index table, so a second interpreter reading the spec today would be actively
misinstructed. This phase is prose only and cannot make the gate red, which is
why it is separable from Phase 1 rather than folded into it.

### Changes Required:

#### 1. `effect.*` and `round` (ADR-0046, st-nbmj closed)

**File**: `docs/wire-format.md`
**Changes**: `:57-65` states "no core effect payload stamps `round` - `round`
is a trace-only counter today, upstream tracking issue `st-nbmj`". That is
false as of ADR-0046: ten core payloads now carry `round`, and effects emitted
before the fold carry `round: 0`. Rewrite the paragraph to say that the engine
now stamps `round` on every core effect, that **this producer** does not yet
propagate it onto `effect.*` messages (tracked as sui-t36.5), and that when it
does the `effect.*` schemas gain the key as an additive change under the
versioning rule - not a version bump. Keep the envelope table at `:41-48`
accurate to what this producer emits today (`round` on `trace.*` only) and say
so explicitly rather than leaving the reader to reconcile the two.

#### 2. Delivery ordering and halt (ADR-0044, st-r6l9 closed)

**File**: `docs/wire-format.md`
**Changes**: `:100-114` warns that live delivery may violate `(macrostep,
round)` order and may deliver `trace.*` after `session.halted`, and instructs
consumers never to treat halt as end-of-stream. ADR-0044 closed both: re-entry
effects are enqueued and FIFO-drained after the outer batch, arrival order is
now non-decreasing in `(macrostep, round)` across a run, and `{:halted,
reason}` is promised as end-of-stream. Rewrite to record the guarantee.

Two things must survive the rewrite. First, the advice to reconstruct a
timeline from `(macrostep, round)` rather than arrival order stays good advice
and stays. Second, **the cross-session paragraph at `:92-98` is unaffected** -
ADR-0044 says nothing about how two sessions interleave on a shared channel,
and that is the paragraph sui-t36.8 will lean on.

Also record ADR-0044's new uniqueness key while the section is open: more than
one `trace.macrostep_stable` per macrostep is now explicitly allowed, exactly
one per `(macrostep, round)`, the last-arriving being that macrostep's
quiescence.

Two other passages repeat the closed claim and must move with it:

- The `### session.halted` schema (`:622-624`) says "Halting a session does not
  stop effect delivery: `trace.*` messages may still arrive after
  `session.halted` ... A consumer must not treat this message as
  end-of-stream." ADR-0044 reverses this. Rewrite it to say halt is terminal
  for that session id - and, because ADR-0050 lets a subscriber observe an
  invoke tree, say explicitly that it is terminal **per session id**, not per
  mailbox.
- The References list (`:776-777`) carries an `st-r6l9` entry reading "the
  upstream reordering seam behind the ordering warning above". Restate it as
  the bead ADR-0044 closed, or drop it.

The `st-nbmj` References entry (`:774-775`, "the upstream gap behind `effect.*`
messages carrying no `round`") belongs to change 1 above and moves with it.

#### 3. The test comment that cites the closed gap

**File**: `test/statifier_ui/trace/golden_trace_test.exs`
**Changes**: the moduledoc explains the chart was chosen "to avoid the
`st-r6l9` reordering seam". Note that ADR-0044 closed the seam, and that the
chart choice now buys determinism rather than order-safety. Do not change the
chart or the test.

### Success Criteria:

#### Automated Verification:
- [x] `mix quality` (full) is green
- [x] `mix test test/statifier_ui/trace/wire_format_spec_test.exs` passes -
      the type index table's rows are untouched by this phase
- [x] `git diff --stat` for this phase touches only `docs/wire-format.md` and
      `test/statifier_ui/trace/golden_trace_test.exs`

#### Manual Verification:
- [ ] Neither rewritten passage contradicts what Phase 1's producer actually
      emits; where the spec describes an engine capability this producer has
      not yet propagated, it says which bead owns the propagation
- [ ] The cross-session interleaving paragraph is unchanged
- [ ] Every surviving `st-r6l9` and `st-nbmj` mention (find them with
      `grep -n 'st-r6l9\|st-nbmj' docs/wire-format.md`) reads as a historical
      reference to a **closed** gap, not as an assertion that the gap is still
      open. This is a manual check on purpose: the grep cannot tell a correct
      backward reference from a stale claim, and a plain "no matches" would be
      the wrong target - the References list legitimately keeps naming these
      beads.
- [ ] No regressions in related features: the spec still reads as one document,
      not as a document with two patches in it

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the bare `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
finishing. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_ui/trace/normalizer_test.exs` - the `@coverage` table is the
  designed alarm for a renamed or added engine field and must keep passing
  without its `expected_keys/2` being relaxed. A new `session.datamodel` test
  covers the `:undefined` sentinel inside the datamodel map and a nested host
  map, which is the only genuinely new encoding path this bead adds.
- `test/statifier_ui/trace/subscriber_test.exs` - the `"normalize errors"`
  block is the direct evidence that an ordinary session is error-free: its two
  tests assert `errors == 1` and `errors == 2` for *deliberately* broken
  effects, so they are only green when nothing else is erroring. That property
  is what makes them the right regression test for this bead, and it is why
  the trial bump's two failures were the signal that the pin move alone is not
  enough.
- `test/statifier_ui/trace/golden_trace_test.exs` - byte equality plus
  run-to-run identity, over a real session. This is ADR-0005's conformance
  mechanism and the one test that would catch an engine behavior change the
  struct-literal repairs would otherwise mask.
- `test/statifier_ui/trace/wire_format_spec_test.exs` - must pass **unedited**
  in both phases. If it goes red, the vocabulary changed, and that is a
  direction-level question, not a plan edit.

### Manual Testing Steps:

1. After the pin move, before any other edit, run `mix deps.get` and confirm
   `mix.lock` names predicator `9.0.0` and a statifier SHA other than
   `71499a5`.
2. Run `mix test test/statifier_ui/trace/golden_trace_test.exs` with the pins
   moved but before change 4 lands, and confirm it **passes** - that is the
   observation that the fixture bytes did not move for an upstream reason. Any
   later fixture diff is then attributable to change 4 alone.
3. Start a session over a chart carrying `<datamodel><data id="x" expr="1"/>`
   and an `<onentry><assign location="x" expr="2"/>`, attach a subscriber, and
   read `Subscriber.messages/1`. Confirm the `session.datamodel` message is
   present and correct, and confirm the single expected
   `{:unknown_effect, :datamodel_change}` warning - the bounded, named cost of
   the deferral.
4. Read the full `mix quality` output rather than a summary line, and confirm
   the `○` lines are exactly Gettext and Sobelow.

## Proposed follow-up beads

**Not filed by this plan.** The orchestrating session files these; sui-bpb does
not depend on any of them.

### 1. Serialize `:datamodel_change` onto the wire format

**Area**: `area:wire-format`
**Mirrors**: st-oef3

The engine now emits `Statifier.Effect.DatamodelChange` on every `<data>`
initialization and every `<assign>`, carrying `location_path`
(`Predicator.ContextLocation.location_path()`, a `[binary() | integer()]`),
`location_source`, `new_value`, `prior_value` (either may be `:undefined`),
mutually exclusive `d_index` / `c_index`, an `owner` widened to
`Content.owner() | {:invoke, non_neg_integer(), non_neg_integer()}`, and the
ADR-0046 counters. sui-bpb deliberately left it falling through
`Normalizer.decompose/1`'s catch-all, so a chart with a datamodel logs one
`{:unknown_effect, :datamodel_change}` warning per subscriber. This bead gives
it a type string (`session.datamodel` is now taken by `DatamodelInit`, so this
needs a new one - likely `effect.datamodel_change`), a payload schema in
`docs/wire-format.md` including its own type index row, a `@coverage` entry,
and a decision on how `location_path`'s mixed string/integer segments
serialize. Adding a type is additive under ADR-0005 and not a version bump.
Depends on bead 2 below: a consumer receiving a `d_index` cannot resolve it
today.

### 2. `session.start` gains a `data` identity table from `Machine.data/2`

**Area**: `area:wire-format`

`<data>` elements now carry a compiler-assigned dense document-order index
resolved through `Statifier.Machine.data/2` to a `%Statifier.Machine.Data{}`
carrying `location` and `value_location`. That is a **fourth** identity
resolver alongside `at/2`, `transition/2`, and `content/2`, and
`StatifierUI.Trace.Manifest` (`lib/statifier_ui/trace/manifest.ex:77-94`) builds
tables for only the first three. Until `session.start` carries a `data` table,
`d_index` is an unresolvable integer for any consumer, which is what blocks
bead 1. This bead adds the table alongside `states`, `transitions`, and
`contents`, its `docs/wire-format.md` schema, and the manifest test coverage.
It moves the golden fixture's `session.start` line, deliberately and
traceably.

## Open questions returned to the orchestrator

Neither blocks this plan; both are tracker hygiene rather than implementation
decisions.

1. **sui-t36.6 and sui-t36.7 do not depend on sui-bpb** even though the other
   four `sui-t36.x` children do. The research could not determine whether that
   is deliberate. Nothing in this refresh settles it, and it does not affect
   this bead's execution.
2. **st-xbaz (the initialize-time `<invoke>` deadlock, GAP 5 of the
   260816 spike)** was not verified as open or closed in the commit range, and
   this plan did not verify it either - no chart exercised here uses
   `<invoke>`. It is an upstream bead in any case, and ADR-0002 keeps it there.

## References

- Source document:
  `docs/research/260819-sui-bpb-statifier-and-predicator-9-refresh-surface.md`
- Related ADRs: `docs/adr/0002-adopt-upstream-decisions-by-reference.md`
  (upstream ADRs adopted as they stand; engine gaps are `st-`/`px-` beads,
  never a patch from here), `docs/adr/0004-one-package-with-optional-integrations.md`
  (statifier is a git dep, the lock SHA is the pin),
  `docs/adr/0005-language-neutral-trace-wire-format.md` (must-ignore-unknown,
  so adding a type or field is not a version bump; the golden trace is the
  drift alarm), `docs/adr/0010-cross-repo-tracker-authority-and-mirrors.md`
  (this repo owns "when its dependency pins move"),
  `docs/adr/0011-exit-and-entry-sets-are-sequences.md` (`indexes` keeps engine
  order; a `MapSet` serializes ascending; a moved fixture order is a behavior
  change to review, never a re-baseline)
- Upstream records this plan's expectation changes trace to: statifier ADR-0046
  and st-xb2b (`round` on core effects), st-ntf5 (`configuration` on the two
  set effects), st-1xwh (`DatamodelInit`), st-oef3 (`DatamodelChange`),
  statifier ADR-0044 and st-r6l9 (monotone delivery, halt terminal), px-69c
  (eight-key durations)
- Similar implementation:
  `docs/plans/260817-sui-t36.3-session-subscriber-and-trace-normalizer.md` -
  the plan that built the normalizer, subscriber, manifest, and golden fixture
  against the pinned engine
- Prior research: `docs/research/260816-sui-t36.1-trace-coverage-spike.md` -
  the eight engine gaps, six of which this refresh closes
- Bead: sui-bpb

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Every changed test expectation in the diff is traceable to ADR-0046 /
      st-xb2b, st-ntf5, or st-1xwh, and no expectation was widened merely to
      absorb a failure
- [ ] The `session.datamodel` payload for a real chart with a `<data>` element
      is readable and correct: system variables present, an unassigned `<data>`
      appearing as `{"$undefined": true}`
- [ ] The regenerated fixture's non-`seq` bytes are unchanged from the
      committed version, line for line
- [ ] `docs/wire-format.md`'s new section reads as a specification a second
      interpreter could implement from, not as a changelog entry

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the bare `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before moving
to the next phase. In looped (`--loop`) execution, this phase's Automated
Verification gates advancement automatically (via `/wurk:commit --auto`), and
Manual Verification items are deferred and surfaced once at the end instead of
blocking here.

---

### Phase 2

- [ ] Neither rewritten passage contradicts what Phase 1's producer actually
      emits; where the spec describes an engine capability this producer has
      not yet propagated, it says which bead owns the propagation
- [ ] The cross-session interleaving paragraph is unchanged
- [ ] Every surviving `st-r6l9` and `st-nbmj` mention (find them with
      `grep -n 'st-r6l9\|st-nbmj' docs/wire-format.md`) reads as a historical
      reference to a **closed** gap, not as an assertion that the gap is still
      open. This is a manual check on purpose: the grep cannot tell a correct
      backward reference from a stale claim, and a plain "no matches" would be
      the wrong target - the References list legitimately keeps naming these
      beads.
- [ ] No regressions in related features: the spec still reads as one document,
      not as a document with two patches in it

**Implementation Note**: Use `mix quality --profile loop` between edits while
iterating; run the bare `mix quality` as the phase gate. In interactive
execution, pause here for the human to confirm the manual testing before
finishing. In looped (`--loop`) execution, this phase's Automated Verification
gates advancement automatically (via `/wurk:commit --auto`), and Manual
Verification items are deferred and surfaced once at the end instead of
blocking here.

---
