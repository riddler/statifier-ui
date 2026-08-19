---
date: 2026-08-19T04:20:14-0600
researcher: Claude
git_commit: e7bc8abc78016d6477613231513f4f145fb40208
branch: sui-bpb-refresh-statifier-predicator
repository: statifier-ui
beads_issue: sui-bpb
topic: "What refreshing statifier to main and predicator to 9.0 changes for statifier-ui"
tags: [research, codebase, dependencies, trace, wire-format]
status: complete
last_updated: 2026-08-19
last_updated_by: Claude
---

# Research: What refreshing statifier to main and predicator to 9.0 changes for statifier-ui

**Date**: 2026-08-19T04:20:14-0600
**Git Commit**: e7bc8abc78016d6477613231513f4f145fb40208
**Branch**: sui-bpb-refresh-statifier-predicator
**Bead**: sui-bpb

## Research Question

`mix.lock` pins statifier at git commit `71499a5` (2026-08-16), 141 commits
behind statifier-ex main, and pins predicator 8.0.0 transitively. statifier
main now requires `{:predicator, "~> 9.0"}`, so refreshing statifier drags
predicator across a major version in the same step.

Document, as it exists today:

1. What this repo consumes from statifier and predicator - every call site,
   every struct field pattern-matched, every trace effect shape the
   normalizer, golden-trace, and wire-format tests assert on.
2. The upstream breaking surface, read rather than assumed, in both repos.
3. Which of this repo's call sites and test expectations each upstream change
   lands on, and which downstream beads each unblocks.
4. Anything in the predicator 9.0 breaking surface not already covered by an
   existing `sui-` bead.

## Summary

Both sibling checkouts are present and current: `/Users/johnnyt/repos/github/statifier-ex`
at `f7fcaa8` (main) and `/Users/johnnyt/repos/github/predicator-ex` at
`cdf9b46` ("Releases v9.0.0"). Nothing in this document is inferred from
hex.pm metadata or guessed; every claim below was read from those trees.

**The two halves of this bump are wildly asymmetric.**

The predicator half is nearly empty. The complete `lib/` diff between tags
`v8.0.0` and `v9.0.0` is three files, 30 lines, of which exactly one line is
behavioral: the `duration` opcode now seeds its accumulator with
`Duration.new()` so every evaluated duration carries all eight unit keys
(`predicator-ex/lib/predicator/evaluator.ex:1831`). That is bead px-69c,
already mirrored here as sui-cw0. There is no second behavioral break. No
module was renamed, no public function added or removed, no return tuple or
error struct field changed, no `@deprecated` anywhere in `lib/`, and the
Elixir requirement stays `~> 1.18`. This directly answers sui-bpb's third
acceptance criterion: the review was done, and nothing beyond the duration
key set needs filing. The one caveat worth recording is that this repo pins
exactly `8.0.0`, so `v8.0.0..v9.0.0` is the right and complete range - 8.0.0
itself carried much larger breaks (`{:error, binary()}` widening to
`%Predicator.Errors.ParseError{}`, and `:span` on every parse error), but
this repo is already past them.

The statifier half is large: 141 commits, 105 files under `lib/`,
+5267/-1236, twelve new ADRs (0040 through 0051) and six amended. Most of it
is additive, and most of the additive part is precisely the work the six
downstream beads are waiting for. But three changes are hard breaks against
code or tests in this repo, and one of them is not covered by any existing
`sui-` bead.

**The single largest finding is not on sui-bpb's list.** statifier's core
effect vocabulary grew from nine tags to eleven: `:datamodel_change` (st-oef3)
and `:datamodel_init` (st-1xwh) are new. `Statifier.Effect.DatamodelInit` is
emitted **once per `initialize/2`, unconditionally, first in the stream, at
`round: 0`, and under `trace: false` as well**
(`statifier-ex/lib/statifier/effect.ex:35`). This repo's
`StatifierUI.Trace.Normalizer.decompose/1` enumerates exactly ten tags and
answers `{:error, {:unknown_effect, tag}}` to anything else
([`lib/statifier_ui/trace/normalizer.ex:168-179`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L168-L179)). So after the refresh, every
single session this package observes opens with an effect the normalizer
rejects. The blast radius is bounded and precisely knowable, because
`record_normalize_error/3` does not increment `seq`
([`lib/statifier_ui/trace/subscriber.ex:392-405`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L392-L405) versus `:407-412`): the
golden fixture's fourteen lines and their `seq` numbering stay byte-identical,
but `state.errors` becomes 1 on every run and a `Logger.warning` fires. Tests
asserting a clean error count break; the golden bytes do not.

The three hard breaks, in order of how early they bite:

1. **`round` on every core effect (ADR-0046, st-xb2b).** Ten core effect
   payloads gained `round` in `@enforce_keys`, `Log` among them. Every
   struct literal this repo's tests build for a core effect now raises at
   construction.
2. **`configuration` on `Trace.EntrySet` / `Trace.ExitSet` (st-ntf5).** Same
   mechanism - the field joined `@enforce_keys`, so the test literals break.
   Readers are unaffected.
3. **The two new core effect tags**, described above.

Everything else in the statifier delta is additive, behavioral-but-untested
here, or lands on code this repo does not have yet. Notably, three of this
repo's documented upstream gaps have closed and their prose in
`docs/wire-format.md` is now false: the `st-nbmj` "`effect.*` carries no
`round`" paragraph, the `st-r6l9` "never treat halt as end-of-stream"
ordering warning, and the `st-oef3` "`session.datamodel` reserved, not
emitted" note.

