# Subexpression underlining via `resolve_span/4` Implementation Plan

## Overview

ADR-0007 commits the editor to underlining a *failing subexpression* rather
than a whole attribute. The composition that turns a predicator span into an
absolute document span is not arithmetic - entity expansion shifts columns
between the raw source and the string predicator counted in - and the engine
now owns it as `Statifier.Parser.Location.resolve_span/4`. This plan makes
statifier-ui consume that helper (never reimplement it, ADR-0002) and makes
the wire producer pre-resolve spans to absolute positions so a non-Elixir
consumer can underline without a compiler or a composition routine of its own
(ADR-0005).

The work also closes a live defect discovered while planning: today an
`error.execution` event carrying a `%Statifier.Evaluator.Error{}` makes the
*entire* trace message fail to normalize, so the message a diagnostics UI most
needs is the one message that never reaches the wire.

Bead: sui-czr (mirrors st-nhpk, closed upstream).

## Current State Analysis

**The engine helper exists and is the version this repo resolves.**
`Statifier.Parser.Location.resolve_span/4` is at
`deps/statifier/lib/statifier/parser/location.ex:120` (statifier 2.0.0, the
version `mix.lock` pins; the same file in the sibling checkout
`../statifier-ex/lib/statifier/parser/location.ex` agrees). Signature:

```elixir
@spec resolve_span(
        value_location :: Location.t(),
        span :: Predicator.Types.span(),
        value :: binary(),
        source :: binary()
      ) :: Location.t()
```

It degrades rather than raising: a position past the end of `value` clamps to
`value_location`'s end, and a raw/expanded desync returns `value_location`
whole. Both ends - the predicator span's and the returned location's - are
**exclusive**.

**Nothing in this repo consumes it, and nothing composes spans locally
either.** `grep -rn "resolve_span\|attribute_locations" lib/` returns nothing.
A wider sweep for line/column arithmetic over a `%Location{}` in `lib/`
(`start_column +`, `end_column -`, `start_offset +`, and every `Location`
reference) finds only `StatifierUI.Trace.Manifest`'s `location_object/1`
(`lib/statifier_ui/trace/manifest.ex:218-228`), which copies the six fields
verbatim and does no arithmetic at all. **There is no existing local span
composition to retire.** Acceptance criterion 1 is therefore satisfied
constructively - by consuming the helper at the one site that needs a
subexpression span - rather than by deleting a competing implementation. This
plan does not manufacture one to delete.

**The live defect.** `StatifierUI.Value.encode/1`
(`lib/statifier_ui/value.ex:159`) rejects any struct outside its closed
predicator-value domain:

```elixir
def encode(%_struct{} = other), do: {:error, {:unsupported_value, other}}
```

`Statifier.Interpreter.Content.raise_execution_error/4` raises
`error.execution` with `data: reason`, and for every expression failure that
`reason` is a `%Statifier.Evaluator.Error{source:, error:, span:}`. That struct
reaches the normalizer as `Statifier.Event.data`, goes through
`put_defined(base, "data", ev.data)` -> `Value.encode/1`, and the whole message
becomes `{:error, {:unsupported_value, %Statifier.Evaluator.Error{...}}}`.
Verified two ways during planning:

- Unit: `Normalizer.normalize({:trace, %Trace.EventDequeued{event: %Event{data:
  %Evaluator.Error{}}}}, %{session: "s", seq: 3})` returns
  `{:error, {:unsupported_value, %Statifier.Evaluator.Error{...}}}`.
- End to end: a real session over a chart with an undefined variable in a
  `cond` logs `StatifierUI.Trace.Subscriber: normalize error on trace:
  {:unsupported_value, %Statifier.Evaluator.Error{source: "amount < limit",
  error: %Predicator.Errors.UndefinedVariableError{...}, span: {{1,1},{1,7}}}}`
  and drops the message.

So the producer half of this bead is not "add a field to a working message";
it is "make the message exist at all".

**The producer already has everything it needs.**
`StatifierUI.Trace.Subscriber` holds both the compiled `%Statifier.Machine{}`
and the caller-supplied SCXML `source` on its state
(`lib/statifier_ui/trace/subscriber.ex:177-178`, `:301-302`), and passes
`source` to `Manifest.build/3` already (`:495`). What it does *not* pass is
either of them to the normalizer: `ctx` is built at
`lib/statifier_ui/trace/subscriber.ex:518` as `%{session: state.session, seq:
state.seq}` and nothing more. Widening that `ctx` is the whole plumbing
problem, and `Manifest.build/3`'s caller-supplied `source` is the precedent
for how the chart text reaches a producer that cannot derive it.

**The owning node is nameable from the event itself.** A failing expression's
platform event carries `cause.origin`. Verified live: a transition guard
failure produces `origin: {:transition, 0}`, and a content failure produces
`{:content, c_index, owner}` (`deps/statifier/lib/statifier/interpreter/
content.ex:289,296`). The compiled Machine then supplies the value location -
`Transition.cond_location` for a guard, the per-kind `*_location` fields for
content nodes, `Data.value_location` for a `<data>` element.

**The wire format has no `error` vocabulary and no exclusivity statement.**
`docs/wire-format.md`'s event-object table (`:485-497`) has no error field, and
its location table (`:429-436`) marks only `end_offset` as exclusive - the
`end_line`/`end_column` rows say nothing, which is exactly the guess ADR-0005
forbids leaving a consumer to make.

**Projection is a real constraint, not a formality.** ADR-0012's closed
value-position table (`docs/wire-format.md:934-980`) opens with "a value
position added to this format later without a projection rule would carry
values through a projected stream silently, which is the worst failure
available here because it is invisible." Any new field carrying run- or
chart-derived text needs a rule in `lib/statifier_ui/trace/projection.ex`
before it ships.

### Key Discoveries:

- `deps/statifier/lib/statifier/parser/location.ex:120` -
  `resolve_span/4` exists, degrades by design, exclusive end. Read-only from
  here (CLAUDE.md, "The engine is not modified from here").
- `lib/statifier_ui/value.ex:159` - the `%_struct{}` catch-all that swallows
  the whole message today.
- `lib/statifier_ui/trace/subscriber.ex:518` - the one-line `ctx` that must
  widen; `:177-178`/`:301-302` show machine and source are already on state.
- `lib/statifier_ui/trace/manifest.ex:190-192` - `content_location/1`
  dispatches on the struct rather than using a generic
  `Map.get(node, :location) || Map.get(node, :node_location)` fallback, with a
  moduledoc section arguing why the generic form is silently wrong for
  `Content.Assign`. The new resolver follows that precedent: an explicit,
  greppable per-kind table, not reflection.
- `docs/wire-format.md:934-980` (projection positions), `:1066-1084`
  (`allow_source`), `:1178-1215` (the type index, a machine boundary asserted
  by `test/statifier_ui/trace/wire_format_spec_test.exs`).
- `test/statifier_ui/trace/golden_trace_test.exs` - the byte-for-byte
  conformance fixture. Its chart raises no error, so this work must leave
  `test/support/trace/two_state.jsonl` byte-identical.
- ADR-0005: additive **fields** are not a version bump; the **type** set is
  fixed. This plan adds fields only. Version stays `1`. The 24-entry type
  index is untouched.

## Desired End State

An `error.execution` (or `error.communication`) event whose `data` is a
`%Statifier.Evaluator.Error{}` normalizes successfully and reaches the wire
carrying an `error` object on the event: the failure kind, the entity-expanded
expression predicator counted columns in, the predicator span over that
expression, and - when the producer was given the machine and the chart source
- the **absolute, pre-resolved** document location of the failing
subexpression, produced by `Statifier.Parser.Location.resolve_span/4` and by
nothing else. `docs/wire-format.md` documents that object and states the
end-exclusive convention explicitly for both spans and locations.

How to verify it is done:

- `mix quality` green.
- A test drives a real session over a chart whose guard contains a character
  reference, and asserts the produced absolute location slices back out of the
  source as exactly the failing subexpression - and that a naive
  `value_location.start_column + span_column - 1` composition does **not**.
- `test/support/trace/two_state.jsonl` is unchanged on disk.

## What We're NOT Doing

- **Not adding a wire message type.** ADR-0005 fixes the 24-entry type list;
  this work adds fields to an existing object. `Normalizer.types/0` and
  `docs/wire-format.md`'s type index are untouched, and the format version
  stays `1`.
- **Not carrying the predicator error's rendered `message` on the wire.**
  `%Predicator.Errors.TypeMismatchError{}` carries `:values` and its `message`
  embeds them, so a `message` field would be a **datamodel value position**
  under ADR-0012 - requiring a new entry in
  `StatifierUI.Trace.Projection.positions/0`'s closed set, a new profile knob,
  and a redaction rule, all for text a consumer reconstructs from `kind` +
  `expression` + `span`. Carrying `kind` (a closed discriminator) and letting
  the consumer render its own message is the smaller and more projectable
  choice. Rendering full error prose on the wire is a separate decision; it is
  recorded as a follow-up in "Follow-ups to file" below rather than folded in
  here.
- **Not fixing every non-encodable `error.*` payload.** The raise site passes
  `data: reason` with `reason :: term()`, so a non-`Evaluator.Error` reason (a
  bare atom, a tuple) still fails `Value.encode/1` and still drops its message.
  This plan fixes the expression-failure case - the case with a span, which is
  what this bead is about - and leaves the general case explicitly unfixed and
  filed. Narrowing the blast radius is deliberate: a general "encode any
  reason" rule is a wire-vocabulary decision, not a bug fix.
- **Not touching the engine.** No `st-` patch, no vendored-dep edit. No engine
  gap was found: `resolve_span/4`, `Evaluator.Error.source`/`:span`, and
  `Event.Cause.origin` together supply every input the producer needs.
- **Not adding a rescue at the leaf.** `resolve_span/4` degrades by contract
  and CLAUDE.md's "errors are values / never rescue-to-default at a leaf"
  convention forbids one. The `nil value_location` / `nil span` branch is a
  producer-side guard that decides *not to call* the helper, which is a
  different thing from catching what it raises.
- **Not trimming the expression before resolving.** The helper anchors
  `value`'s `{1,1}` at `value_location`'s start, which holds because
  `Statifier.Compiler.Expressions.compile/3` does not trim. Nothing here may
  `String.trim/1` an expression on the way to the helper.