## Detailed Findings

### What this repo consumes today

The engine surface is narrow and concentrated in four modules.

**`StatifierUI.Trace.Normalizer`** (`lib/statifier_ui/trace/normalizer.ex`)
is the whole effect-facing surface. It aliases ten `Statifier.Effect` modules
plus `Statifier.Event` and `Statifier.Event.Cause`
([`lib/statifier_ui/trace/normalizer.ex:37-48`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L37-L48)), dispatches on ten core tags
([`lib/statifier_ui/trace/normalizer.ex:168-179`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L168-L179)), pattern-matches the nine
`Statifier.Effect.Trace.*` structs by name
([`lib/statifier_ui/trace/normalizer.ex:184-241`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L184-L241)), and destructures
`Cause.origin()`'s eight tagged-tuple variants
([`lib/statifier_ui/trace/normalizer.ex:419-452`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L419-L452)) and `Content.owner()`'s five
([`lib/statifier_ui/trace/normalizer.ex:456-474`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L456-L474)).

The counter handling is the part the refresh moves. Trace payloads are read
for `macrostep`, `microstep`, and `round`
([`lib/statifier_ui/trace/normalizer.ex:187-237`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L187-L237)), but core effects are built
with a literal `nil` in the fourth position because no core effect except
`BudgetExhausted` carried `round`
([`lib/statifier_ui/trace/normalizer.ex:252`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L252),
[`lib/statifier_ui/trace/normalizer.ex:260`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L260),
[`lib/statifier_ui/trace/normalizer.ex:289`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L289),
[`lib/statifier_ui/trace/normalizer.ex:295`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L295),
[`lib/statifier_ui/trace/normalizer.ex:306`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L306),
[`lib/statifier_ui/trace/normalizer.ex:319`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L319),
[`lib/statifier_ui/trace/normalizer.ex:337`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L337),
[`lib/statifier_ui/trace/normalizer.ex:345`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L345);
`BudgetExhausted` at [`lib/statifier_ui/trace/normalizer.ex:272`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L272)).
`configuration` is always read off a `MapSet` and reduced to a sorted list
([`lib/statifier_ui/trace/normalizer.ex:488-489`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L488-L489)).

**`StatifierUI.Trace.Manifest`** (`lib/statifier_ui/trace/manifest.ex`) is the
only consumer of the compiled machine. It walks `%Statifier.Machine{}`'s
`states`, `transitions`, and `contents` tuples
([`lib/statifier_ui/trace/manifest.ex:111`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L111),
[`lib/statifier_ui/trace/manifest.ex:133`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L133),
[`lib/statifier_ui/trace/manifest.ex:156`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L156)) and reads seven fields off
`Machine.State` ([`lib/statifier_ui/trace/manifest.ex:118-128`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L118-L128)), eight off
`Machine.Transition` ([`lib/statifier_ui/trace/manifest.ex:140-151`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L140-L151)), and
`c_index` plus a location off each content node, with the documented
`Content.Script.node_location` fallback
([`lib/statifier_ui/trace/manifest.ex:187-188`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L187-L188)).

**`StatifierUI.Trace.Subscriber`** (`lib/statifier_ui/trace/subscriber.ex`)
touches the live session at exactly two points:
`Statifier.Session.subscribe(session_pid, self())`
([`lib/statifier_ui/trace/subscriber.ex:235`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L235)) and
`Statifier.Session.unsubscribe/2` ([`lib/statifier_ui/trace/subscriber.ex:257`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L257)).
It demuxes on the envelope's session id already
([`lib/statifier_ui/trace/subscriber.ex:278-292`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L278-L292)). **No `Replay` module and no
`record: true` option is referenced anywhere in `lib/` or `test/`.**

**`StatifierUI.Value`** (`lib/statifier_ui/value.ex`) is the entire predicator
surface in `lib/`. It is a hand-written codec, not a call into predicator: the
eight `@duration_units` are declared locally
([`lib/statifier_ui/value.ex:36-45`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/value.ex#L36-L45)), `encode_duration/1` always emits all
eight, filling absent units with `0` ([`lib/statifier_ui/value.ex:174-179`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/value.ex#L174-L179)), and
`decode_duration/1` fills all eight regardless of which subset arrived
([`lib/statifier_ui/value.ex:181-196`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/value.ex#L181-L196)). The only direct predicator calls in the
whole repo are two test lines: `Predicator.evaluate("3d8h")` and
`Predicator.evaluate("2w")` ([`test/statifier_ui/value_test.exs:89`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/value_test.exs#L89),
[`test/statifier_ui/value_test.exs:98`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/value_test.exs#L98)).

**The test expectations that hard-code an upstream shape** are four:

- The coverage block in [`test/statifier_ui/trace/normalizer_test.exs:604-627`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L604-L627)
  drives a `@coverage` table of eighteen `{tag, payload_module}` pairs
  ([`test/statifier_ui/trace/normalizer_test.exs:26-45`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L26-L45)) through a `maximal/2`
  struct literal per pair
  ([`test/statifier_ui/trace/normalizer_test.exs:633-781`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L633-L781)), then asserts each
  type's payload key set against a hard-coded `expected_keys/2`
  ([`test/statifier_ui/trace/normalizer_test.exs:783-816`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L783-L816)). This is the
  designed alarm for a renamed or added engine field, and it is the thing the
  refresh trips first.
- [`test/statifier_ui/trace/golden_trace_test.exs:47-56`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/golden_trace_test.exs#L47-L56) asserts byte equality
  against `test/support/trace/two_state.jsonl` twice over, plus run-to-run
  identity.
- [`test/statifier_ui/trace/wire_format_spec_test.exs:9-27`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/wire_format_spec_test.exs#L9-L27) asserts
  `Normalizer.types/0` equals the type table parsed out of
  `docs/wire-format.md`.
- `test/statifier_ui/trace/subscriber_test.exs` builds `%Log{}` literals at
  [`test/statifier_ui/trace/subscriber_test.exs:200`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/subscriber_test.exs#L200),
  [`test/statifier_ui/trace/subscriber_test.exs:227`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/subscriber_test.exs#L227),
  [`test/statifier_ui/trace/subscriber_test.exs:271-272`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/subscriber_test.exs#L271-L272),
  [`test/statifier_ui/trace/subscriber_test.exs:300`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/subscriber_test.exs#L300), and
  [`test/statifier_ui/trace/subscriber_test.exs:349`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/subscriber_test.exs#L349).

### The predicator 8.0.0 to 9.0.0 surface

Read from `predicator-ex` at tags `v8.0.0` and `v9.0.0`.

**Change 1, the only behavioral one (px-69c).** In 8.0.0 the `duration` opcode
seeded a seven-key literal and inserted `:milliseconds` via `Map.put/3` only
when the expression named a ms-family unit, so the key set varied with the
expression (`predicator-ex/lib/predicator/evaluator.ex:1822` at v8.0.0). In
9.0.0 it seeds `Duration.new()`
(`predicator-ex/lib/predicator/evaluator.ex:1831`), giving all eight keys on
every path. `Predicator.Types` always declared eight
(`predicator-ex/lib/predicator/types.ex:37-46`); only the runtime disagreed.
Numeric meaning is unchanged, since an absent `:milliseconds` always meant `0`.

**Change 2, a semantic reclassification with no code change.**
`Predicator.Conformance.Values` still declares seven `@duration_keys`
(`predicator-ex/lib/predicator/conformance/values.ex:39`) and still emits
`"milliseconds"` only when non-zero
(`predicator-ex/lib/predicator/conformance/values.ex:181-189`). The wire bytes
are identical across the two versions; what changed is what those bytes mean.
This is worth recording because **this repo's codec deliberately differs**:
ADR-0005 and `StatifierUI.Value.encode_duration/1` always emit all eight keys
([`lib/statifier_ui/value.ex:174-179`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/value.ex#L174-L179)), where predicator's own conformance
codec compacts a zero `milliseconds` away. Both are self-consistent; they are
not byte-compatible with each other. This is a pre-existing divergence the
refresh does not create, and ADR-0005 is this repo's governing record for it.

**Change 3.** `conformance/manifest.json`'s `corpus_hash` moved, caused by two
`notes` string rewrites only - no `expected_result` or `instructions` value
moved. This repo does not vendor or pin the corpus, so it is inert here.

**Explicit negatives, checked rather than assumed**: `mix.exs` is
`elixir: "~> 1.18"` at both tags, the only `mix.exs` change in the range being
the version string. No UPGRADING guide exists. No ADR was added under
`docs/adr/` in the range. The top-level `Predicator` module, parser, lexer,
context, and `Predicator.Errors.*` are untouched. Date, datetime, decimal,
list, and map representations are unchanged. ISA version stays 6.

### The statifier 71499a5 to f7fcaa8 surface

`mix.exs` on main declares `{:predicator, "~> 9.0"}` and, new in this range,
`{:telemetry, "~> 1.3"}` (`statifier-ex/mix.exs:41-43`). At 71499a5 it was
`~> 8.0` with no telemetry dependency, so the refresh also adds `telemetry` to
this repo's lock transitively.

#### Hard breaks against this repo

**ADR-0046 / st-xb2b: `round` on every core effect.** Ten payloads gained
`round :: non_neg_integer()` in both `@enforce_keys` and `@type t`:
`Send` (`statifier-ex/lib/statifier/effect/send.ex:48`), `SendDelayed`
(`statifier-ex/lib/statifier/effect/send_delayed.ex:25`), `Cancel`
(`statifier-ex/lib/statifier/effect/cancel.ex:20`), `Invoke`
(`statifier-ex/lib/statifier/effect/invoke.ex:46`), `CancelInvoke`
(`statifier-ex/lib/statifier/effect/cancel_invoke.ex:29`), `Autoforward`
(`statifier-ex/lib/statifier/effect/autoforward.ex:35`), `Done`
(`statifier-ex/lib/statifier/effect/done.ex:21`), `Log`
(`statifier-ex/lib/statifier/effect/log.ex:23`), `DatamodelChange`
(`statifier-ex/lib/statifier/effect/datamodel_change.ex:51`), and
`DatamodelInit` (`statifier-ex/lib/statifier/effect/datamodel_init.ex:37`).
Effects emitted before the fold carry `round: 0`. ADR-0020's paragraph saying
other core effects do not gain `round` is withdrawn.

For readers this is additive, so `Normalizer`'s `nil` literals keep compiling
and simply stay wrong. For struct builders it is a break: the `maximal/2`
literals at [`test/statifier_ui/trace/normalizer_test.exs:633-781`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L633-L781) and the
`%Log{}` literals in `test/statifier_ui/trace/subscriber_test.exs` raise on
construction.

**st-ntf5: `configuration` on `Trace.EntrySet` and `Trace.ExitSet`.** Both
structs now enforce `[:indexes, :configuration, :macrostep, :microstep, :round]`
(`statifier-ex/lib/statifier/effect/trace/entry_set.ex:23-31`,
`statifier-ex/lib/statifier/effect/trace/exit_set.ex:36-44`). `configuration`
is a `MapSet.t(non_neg_integer())` holding the full configuration **after** the
named set is applied - the only post-mutation field on a trace effect, newly
sanctioned by the st-xsb1 amendment to statifier ADR-0012. At
`exit_interpreter/1` it is a true `MapSet.new()`, not a missing value.

This settles the ordering question ADR-0011 turns on, in ADR-0011's favour:
`indexes` remains `[non_neg_integer()]`, a list in engine emission order, and
is unchanged in the range. The new field is the `MapSet`, and it is a genuine
set, so ADR-0011's rule assigns it ascending serialization. Same break
mechanism as above for the test literals.

**st-oef3 and st-1xwh: two new core effect tags.** The `Statifier.Effect.core()`
union grew from nine members to eleven
(`statifier-ex/lib/statifier/effect.ex:34-35`, `:48`).
`Statifier.Effect.DatamodelChange` carries `location_path`
(`Predicator.ContextLocation.location_path()`, a `[binary() | integer()]`),
`location_source`, `new_value`, `prior_value` (either may be `:undefined`),
`d_index`, `c_index` (mutually exclusive), `owner` - widened to
`Content.owner() | {:invoke, non_neg_integer(), non_neg_integer()}` - and the
counters. `Statifier.Effect.DatamodelInit` carries `datamodel :: map()` and is
emitted once per `initialize/2`, unconditionally, first in the stream, at
`round: 0`, from `Statifier.Interpreter.Datamodel.initialize/1`.

Against [`lib/statifier_ui/trace/normalizer.ex:178`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L178), both fall through to
`{:error, {:unknown_effect, tag}}`. Because
[`lib/statifier_ui/trace/subscriber.ex:392-405`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L392-L405) records the error without
touching `seq`, the observable damage is confined: `state.errors` becomes 1
per session and a warning is logged. The golden fixture's fourteen lines are
all `trace.*` and already carry `round`
(`test/support/trace/two_state.jsonl`), so the fixture bytes themselves do not
move from either this change or ADR-0046.

Also in this group: `:send`, `:send_delayed`, and `:cancel` were documented as
"not yet produced" at 71499a5 and are now actually produced. The normalizer
already handles all three.

#### Additive, and lands on a waiting bead

**st-9i5r: `attribute_locations`.** `Machine.Transition`
(`statifier-ex/lib/statifier/machine/transition.ex:83`, type at `:96`) and
`Machine.State` (`statifier-ex/lib/statifier/machine/state.ex:92`, type at
`:115`) each gained `attribute_locations: %{}`, typed
`Statifier.Document.attribute_locations()`, that is
`%{optional(atom()) => Location.t()}`
(`statifier-ex/lib/statifier/document.ex:97`). The key-presence contract is
the load-bearing part sui-qay cares about: a key exists only for an attribute
the author actually wrote, so `Map.has_key?(transition.attribute_locations, :type)`
answers "was `type` authored or defaulted", which the compiled value cannot.
State index 0 carries the `<scxml>` element's own attributes; the synthesized
initial transition carries `%{}`. `cond_location` stays; prefer
`attribute_locations[:cond]` for new work. This is the data
[`lib/statifier_ui/trace/manifest.ex:140-151`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L140-L151) does not yet read, and it closes
the caveat at [`docs/wire-format.md:328-338`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L328-L338). **Unblocks sui-qay.**

**ADR-0049 / st-uqo4: catch-up.** `Session.subscribe/3` with
`subscribe_opts :: [catch_up: boolean()]`
(`statifier-ex/lib/statifier/session.ex:683`) returns
`:ok | {:ok, Recording.t()} | {:error, :not_recorded}`
(`statifier-ex/lib/statifier/session.ex:711-712`). On a recording session the
snapshot is taken in the same `handle_call` that adds the pid
(`statifier-ex/lib/statifier/session.ex:1028`); on a non-recording session the
pid is **not** added (`statifier-ex/lib/statifier/session.ex:1024`), so a
"try catch_up, ignore the error" attaches nothing. `Replay.run/1`
(`statifier-ex/lib/statifier/replay.ex:201-203`) returns
`%{machine_state:, stream:, status:}` whose stream elements are the
un-enveloped subscriber shapes
(`statifier-ex/lib/statifier/replay.ex:174`), so prefix plus mailbox suffix is
one uniform stream with no overlap and no dedup key, resting on a new
invariant asserted between GenServer callbacks. ADR-0049 decision 3
**declined** a session-header effect, so building `session.start` stays this
repo's work - the stream opens with `{:datamodel_init, _}` instead, which is
the same effect this repo's normalizer currently rejects. Watch the
one-letter trap: `recording/1` answers `:not_recording`, `subscribe/3` answers
`:not_recorded`. **Unblocks sui-t36.8.**

**ADR-0050 / st-fd7n: invoke-tree observation.** `Session.invocations/1`
(`statifier-ex/lib/statifier/session.ex:669`) returns
`[%{invoke_id: String.t(), session_id: String.t(), pid: pid()}]`
(`statifier-ex/lib/statifier/session/invocations.ex:186`), sorted by
`invoke_id`. `:inherit_observers` on `start_link/2` defaults to `false`; when
true a child inherits the parent's `:trace` and its subscriber pids as a
snapshot, transitively. It does **not** inherit `:record`, so `catch_up: true`
on a child always answers `{:error, :not_recorded}`. An inheriting subscriber
sees child session ids and must demux on them - which
[`lib/statifier_ui/trace/subscriber.ex:278-292`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L278-L292) already does - and `{:halted, _}`
is end-of-stream per session id, not per mailbox. **Unblocks sui-t36.8.**

**st-nhpk: `Location.resolve_span/4`.**
`statifier-ex/lib/statifier/parser/location.ex:114-127` takes
`(value_location, span, value, source)` and returns a `Location.t()` with an
exclusive end. It never raises: a position past the end of `value` clamps, and
a desync returns `value_location` whole. `nil` `value_location` or `nil` span
is the caller's branch, not the helper's. Siblings
`normalize_attribute_value/3` (`:168`) and `normalize_character_data/3`
(`:217`) landed alongside. **Unblocks sui-czr.**

**ADR-0044 / st-r6l9: monotone delivery.** Re-entry effects are now enqueued
and FIFO-drained after the outer batch
(`statifier-ex/lib/statifier/session.ex:1337`) rather than performed inline,
so arrival order is non-decreasing in `(macrostep, round)` across the whole
run, matching `Replay`. `{:halted, reason}` is now promised as end-of-stream.
And more than one `Trace.MacrostepStable` per macrostep is explicitly allowed,
with a new uniqueness key of exactly one per `(macrostep, round)`, the
last-arriving being that macrostep's quiescence. **Relevant to sui-t36.5**,
and it makes three passages in `docs/wire-format.md` false (see below).

**st-5fbw: phantom invocation.** An `<invoke>` with an unsupported resolved
type still emits its `Effect.Invoke` carrying the authored type, but is no
longer recorded in `active_invocations`
(`statifier-ex/lib/statifier/interpreter.ex:1587-1592`), no longer appears in
`Trace.InvokePass.invoke_ids`
(`statifier-ex/lib/statifier/interpreter.ex:1288-1300`), and gets no
`CancelInvoke` on exit
(`statifier-ex/lib/statifier/interpreter/exit_entry.ex:305-312`). Consumer
consequence: an `Effect.Invoke` is no longer proof an invocation started.

#### Additive, with no bead pointing at it

**`d_index` and `Machine.data/2`.** `<data>` elements now carry a
compiler-assigned dense document-order index resolved through
`Machine.data/2` (`statifier-ex/lib/statifier/machine.ex:192-193`) to a
`%Statifier.Machine.Data{}` carrying `location` and `value_location`. This is
a **fourth identity resolver** alongside `at/2`, `transition/2`, and
`content/2`, and `session.start` has no table for it
([`lib/statifier_ui/trace/manifest.ex:77-94`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L77-L94)). `DatamodelChange` references
`d_index`, so a consumer receiving one has no way to resolve it from
`session.start` alone.

#### Breaks that do not touch this repo, verified

- `Statifier.Session.Target` was renamed to `Statifier.Send.Target`. Not
  referenced anywhere in this repo.
- `Statifier.Lowering.lower/1` became `lower/2` with a new required `source`
  argument and no default. Not called here; this repo enters through
  `Statifier.compile/1`, which became `compile/2` with `opts \\ []` and is
  source-compatible.
- `Session.Recording`'s entry shape widened - every variant gained a trailing
  `Send.Routes.t() | nil` and `:cancel` went from a bare atom to a tuple
  (`statifier-ex/lib/statifier/session/recording.ex:93-103`). `t()` is
  `@opaque` and this repo does not use `Recording` yet, so it is inert until
  sui-t36.8.
- Telemetry's `location` metadata key was dropped from the
  `[:statifier, :session, :trace, *]` events, surviving only on
  `:transitions_selected` with exactly one `t_index`. This repo consumes no
  telemetry; statifier ADR-0040 is explicitly excluded from ADR-0002's adopted
  list.
- `%Statifier.MachineState{}` gained `routes` and `invoke_types`
  (`statifier-ex/lib/statifier/machine_state.ex:357-358`); this repo does not
  build or exhaustively match that struct.
- New `Statifier.Invoke.Handler` behaviour and `:invoke_handlers` option
  (statifier ADR-0051). Unused here.
- `<send>` validity now aborts the enclosing block at the send's own position
  (statifier ADR-0047 / ADR-0048); no test here asserts block completion after
  a bad `<send>`.
- XML normalization now folds attribute values per XML 1.0 3.3.3 and character
  data per 2.11, so `Script.text`, `Content.text`, `Data.text`, and
  `Assign.text` change on a CRLF checkout and a multi-line `cond` compiles to
  a single line. This repo's fixtures are LF heredocs at 4-space indentation
  per the project convention, so the exposure is low - but it is the reason
  sui-czr must not hand-roll span arithmetic.
- A syntactically ill-formed `namelist` now compiles, with
  `Machine.Param.expr` carrying `{:invalid, error}` and failing at execute
  time. `lib/statifier_ui/trace/manifest.ex` does not read `Machine.Param`.

### Where each upstream change lands, and what it unblocks

| Upstream change | Bead | Lands on | Kind |
|---|---|---|---|
| `round` on all core effects (ADR-0046) | st-xb2b -> sui-t36.5 | `normalizer.ex:252,260,289,295,306,319,337,345`; `normalizer_test.exs:633-781`; `subscriber_test.exs` `%Log{}` literals; `wire-format.md:57-65` | break (builders) |
| `:datamodel_init` / `:datamodel_change` | st-oef3, st-1xwh -> **no sui- bead** | `normalizer.ex:168-179`; every session via `subscriber.ex:392-405` | break (behavioral) |
| `configuration` on Entry/ExitSet | st-ntf5 -> sui-t36.4 | `normalizer.ex:201,213`; `normalizer_test.exs` literals; `wire-format.md` trace schemas | break (builders) |
| `attribute_locations` | st-9i5r -> sui-qay | `manifest.ex:118-151`; `wire-format.md:328-338` | additive |
| `subscribe/3` + `Replay.run/1` (ADR-0049) | st-uqo4 -> sui-t36.8 | `subscriber.ex:235` | additive |
| `invocations/1`, `:inherit_observers` (ADR-0050) | st-fd7n -> sui-t36.8 | `subscriber.ex:278-292` | additive |
| `Location.resolve_span/4` | st-nhpk -> sui-czr | not yet consumed | additive |
| Monotone delivery, halt-terminal (ADR-0044) | st-r6l9 -> sui-t36.5 | `wire-format.md:100-114` | doc-invalidating |
| Phantom invoke suppressed | st-5fbw | `normalizer.ex:225` semantics | behavioral |
| `d_index` / `Machine.data/2` | **no bead** | `manifest.ex:77-94` | additive gap |
| Eight-key durations | px-69c -> sui-cw0 | `shape.ex` `@doc`; `value_test.exs:89,98`; `shape_test.exs` | doc + test justification |

Three passages in `docs/wire-format.md` state upstream gaps that have now
closed, and the drift test at
[`test/statifier_ui/trace/wire_format_spec_test.exs:9-27`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/wire_format_spec_test.exs#L9-L27) will not catch any of
them, because it compares only the type table:

- [`docs/wire-format.md:57-65`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L57-L65), the `st-nbmj` paragraph asserting `effect.*`
  carries no `round`. ADR-0046 closed it; per ADR-0005's own versioning rule
  ([`docs/adr/0005-language-neutral-trace-wire-format.md:137-144`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/adr/0005-language-neutral-trace-wire-format.md#L137-L144)) gaining the
  key is additive and not a version bump.
- [`docs/wire-format.md:100-114`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L100-L114), the `st-r6l9` ordering warning and the
  instruction never to treat halt as end-of-stream. ADR-0044 closed both.
- [`docs/wire-format.md:652-662`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L652-L662), `session.datamodel` reserved-but-unemitted
  pending `st-oef3`. The engine now emits the effects.

### Coverage against sui-bpb's third acceptance criterion

"Predicator 9.0.0 breaking changes are reviewed and any beyond the duration
key set are filed."

Reviewed against the `v8.0.0..v9.0.0` diff of `predicator-ex/lib/`, which is
the correct range because this repo pins exactly 8.0.0. **There is nothing
beyond the duration key set to file.** The four predicator-adjacent surfaces
that carry no version bead of their own were each checked against the diff and
are all untouched in the range:

- `Predicator` Provider behaviour `functions/0`, relied on by sui-t36.7 -
  unchanged.
- `:undefined` and null shape-inference semantics, written against predicator
  6.0 in the closed sui-t36.2 - unchanged in this range.
- `Predicator.Types.span()`, consumed by sui-czr through
  `Location.resolve_span/4` - unchanged.
- Free-standing expression evaluation for ADR-0006 datasets, sui-bob -
  unchanged.

sui-cw0's own note already records that px-69c settled on the eight-key
branch, which means its encode-side worry does not apply:
`StatifierUI.Value.encode/1` filling `:milliseconds` with `0` is not inventing
a unit. Only the `@doc` justification on `StatifierUI.Shape.duration?/1` needs
rewriting, and the `shape_test.exs` durations-from-real-predicator tests need
confirming that they would fail if the subset rule were tightened.

**By contrast, the statifier side does have uncovered surface**, listed under
Open Questions below.

## Code References

- [`lib/statifier_ui/trace/normalizer.ex:168-179`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L168-L179) - `decompose/1`'s ten-tag
  dispatch and its `{:error, {:unknown_effect, tag}}` fallthrough, the exact
  line the two new core tags fall through
- [`lib/statifier_ui/trace/normalizer.ex:252`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L252) - a representative core-effect
  message built with a literal `nil` for `round`
- [`lib/statifier_ui/trace/normalizer.ex:184-241`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L184-L241) - the nine `Trace.*` struct
  matches and the unknown-trace-struct fallthrough
- [`lib/statifier_ui/trace/normalizer.ex:488-489`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/normalizer.ex#L488-L489) - `configuration/1`, the
  `MapSet`-to-sorted-list reduction
- [`lib/statifier_ui/trace/manifest.ex:111-189`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L111-L189) - the `%Statifier.Machine{}`
  walk: states, transitions, contents, and the `Content.Script.node_location`
  fallback
- [`lib/statifier_ui/trace/subscriber.ex:235`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L235) - the sole
  `Statifier.Session.subscribe/2` call site, the one ADR-0049 gives an arity-3
  sibling
- [`lib/statifier_ui/trace/subscriber.ex:392-405`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L392-L405) - `record_normalize_error/3`,
  which does not touch `seq`
- [`lib/statifier_ui/trace/subscriber.ex:407-412`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/subscriber.ex#L407-L412) - `buffer_and_fanout/2`, the
  only place `seq` increments
- [`lib/statifier_ui/value.ex:174-196`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/value.ex#L174-L196) - the always-eight-key duration encode
  and decode
- [`lib/statifier_ui/value.ex:36-45`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/value.ex#L36-L45) - the locally declared `@duration_units`
- [`test/statifier_ui/trace/normalizer_test.exs:633-781`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L633-L781) - the `maximal/2`
  struct literals that break on the new `@enforce_keys`
- [`test/statifier_ui/trace/normalizer_test.exs:783-816`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/test/statifier_ui/trace/normalizer_test.exs#L783-L816) - `expected_keys/2`,
  the per-type payload key assertions
- `test/support/trace/two_state.jsonl` - fourteen `trace.*` lines, all already
  carrying `round`
- [`docs/wire-format.md:57-65`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L57-L65) - the now-false `st-nbmj` paragraph
- [`docs/wire-format.md:100-114`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L100-L114) - the now-false `st-r6l9` ordering warning
- [`docs/wire-format.md:652-662`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/wire-format.md#L652-L662) - the now-false `session.datamodel`
  reservation
- `statifier-ex/lib/statifier/effect.ex:34-35` - the two new core tags
- `statifier-ex/lib/statifier/effect/trace/exit_set.ex:36-44` - the widened
  `@enforce_keys`
- `statifier-ex/lib/statifier/session.ex:711-712` - `subscribe/3`
- `statifier-ex/lib/statifier/replay.ex:201-203` - `Replay.run/1`
- `statifier-ex/lib/statifier/parser/location.ex:114-127` - `resolve_span/4`
- `statifier-ex/lib/statifier/document.ex:97` - `attribute_locations()`
- `predicator-ex/lib/predicator/evaluator.ex:1831` - the one behavioral line
  of the 8-to-9 bump

## Architecture Documentation

The governing records for this refresh are already written, and none of them
needs re-arguing.

**ADR-0004** fixes the mechanism: statifier is a git dependency with the SHA
pinned in `mix.lock` until it publishes to hex, so this is a SHA move, not a
semver bump ([`docs/adr/0004-one-package-with-optional-integrations.md:33-37`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/adr/0004-one-package-with-optional-integrations.md#L33-L37)).
Predicator arrives transitively as an ordinary hex requirement.

**ADR-0002** fixes what happens to anything the bump exposes: upstream ADRs
are adopted as they stand rather than as a snapshot, so a bump does not by
itself amend ADR-0002 - only a change in the *set* of load-bearing upstream
records does. And any engine gap found while bumping is an `st-` or `px-`
bead, never a patch from here, "however small the patch looks"
([`docs/adr/0002-adopt-upstream-decisions-by-reference.md:90-96`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/adr/0002-adopt-upstream-decisions-by-reference.md#L90-L96)).

**ADR-0010** supplies the tracker mechanics, and one clause of it is directly
load-bearing here: this repo owns "when its dependency pins move"
([`docs/adr/0010-cross-repo-tracker-authority-and-mirrors.md:69-70`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/adr/0010-cross-repo-tracker-authority-and-mirrors.md#L69-L70)). Refresh
timing is this repo's call, not something to defer upstream. Mirrors pull;
re-read the `st-`/`px-` bead before acting on a mirrored `sui-` bead.

**ADR-0005** supplies the drift alarm and the version rule. Consumers must
ignore unknown fields and unknown types, so additive upstream change is not a
version bump; a bump means an old-version consumer would misread the stream
([`docs/adr/0005-language-neutral-trace-wire-format.md:137-144`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/docs/adr/0005-language-neutral-trace-wire-format.md#L137-L144)). Its
Consequences name the golden-trace mechanism as the alarm for exactly this
situation, and say a vocabulary change that breaks it is handled as ADR-0002
prescribes, in the open, not by a quiet local patch. Everything the statifier
delta adds to the wire format - `round` on `effect.*`, `configuration` on the
two set effects, attribute-level location entries, a data table - is additive
under this rule.

**ADR-0011** is the record that survives this bump unchanged and is worth
checking rather than assuming: `indexes` on `Trace.EntrySet` and
`Trace.ExitSet` is still `[non_neg_integer()]` in engine emission order
upstream, so the "keep the engine's order, never re-sort" rule still describes
the engine. The new `configuration` field is a genuine `MapSet` and therefore
takes ADR-0011's ascending-serialization branch. The one discipline the record
demands of this refresh: if the golden fixture's exit or entry order ever
moves, that is a real behavior change to review, never an artifact to
re-baseline silently.

**ADR-0006** shares ADR-0005's value codec for `expect` maps, so it inherits
the duration finding without needing its own analysis.

## Historical Context

`docs/research/260816-sui-t36.1-trace-coverage-spike.md` filed eight engine
gaps against the vendored statifier. This refresh closes or moves **all
eight** of them, which is a useful measure of how much of the 141 commits is
work this repo asked for. (An earlier revision of this document said six; the
list below always showed seven, and GAP 5 was confirmed closed during the
post-implementation verification pass - see the resolution under open question
6.)

- GAP 1, st-nbmj (`round` missing from core effects) - **closed** by ADR-0046.
- GAP 2, st-oef3 (no datamodel-change effect) - **closed**, and it is the
  finding with no `sui-` bead behind it.
- GAP 3, st-fd7n (child invocations not introspectable) - **closed** by
  ADR-0050.
- GAP 4, st-r6l9 (delivery order can violate `(macrostep, round)`; trace
  effects after halt) - **closed** by ADR-0044.
- GAP 6, st-uqo4 (no replay for a late subscriber) - **closed** by ADR-0049,
  though not as filed: the buffer-retention design was rejected in favour of
  replaying the recording.
- GAP 7, st-ntf5 (no per-microstep configuration) - **closed**.
- GAP 5, st-xbaz (`start_session/2` deadlock on initialize-time `<invoke>`) -
  **closed** upstream as a duplicate of st-u2h4, fixed by statifier `3fe03ca`,
  which is an ancestor of the pinned `1d0c6ba`. Verified after implementation,
  not in the original pass.
- GAP 8, st-5fbw (phantom child for unsupported invoke type) - **closed**.

The spike also verified `Machine.at/2`, `transition/2`, `content/2`, and
`id_to_index` as the resolution calls a serializer needs; all four survive,
and `Machine.data/2` joins them as a fourth.

`docs/plans/260817-sui-t36.3-session-subscriber-and-trace-normalizer.md`
recorded two facts about the vendored engine that this refresh should be
re-checked against, since both were landmines the producer works around:
`%Statifier.Machine{}` does not retain SCXML source text, and there is no
`index_to_id` map. Neither changed in the range. Its third landmine -
`Content.Script` carrying `:node_location` rather than `:location` - also
survives, so the fallback at [`lib/statifier_ui/trace/manifest.ex:187-188`](https://github.com/riddler/statifier-ui/blob/e7bc8abc78016d6477613231513f4f145fb40208/lib/statifier_ui/trace/manifest.ex#L187-L188)
stays necessary.

The spike's note that `Statifier.Replay` was already more trustworthy than
live delivery on the reordering seam is now historical: ADR-0044 made live
delivery match replay's order, which is what makes ADR-0049's
prefix-plus-suffix recipe sound.

## Related Research

- `docs/research/260816-sui-t36.1-trace-coverage-spike.md` - the eight engine
  gaps, six of which this refresh closes
- `docs/research/260816-sui-kua-gui-research-and-direction.md` - the founding
  research the ADRs cite
- `docs/plans/260817-sui-t36.3-session-subscriber-and-trace-normalizer.md` -
  the plan that built the normalizer and manifest against the pinned engine

## Open Questions

1. **`:datamodel_init` and `:datamodel_change` have no `sui-` bead, and
   `:datamodel_init` is not optional.** It is emitted on every
   `initialize/2`, including under `trace: false`, so after the refresh every
   observed session records a normalize error. sui-bpb's description does not
   list st-oef3 or st-1xwh among the changes it expects. Whether the refresh
   bead absorbs a minimal fix - even just teaching `decompose/1` to ignore the
   two tags so the error count stays clean - or whether the whole
   `session.datamodel` un-reservation is its own bead, is a scoping call this
   research cannot make. What is certain is that leaving it entirely to a
   later bead means shipping a refresh whose every session logs a warning.
   sui-t36.7 is the datamodel explorer pane, but it is about the predicator
   Provider behaviour, not these effects, so it is not the right home as
   written.

2. **`d_index` and `Machine.data/2` have no bead.** `session.start` grows a
   fourth identity table or `DatamodelChange`'s `d_index` is unresolvable by a
   consumer. This only becomes urgent once question 1 is answered in favour of
   actually emitting datamodel messages.

3. **The three false passages in `docs/wire-format.md`** (`:57-65`,
   `:100-114`, `:652-662`) are not caught by the drift test, which compares
   only the type table. Whether correcting them is refresh work or belongs to
   the beads that consume each change (sui-t36.5 for ordering, sui-t36.4 for
   configuration) is unresolved. The risk of deferring is that the spec
   actively misinstructs a second interpreter in the meantime.

4. **Are the golden fixture bytes truly unmoved?** The reasoning above says
   yes - all fourteen lines are `trace.*`, all already carry `round`, and the
   rejected datamodel effect does not consume a `seq`. That is a prediction
   from reading, not an observation; it was not run, because this research
   stage does not touch `mix.lock`. It is the first thing the implementation
   should check, and a moved byte is information about upstream, never
   something to re-baseline (ADR-0005, ADR-0011).

5. ~~**sui-t36.6 and sui-t36.7 do not depend on sui-bpb** even though the
   other four `sui-t36.x` children do.~~ **Resolved 2026-08-19.** They are not
   the same case. sui-t36.6 (event injection) drives the ordinary
   `Statifier.Session` event API and correctly needs nothing from the refresh.
   sui-t36.7 (datamodel explorer) was an omission: its live mode reads the
   subscribed session datamodel, which did not exist on the wire before this
   refresh. Dependencies on sui-bpb and sui-h92 were added.

6. ~~**st-xbaz (GAP 5, the initialize-time `<invoke>` deadlock)** was not
   verified as closed or open in this pass.~~ **Resolved 2026-08-19.** It is
   closed upstream as a duplicate of st-u2h4, fixed by `3fe03ca`. It did not
   surface in the commit-range review because it landed under the other bead's
   id. `git merge-base --is-ancestor 3fe03ca 1d0c6ba` confirms the fix is in
   the pinned tree, so this refresh carries it.