- **Not attribute-level location resolution for `<send>`/`<cancel>`.** Those
  nodes keep a raw `attribute_locations` map rather than distilled
  `*_location` fields, and `docs/wire-format.md:461-472` already tracks the
  finer table as `sui-qay`. A failure inside one of them falls back to the
  node's own location, which is the documented degraded behavior, not a gap
  this bead closes.
- **Not touching any file a sibling PR declares.** PRs 61-65 are open against
  main; this plan's file set is disjoint from all five (see "Collision
  surface" below).

## Implementation Approach

Three moves, in dependency order.

**One resolver module, pure.** A new `StatifierUI.Trace.Diagnostic` owns the
whole mapping from `{%Evaluator.Error{}, origin, machine, source}` to the wire
`error` object. It is the *only* caller of `resolve_span/4` in this repo, so
"consumes the engine helper" is a one-site property that a grep can check
rather than a habit spread across the producer. It is pure and takes plain
arguments, matching `Normalizer`'s "testable from a struct literal" stance and
`Manifest`'s "pure, no process" stance.

**Origin-to-location by an explicit table.** The resolver dispatches on
`Event.Cause.origin` and, for content, on the content struct itself - the same
shape as `Manifest.content_location/1`, and for the same recorded reason:
a generic `Map.get(node, :location) || Map.get(node, :node_location)` reflection
is silently wrong for `Content.Assign`, whose `:location` is a path-expression
*string*. Where more than one expression lives on a node
(`Content.If`'s per-branch guards), the candidate whose compiled
`{:compiled, _, source}` third element equals `Evaluator.Error.source` is the
one that failed; where no candidate matches, the node's own span is the
fallback. Every unmatched origin degrades to the owning node's location, and
where even that is unavailable the `location` key is simply absent - key
absence, per ADR-0005's discipline, rather than a null or a sentinel.

**Additive fields, projected before they ship.** The `error` object is a new
key on the existing event object; the `data` key is omitted for it, because a
`%Evaluator.Error{}` is not a predicator value and must not be smuggled
through `Value.encode/1`. Its `expression` field is a slice of the chart
source, so it is governed by the existing `allow_source` knob rather than a new
projection position - the projection rule lands in the same phase as the field,
so no commit ever ships an unredacted value position.

## Phase 1: The resolver, and a fixture that can actually fail

### Overview

Add `StatifierUI.Trace.Diagnostic` and prove it against a chart whose guard
contains a character reference. Nothing consumes it yet; it is a public,
specced module with its own tests, independently committable and
gate-verifiable.

This phase carries the plan's most important test-design decision, so it is
written out rather than left to the implementer.

### Changes Required:

#### 1. The resolver module

**File**: `lib/statifier_ui/trace/diagnostic.ex` (new)
**Changes**: The pure mapping to the wire `error` object; the only
`resolve_span/4` call site in the repo.

```elixir
defmodule StatifierUI.Trace.Diagnostic do
  @moduledoc """
  The wire `error` object for an expression failure: what
  `docs/wire-format.md` documents as an event object's `error` key.

  ... (moduledoc must state: the only caller of
  `Statifier.Parser.Location.resolve_span/4` in this repo, per ADR-0002;
  the end-exclusive convention; that the helper degrades and is therefore
  never rescued; and that a nil value location or nil span means the helper
  is not called at all.)
  """

  alias Statifier.Evaluator
  alias Statifier.Machine
  alias Statifier.Parser.Location

  @spec object(
          Evaluator.Error.t(),
          Statifier.Event.Cause.origin() | nil,
          Machine.t() | nil,
          String.t() | nil
        ) :: map()
  def object(%Evaluator.Error{} = error, origin, machine, source)

  # Origin -> a value location to anchor the span in, or the owning node's
  # own span, or nothing. Explicit per-kind dispatch, never reflection -
  # the reason is `StatifierUI.Trace.Manifest`'s moduledoc gotcha section.
  @spec anchor(Statifier.Event.Cause.origin(), Machine.t(), Evaluator.Error.t()) ::
          {:value, Location.t()} | {:node, Location.t()} | :none
end
```

The produced object:

| Key | Value | Presence |
|---|---|---|
| `"kind"` | underscored last segment of the predicator error struct module (`"undefined_variable"`, `"type_mismatch"`, `"evaluation"`, `"parse"`, `"location"`) | always |
| `"expression"` | `Evaluator.Error.source` - the entity-expanded string predicator counted columns in | always |
| `"span"` | `%{"start_line" =>, "start_column" =>, "end_line" =>, "end_column" =>}` over `expression`, 1-based, end-exclusive | only when `Evaluator.Error.span` is non-nil |
| `"location"` | the six-field absolute location object, end-exclusive | only when `machine` and `source` were both supplied and an anchor was found |
| `"location_kind"` | `"resolved"` or `"node"` | exactly when `"location"` is present |

`"location_kind"` reports **what the producer did**, not what the helper
decided: `"resolved"` means `resolve_span/4` was called with a value location
and a span, `"node"` means it was not (no span, or no value location) and the
owning node's own span was emitted instead. The producer must not try to detect
the helper's internal degradation by comparing the result against
`value_location` - that would model helper internals, which is the ADR-0002
failure this bead exists to prevent. The doc phase states plainly that
`"resolved"` may still span the whole attribute value when the helper degraded.

Bounds on the `anchor/3` table for this phase:

- `{:transition, t_index}` -> `Transition.cond_location` as `{:value, _}`,
  falling back to `Transition.location` as `{:node, _}`.
- `{:data, d_index}` -> `Data.value_location` as `{:value, _}` **only when it
  differs from `Data.location`** - `docs/wire-format.md:411-424` records that
  `value_location` falls back to the element's own span when there is no
  distinct value, and anchoring an expression at the whole `<data>` element
  would be wrong; equal means `{:node, _}`.
- `{:content, c_index, _owner}` -> the content node's expression location by
  the explicit per-kind table: `Content.Log.expr_location`,
  `Content.Assign.expr_location`, `Content.Foreach.array_location` (the only
  one of `Foreach`'s three `*_location` fields that spans an expression -
  `item_location` and `index_location` span datamodel location paths), and
  the matching `%Content.If.Branch{}`'s `cond_location`
  (`deps/statifier/lib/statifier/machine/content/if.ex:87`, a nested struct
  under `Content.If.branches`). Selection among multiple
  candidates is by `{:compiled, _, source} == Evaluator.Error.source`. No
  match, or a kind not in the table (`Content.Send`, `Content.Cancel`,
  `Content.Script`, everything else) -> `{:node, _}` with the node's own span
  via the same rule `Manifest.content_location/1` uses.
- Every other origin (`{:state, _}`, `{:donedata_param, _, _}`,
  `{:global_script, _}`, `{:invoke, _, _}`, `{:finalize, _, _}`) -> `{:node, _}`
  where the machine names a span for it, `:none` otherwise.
- `origin` of `nil`, or `machine`/`source` of `nil` -> `:none`.

#### 2. The regression fixture and its sabotage test

**File**: `test/statifier_ui/trace/diagnostic_test.exs` (new)
**Changes**: unit coverage of the object shape and the anchor table, plus the
character-reference regression.

The chart is an inline heredoc, matching `golden_trace_test.exs`'s `@two_state`
convention, and deliberately **not** a file under `test/support/fixtures/` -
that directory holds `StatifierUI.Fixtures.Source` behaviour modules, and PR 65
is moving files inside it.

```elixir
# A less-than guard written with a character reference, which is the case
# naive span composition gets wrong: `&lt;` is four raw characters standing
# for one expanded character, so every column after it is shifted by three.
# `amount` is bound and `limit` is not, so the engine's own
# UndefinedVariableError attributes to the subexpression *after* the
# reference - the half where the divergence is observable.
@entity_guard """
<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="idle" version="1.0" datamodel="elixir">
    <datamodel><data id="amount" expr="100"/></datamodel>
    <state id="idle">
        <transition event="myapp:authorize" cond="amount &lt; limit" target="approved"/>
    </state>
    <state id="approved"/>
</scxml>
"""
```

**The sabotage requirement, stated as an assertion.** A test that stays green
when the `resolve_span/4` call is removed is not evidence. This fixture's whole
job is to fail under naive composition, so the test asserts the divergence
explicitly rather than only asserting the right answer. Verified against
statifier 2.0.0 during planning, with `cond_location` at line 4, columns 51-68,
raw slice `"amount &lt; limit"`, expanded value `"amount < limit"`, engine span
`{{1, 10}, {1, 15}}`:

| | start_column | end_column | slice of `source` |
|---|---|---|---|
| naive (`value_location.start_column + span_column - 1`) | 60 | 65 | `"t; li"` |
| `resolve_span/4` | 63 | 68 | `"limit"` |

The test must assert all three of:

1. `Location.slice(resolved, source) == "limit"` - the right answer.
2. The naive composition over the same inputs slices `"t; li"` - so the test
   demonstrates, in the same run, that the naive answer is wrong.
3. `resolved.end_column - naive_end_column == byte_size("&lt;") - byte_size("<")`
   - three columns, and the test names *why* three.

Assert on the `"limit"`/`"t; li"` slices rather than on bare column numbers:
slices survive an edit to the fixture's indentation, raw columns do not.

A second case pins the trap that makes this fixture necessary: a span over
`amount` (**before** the reference) resolves to columns 51-57 under both the
naive composition and the helper. A test built on that subexpression would pass
with `resolve_span/4` deleted. The test records that explicitly, so a later
reader cannot "simplify" the fixture back into uselessness.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`), coverage floor included.
- [x] `grep -rn "resolve_span" lib/` names exactly one file,
      `lib/statifier_ui/trace/diagnostic.ex`.
- [x] The character-reference test asserts the resolved slice is `"limit"`,
      that the naive composition over the same inputs yields `"t; li"`, and
      that the divergence equals `byte_size("&lt;") - byte_size("<")`.
- [x] A test covers each `anchor/3` arm: transition-with-guard,
      transition-without-guard, `<data>` with and without a distinct value
      span, a matching content kind, a non-matching content kind, an origin the
      table does not name, and `nil` machine/source.
- [x] `git diff --stat` for this phase touches no file outside
      `lib/statifier_ui/trace/diagnostic.ex` and
      `test/statifier_ui/trace/diagnostic_test.exs`.

#### Manual Verification:
- [ ] Delete the `resolve_span/4` call, substitute naive arithmetic, and
      confirm the character-reference test goes **red**. Restore. This is the
      sabotage check; it is manual because it is a deliberate temporary
      regression, and it is the only thing that proves the fixture earns its
      place.
- [ ] Read the `anchor/3` table against
      `deps/statifier/lib/statifier/machine/content/*.ex` and confirm no kind
      was given a `*_location` field it does not have, and that `Content.Assign`
      is not anchored on its `:location` string.
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Producer wiring, and the projection rule that must ship with it

### Overview

Thread the machine and the chart source to the normalizer, emit the `error`
object where an `%Evaluator.Error{}` appears in an event's `data`, and give the
new `expression` field its projection rule in the same commit. After this
phase the defect is closed: an `error.execution` message reaches the wire
instead of being dropped with a warning.

### Changes Required:

#### 1. Widen the normalizer context

**File**: `lib/statifier_ui/trace/normalizer.ex`
**Changes**: `ctx` gains two optional keys; `event/1` becomes `event/2`.

```elixir
@type ctx :: %{
        :session => String.t(),
        :seq => non_neg_integer(),
        optional(:machine) => Statifier.Machine.t(),
        optional(:source) => String.t()
      }
```

Optional, not required, on purpose: every existing normalizer test constructs
`%{session: "sess_1", seq: 7}` from a struct literal, and the moduledoc's "no
process, no session, no `%Statifier.Machine{}` - the whole vocabulary is
testable from a struct literal" claim stays true. Without the keys the producer
still emits `kind`/`expression`/`span` and omits `location` - which is exactly
the ADR-0005 key-absence discipline, and is why `expression` is carried on the
wire at all rather than left for the consumer to slice out of `source`.

**Every function on the path to `event/1` gains a `ctx` parameter.** The full
signature list, so none is discovered at compile time:

- `event/1` -> `event/2` (`lib/statifier_ui/trace/normalizer.ex:414`)
- `put_event/2` -> `put_event/3` (`:432`, `:434`) - the `TransitionsSelected`
  clause reaches `event/1` through this wrapper, not directly
- `event_list/1` -> `event_list/2` (`:398`) - for `BudgetExhausted`
- the three direct `event(p.event)` call sites (`:197` `EventDequeued`, `:247`
  `FinalizeAutoforward`, `:328` `Autoforward`) and the one `put_event(base,
  p.event)` site (`:206` `TransitionsSelected`) pass `ctx` through

`decompose/1` and the two message builders it dispatches to (`trace_message/1`,
`core_message/1`) therefore also take `ctx`, since they own those call sites.
`datamodel_message/1` does not - it carries no event.

**The new clause in `event/2`.** The whole point is that `data` and `error` are
alternatives, not siblings: an `%Evaluator.Error{}` must never reach
`Value.encode/1`, which is what drops the message today.

```elixir
@spec event(Event.t(), ctx()) :: {:ok, map()} | {:error, term()}
defp event(%Event{} = ev, ctx) do
  base = %{"name" => ev.name, "type" => Atom.to_string(ev.type)}

  with {:ok, base} <- put_event_data(base, ev, ctx),
       {:ok, base} <- put_cause(base, ev.cause) do
    # ... the four put_present/3 calls, unchanged
  end
end

# A `%Statifier.Evaluator.Error{}` is not a predicator value, so it never
# goes through `StatifierUI.Value.encode/1` - which rejects it with
# `{:unsupported_value, _}` and fails the whole message, as it does today.
# It is reduced structurally instead, the same move `origin/1` and `owner/1`
# make for atoms and tuples, and it lands on its own `error` key rather than
# in the `data` value position: the two are alternatives, so this clause
# does not call `put_defined/3` at all.
@spec put_event_data(map(), Event.t(), ctx()) :: {:ok, map()} | {:error, term()}
defp put_event_data(base, %Event{data: %Evaluator.Error{} = error} = ev, ctx) do
  object =
    Diagnostic.object(
      error,
      origin_of(ev.cause),
      Map.get(ctx, :machine),
      Map.get(ctx, :source)
    )

  {:ok, Map.put(base, "error", object)}
end

defp put_event_data(base, %Event{} = ev, _ctx),
  do: put_defined(base, "data", ev.data)

# `cause` is nil on an external event, and an event the platform raised
# always has one - but an `%Evaluator.Error{}` arriving without a cause is
# not a reason to fail the message, so the origin is simply absent and
# `Diagnostic` falls back to emitting no `location`.
@spec origin_of(Cause.t() | nil) :: Cause.origin() | nil
defp origin_of(%Cause{origin: origin}), do: origin
defp origin_of(nil), do: nil
```

`Map.get(ctx, :machine)` rather than `ctx.machine`: the two keys are optional
on `ctx`, which is what keeps every existing struct-literal test valid.

Two new aliases at the top of the module: `Statifier.Evaluator` (for
`Evaluator.Error`) and `StatifierUI.Trace.Diagnostic`. `Statifier.Event.Cause`
is already aliased (`lib/statifier_ui/trace/normalizer.ex:55`).

The moduledoc's "Value handling" section gains a sentence naming
`%Evaluator.Error{}` as a structurally-reduced shape, alongside the `MapSet`
and atom cases it already lists, and says why it lands on `error` rather than
`data`.

#### 2. Hand the subscriber's machine and source to the normalizer

**File**: `lib/statifier_ui/trace/subscriber.ex`
**Changes**: one expression, at `:518`.

```elixir
ctx = %{
  session: state.session,
  seq: state.seq,
  machine: state.machine,
  source: state.source
}
```

`state.source` may legitimately be `nil` (a host that supplied no chart text);
the resolver already treats that as `:none`.

#### 3. Project `expression`

**File**: `lib/statifier_ui/trace/projection.ex`
**Changes**: `project_event/2` replaces `error.expression` with the `$redacted`
sentinel when the profile sets `allow_source: false`.

`expression` is a slice of the chart source, so it belongs to the existing
`allow_source` knob rather than to `positions/0`'s closed set - which stays at
six entries, and needs no new profile vocabulary. `kind`, `span`, `location`,
and `location_kind` are never projected: `kind` is a closed discriminator and
the other three are location data, the category `docs/wire-format.md:982-1011`
already lists as never projected. Redaction replaces a present key and never
creates one, so an event with no `error` object is untouched.

#### 4. Tests

**Files**: `test/statifier_ui/trace/normalizer_test.exs`,
`test/statifier_ui/trace/subscriber_test.exs`,
`test/statifier_ui/trace/projection_test.exs`
**Changes**: additive - new `describe` blocks, no rewrites of existing ones.

- normalizer: an `%Evaluator.Error{}` in `Event.data` produces an `error`
  object and **no** `data` key, with and without `machine`/`source` in `ctx`;
  a `nil` span omits `span` and yields `location_kind: "node"`.
- subscriber: the end-to-end regression over the Phase 1 chart - the
  `error.execution` message is **present** in `Subscriber.messages/1` with a
  correct absolute `error.location`, where today it is absent and a warning was
  logged. Assert on the produced message, not on log output.
- projection: `allow_source: false` redacts `error.expression` and leaves
  `kind`/`span`/`location`/`location_kind` intact; `allow_source: true` (the
  default) changes nothing.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`).
- [ ] The subscriber test asserts an `error.execution` message with a resolved
      absolute `error.location` is present in the stream - the direct
      regression for `{:unsupported_value, %Statifier.Evaluator.Error{}}`.
- [ ] `test/statifier_ui/trace/golden_trace_test.exs` passes and
      `git status --porcelain test/support/trace/two_state.jsonl` is empty:
      full-fidelity output for a chart that raises no error is byte-unchanged.
- [ ] `StatifierUI.Trace.Normalizer.types/0` still returns 24 entries and
      `test/statifier_ui/trace/wire_format_spec_test.exs` passes - no
      vocabulary growth.
- [ ] `StatifierUI.Trace.Projection.positions/0` still returns 6 entries and
      `test/statifier_ui/trace/projection_drift_test.exs` passes.
- [ ] Every existing normalizer test still constructs `ctx` as
      `%{session: _, seq: _}` and passes - the optional keys are genuinely
      optional.
- [ ] The module compiles with no arity warnings: `event/2`, `put_event/3`,
      `event_list/2`, `decompose/2`, `trace_message/2`, and `core_message/2`
      all updated together, with no leftover arity-1 caller.

#### Manual Verification:
- [ ] Run the Phase 1 chart through a live session and read the emitted JSON:
      the `error` object is legible without an Elixir term in it, and the
      `location` slices back out of `source` as the failing subexpression.
- [ ] Confirm the `error` object contains no predicator struct field that
      embeds a datamodel value (no `message`, no `values`, no `got`), so the
      "no new projection position" claim holds by inspection as well as by
      test.
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: The spec says which convention it uses

### Overview

`docs/wire-format.md` is normative: when the spec and an implementation
disagree, the spec is what conformance means (ADR-0005). This phase documents
the `error` object and states the end-exclusive convention explicitly, which is
the second half of acceptance criterion 2. Plus the changelog fragment.

`docs/wire-format.md` is touched by none of PRs 61-65.

### Changes Required:

#### 1. The end-exclusive convention, stated

**File**: `docs/wire-format.md`
**Changes**: the location table at `:429-436` currently marks only
`end_offset` exclusive. Amend `end_line` and `end_column` to say the same, and
add a short paragraph immediately after the table:

> **Ends are exclusive.** A location's `end_line`/`end_column`/`end_offset`
> and a span object's `end_line`/`end_column` all name the position **one past**
> the last character of the span, so a zero-width span has its start equal to
> its end and a consumer slices `[start, end)` without adjustment. This is the
> convention statifier's own `Statifier.Parser.Location` and predicator's
> `t:Predicator.Types.span/0` both use, and it is stated here rather than left
> for a consumer to infer from the data.

#### 2. The `error` object

**File**: `docs/wire-format.md`
**Changes**: in "The nine `trace.*` schemas" -> `trace.event_dequeued`'s event
object table (`:485-497`):

- add a row: `error | error object | present only when the event's data is an
  expression-evaluation failure`
- amend the `data` row's presence text to say the key is **omitted** when the
  event's data is an expression-evaluation failure, because such a payload is
  not a value and is carried by `error` instead.

Then a new subsection defining the object: the five keys from Phase 1's table,
their presence rules, and three notes:

- `expression` is the **entity-expanded** string the expression engine counted
  columns in - not the raw source text. A `cond` written `amount &lt; limit`
  appears here as `amount < limit`, which is why `span`'s columns cannot be
  added to a raw-source column and why `location` is pre-resolved for you.
- `location` is **absolute and already resolved**: a consumer underlines it
  directly against `source`, with no span composition of its own. This is the
  field that makes the format usable by a consumer with no Elixir and no
  compiler.
- `location_kind` says what the producer did. `"resolved"` means the span was
  composed against the expression's own value span; `"node"` means there was no
  span to compose (or no value span to compose against) and the owning node's
  whole span is what you get. **`"resolved"` may still span the whole attribute
  value**: the composition degrades rather than failing when the raw and
  expanded text desync, and the producer does not distinguish that case.

#### 3. Projection prose

**File**: `docs/wire-format.md`
**Changes**: in `allow_source` (`:1066-1084`), note that `error.expression` is
chart text and is redacted with `source` under `allow_source: false`. In "What
is never projected" (`:982-1011`), add the `error` object's `kind`, `span`,
`location`, and `location_kind` to the enumerated list. Add a sentence to the
closed-value-position table's preamble recording that `error` carries **no**
value position by construction, and why: the predicator error's rendered
message - the field that would embed datamodel values - is deliberately not on
the wire.

The type index (`:1178-1215`) is **not** touched: 24 rows in, 24 rows out.

#### 4. Changelog fragment

**File**: `changelog.d/sui-czr.md` (new)
**Changes**: matching the shape of the existing fragments in that directory -
a Keep-a-Changelog heading (`### Added`, `### Fixed`) over prose bullets, as in
`changelog.d/sui-hmn.md`. Two user-visible facts:

- **Fixed**: an event whose data is an expression-evaluation failure no longer
  fails to normalize. Previously `StatifierUI.Value.encode/1` rejected the
  `%Statifier.Evaluator.Error{}` payload and the whole trace message was
  dropped, so the diagnostic a consumer most needs never reached the wire.
- **Added**: such an event now carries an `error` object naming the failure
  kind, the expression, the span within it, and the **absolute, pre-resolved**
  document location of the failing subexpression - so a consumer underlines it
  directly with no span composition of its own. `docs/wire-format.md` now
  states the end-exclusive convention for spans and locations explicitly.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (`mix quality`).
- [ ] `test/statifier_ui/trace/wire_format_spec_test.exs` passes - the type
      index table still parses to exactly `Normalizer.types/0`.
- [ ] `test/statifier_ui/trace/projection_drift_test.exs` passes.
- [ ] `changelog.d/sui-czr.md` exists and follows the directory's existing
      fragment shape.
- [ ] The word "exclusive" appears on the `end_line`, `end_column`, and
      `end_offset` rows of the location table.

#### Manual Verification:
- [ ] Read the `error` object subsection as a consumer with no Elixir: is the
      distinction between `span` (over `expression`) and `location` (over
      `source`) unambiguous, and is it clear that only `location` is used for
      underlining?
- [ ] Confirm the doc nowhere implies the producer detects the helper's
      internal degradation - `"resolved"`'s caveat must read as a limitation,
      not as a promise.
- [ ] Terminology scan: nothing in the doc, the fragment, the fixture, or the
      tests contains employer or product terminology; example domains are
      `myapp:`-style throughout.
- [ ] No regressions in related features.

**Implementation Note**: This phase touches no Elixir under `lib/`, so per
CLAUDE.md's commit row the diff review carries it - but `mix quality` still runs
and must be green, because the two drift tests parse this document. In
interactive execution, pause here for the human to confirm the manual testing.
In looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically, and Manual Verification items are deferred.

---

## Testing Strategy

### Unit Tests:

- `StatifierUI.Trace.Diagnostic.object/4`: the five-key object across every
  presence combination - span present/absent, machine and source present/absent,
  each `kind` string.
- The `anchor/3` table: one test per arm, including the two traps the plan
  names - `Content.Assign`'s `:location` being a string, and `Data`'s
  `value_location` falling back to the element's own span.
- `StatifierUI.Trace.Normalizer`: `%Evaluator.Error{}` in `Event.data` on each
  of the five event-carrying messages; the `data` key omitted; every existing
  test unchanged with a two-key `ctx`.
- `StatifierUI.Trace.Projection`: `allow_source` toggling `error.expression`
  and leaving the other four keys alone.

### Key edge cases:

- `Evaluator.Error.span == nil` (predicator could not attribute one) -> helper
  not called, `location_kind: "node"`.
- `cond_location == nil` (a guard with no recorded span) -> helper not called.
- `source == nil` on the subscriber -> `location` key absent entirely.
- A character reference **before** the failing subexpression - the case that
  diverges - and one **after** it, the case that does not and therefore cannot
  serve as the regression.
- A chart that raises no error at all -> `two_state.jsonl` byte-identical.

### Manual Testing Steps:

1. Run the Phase 1 chart through a live session with a `Subscriber` and dump
   `StatifierUI.Trace.Json.encode_lines/1`; read the `error` object by eye.
2. Slice `source` at the emitted `location.start_offset`/`end_offset` and
   confirm the text is `limit`.
3. Temporarily replace the `resolve_span/4` call with naive column arithmetic
   and confirm the Phase 1 test fails and step 2's slice becomes `t; li`.
   Restore.
4. Project the same stream under a profile with `allow_source: false` and
   confirm `expression` is `{"$redacted": true}` while `location` survives.

## Open Questions

No open question blocks implementation. Two judgment calls were made without a
human available and are recorded here so they can be reversed cheaply; both are
also written into "What We're NOT Doing" so they survive for whoever
implements.

1. **The predicator error's rendered `message` is not carried on the wire.**
   Decided against it: `%Predicator.Errors.TypeMismatchError{}` carries
   `:values` and its message embeds them, which would make `message` a
   datamodel value position under ADR-0012 and require growing
   `Projection.positions/0`'s closed set. `kind` plus `expression` plus `span`
   lets a consumer render its own message. If the operator wants full error
   prose on the wire, it is an additive field plus one new projection position
   - reversible, and filed as a follow-up rather than assumed.
2. **`error` hangs on the event object, not on a new message type.** ADR-0005
   fixes the 24-entry type list and says additive fields are not a version
   bump, so this is the choice the ADR points at - but it does mean a consumer
   filtering for "errors" filters on a field rather than a type. Recorded
   because it is the kind of shape decision a maintainer may want to look at
   before it has consumers.

### Follow-ups to file (not part of this bead)

- **Non-`Evaluator.Error` `error.*` payloads still drop their message.**
  `raise_execution_error/4` passes `data: reason` with `reason :: term()`, so a
  bare atom or tuple reason still fails `StatifierUI.Value.encode/1` with
  `{:unsupported_value, _}` and the whole message is dropped with a warning.
  This is the same defect class this bead fixes, one case wider. It needs its
  own wire-vocabulary decision (what a non-value, non-error reason looks like
  on the wire) and should be a new `sui-` bead, area `area:wire-format`.
- **Full error prose on the wire**, per Open Question 1 - a new `sui-` bead if
  the operator wants it.
- **Attribute-level locations for `<send>`/`<cancel>`** is already tracked as
  `sui-qay` (`docs/wire-format.md:461-472`); this bead's fallback behavior is
  the interim answer and no new bead is needed.

## Collision surface

Five PRs (61-65) are open against main. This plan's complete file set:

| File | Status | In PR 61-65? |
|---|---|---|
| `lib/statifier_ui/trace/diagnostic.ex` | new | no |
| `lib/statifier_ui/trace/normalizer.ex` | modified | no |
| `lib/statifier_ui/trace/subscriber.ex` | modified | no |
| `lib/statifier_ui/trace/projection.ex` | modified | no |
| `test/statifier_ui/trace/diagnostic_test.exs` | new | no |
| `test/statifier_ui/trace/normalizer_test.exs` | modified | no |
| `test/statifier_ui/trace/subscriber_test.exs` | modified | no |
| `test/statifier_ui/trace/projection_test.exs` | modified | no |
| `docs/wire-format.md` | modified | no |
| `changelog.d/sui-czr.md` | new | no |

PR 65 is the one with a large `test/` footprint; its file list was read
directly (`gh pr view 65 --json files`) and contains **no**
`test/statifier_ui/trace/*` file. Its `test/support/fixtures/` entries are
`StatifierUI.Fixtures.Source` behaviour modules and sidecar JSON, which is why
this plan's SCXML fixture is an inline heredoc in the test file - the
`golden_trace_test.exs` convention - rather than a new file in that directory.
No file in this plan needs a rewrite of a sibling-declared line, and no phase
touches `lib/statifier_ui/inspector.ex`, `lib/statifier_ui/event_log*`,
`lib/statifier_ui/datamodel_explorer*`, `lib/statifier_ui/live*`, `mix.exs`,
`CLAUDE.md`, or `.claude/wurk.json`.

## References

- Bead: `sui-czr` (mirrors `st-nhpk`, closed upstream via statifier-ex PR #168);
  its 2026-08-18 note is the consumer-side contract this plan implements.
- ADRs: `docs/adr/0002-adopt-upstream-decisions-by-reference.md`,
  `docs/adr/0005-language-neutral-trace-wire-format.md`,
  `docs/adr/0007-text-first-authoring.md`,
  `docs/adr/0012-trace-projection-and-redaction.md`
- Spec: `docs/wire-format.md`
- Engine helper (read-only): `deps/statifier/lib/statifier/parser/location.ex:120`,
  and `deps/statifier/lib/statifier/evaluator/error.ex`
- Explicit-dispatch precedent: `lib/statifier_ui/trace/manifest.ex:190-192` and
  its moduledoc's "The `Content.Script`/`Content.Assign` location gotcha"
- Conformance mechanism to keep green:
  `test/statifier_ui/trace/golden_trace_test.exs`,
  `test/statifier_ui/trace/wire_format_spec_test.exs`,
  `test/statifier_ui/trace/projection_drift_test.exs`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] Delete the `resolve_span/4` call, substitute naive arithmetic, and
      confirm the character-reference test goes **red**. Restore. This is the
      sabotage check; it is manual because it is a deliberate temporary
      regression, and it is the only thing that proves the fixture earns its
      place.
- [ ] Read the `anchor/3` table against
      `deps/statifier/lib/statifier/machine/content/*.ex` and confirm no kind
      was given a `*_location` field it does not have, and that `Content.Assign`
      is not anchored on its `:location` string.
- [ ] No regressions in related features.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
