# Declared path kinds in the expression picklist Implementation Plan

## Overview

`StatifierUI.Live.ExpressionInput.expression_input/1` today infers everything
about a clause row from the literal the author's source already carries: a
row whose value is `'pro'` is a string row, so it gets the string operator
list and a free-text value control, whatever the host knows about that path.
This plan adds a second host-supplied input beside `:candidates` and
`:value_candidates` - a `:path_types` map from a declared path to the kind of
value it holds - and lets that declaration decide the operator list, the value
control, and the candidate set, while never rewriting the author's source and
never refusing it.

Bead: sui-2vj. Campaign 032, lane U.

**No new dependency.** The 032 design walk ruled that statifier-ui takes no
`statifier_datamodel` dependency: the caller (statifier_blocks, or any host)
builds the map. `mix.exs` is untouched by this plan.

## Current State Analysis

**The pure half already carries the richer vocabulary.**
`StatifierUI.Expression` names its own `t:value_kind/0`
(`lib/statifier_ui/expression.ex:101-115`) - `:integer | :float | :boolean |
:string | :date | :datetime | :duration | :relative_date | {:list, kind |
nil}` - and `vocabulary_kind/1` (`lib/statifier_ui/expression.ex:674-678`)
translates it to predicator's coarser seven. A caller kind of `:integer`
therefore needs no new normalisation table: it is already this module's own
word. `operators/1` (`lib/statifier_ui/expression.ex:334-343`) is the public
entry point and delegates through that translation.

**One function decides a row's operators and candidates.** `row/3`
(`lib/statifier_ui/expression.ex:570-585`) builds `:operators` from the
**observed** value kind and `:candidates` from the `value_candidates` map
handed to `simple/2` through its `opts`. That is the single place a declared
kind has to reach.

**The component already renders a boolean control.** `value_control/5`
(`lib/statifier_ui/live/expression_input.ex:605-622`) has a
`row.value_kind == :boolean -> value_select(..., boolean_candidates())` arm
producing a `<select>` of `true` / `false`, and `boolean_candidates/0` lives at
`lib/statifier_ui/live/expression_input.ex:819-821`. Nothing new has to be
drawn for "boolean gets a two-option control": the arm is unreachable today
only because the observed kind of `plan == 'pro'` is `:string`. Reaching it is
a matter of which kind `value_control/5` is asked about.

**The value control cascade, in order**, at
`lib/statifier_ui/live/expression_input.ex:605-622`: list kind with candidates
-> multiselect; list kind without -> readonly; any candidates -> select;
`:boolean` -> select over `true` / `false`; otherwise -> free-text template.
So a candidate list alone is enough to turn a path into a `<select>`, which is
exactly what a `{:one_of, values}` declaration needs.

**The author's current choice is preserved for values and not for operators.**
`keep_current/3` (`lib/statifier_ui/live/expression_input.ex:650-656`) prepends
the row's own source as a selected option when the host's candidate list does
not contain it. `op_options/5`
(`lib/statifier_ui/live/expression_input.ex:579-603`) has no counterpart:
narrowing a row's operator list by a declared kind can drop the operator the
source actually carries, which ADR-0007 forbids (the component "never refuses
the expression and never rewrites the author's text").

**`term/3` converts three host value shapes only.**
`lib/statifier_ui/live/expression_input.ex:827-841` handles `:string`,
`:boolean` and `:integer` (non-negative, or a binary that parses to one).
A date candidate set has to reach it as something it recognises.

**Verified against the resolved predicator (9.4.x) by probe:**

| Kind asked of the grammar | Operators returned |
|---|---|
| `:number`, `:string`, `:date`, `:datetime`, `:duration` | `>`, `>=`, `<`, `<=`, `==`, `===`, `!=`, `!==`, `CONTAINS` |
| `:boolean` | `==`, `===`, `!=`, `!==`, `CONTAINS` |
| `:list` | `IN` |

This is load-bearing and it corrects the bead's acceptance wording: **the
grammar's per-kind operator sets are identical for every ordered scalar kind
today**, so "an integer path offers the numeric operators only" cannot be
written as "and not the string ones" - there is no difference to observe. The
sets that genuinely differ are `:boolean` and `{:list, _}`. The plan's tests
assert set equality against `Expression.operators(:integer)` (which stays true
if predicator ever narrows) and use `:boolean` and `{:list, _}` as the
discriminating cases.

**A new conditional element leaves whitespace behind, also probed.** HEEx keeps
the static whitespace that surrounds an element carrying `:if` or `:for`, so a
falsy `:if` element still contributes its indentation to the rendered string.
Probed directly: a template with `<p :for={i <- []}>` and `<span :if={false}>`
inserted between two spans renders `"<span>one</span>\n  \n  \n  <span>two"`
where the original renders `"<span>one</span>\n  <span>two"`. The two are
identical to a browser - whitespace-only text nodes between block elements are
inert - but **they are not byte identical**. That fixes what the byte-identity
criterion can honestly claim: string equality holds between a render *with* the
assign and one *without* it, which is the property that matters and the one the
bead's "no map renders exactly the 0.7.0 markup" is really about; equality
against 0.7.0's own bytes is unachievable the moment any conditional element
joins the template, and no design that renders an advisory avoids it. The plan
therefore pairs the with/without equality with a second, mechanical guard: no
existing test line may be modified or deleted, so every assertion 0.7.0 shipped
still holds verbatim.

**Relative-date spellings, also probed:** `{:relative_date, [{7, "d"}], :ago}`
writes `7d ago`, `:future` writes `7d from now`, `:next` writes `next 7d`,
`:last` writes `last 7d`. The known units come from
`Predicator.Simple.duration_units/0`: `y mo w d h m s ms`.

## Desired End State

`expression_input/1` accepts a `:path_types` assign shaped
`%{path => kind | {:list, kind} | {:one_of, [value]}}`, defaulting to `%{}`.

- The declared kind decides the row's operator list, asked of predicator
  through `Expression.operators/1` - never from a table here.
- The declared kind decides the value control: `{:one_of, values}` renders a
  `<select>` over those values, `:boolean` renders the two-option select the
  component already has, `:date` / `:datetime` / `:relative_date` render a
  select over an offered relative-date set, `{:list, kind}` reaches the
  multiselect / readonly arms.
- An operator the source carries is **always** offered and selected, even when
  the declared kind's list would not contain it.
- A clause whose observed value kind disagrees with the declared kind renders
  an advisory row stamped `data-advisory="value-kind"` and
  `data-severity="info"`; an operator kept only because the source uses it
  renders one stamped `data-advisory="operator"`. Neither blocks, neither
  rewrites.
- With no `:path_types`, or an empty map, the rendered HTML is **byte identical
  to the same source rendered without the assign at all**, proven by string
  equality of the two rendered fragments, and every 0.7.0 assertion in the
  component test file still passes unmodified. (Against 0.7.0's own bytes the
  difference is whitespace-only text nodes, for the HEEx reason probed above.)
- `mix.exs` is unchanged.

Verification: `mix quality` green, the named tests below passing, and
`git diff origin/main -- mix.exs CHANGELOG.md docs/adr/` empty.

### Key Discoveries:

- `StatifierUI.Expression` owns the richer kind vocabulary already
  (`lib/statifier_ui/expression.ex:101-115`), so a caller kind needs no new
  translation - only `{:one_of, _}` is a tag the module does not yet know.
- `row/3` (`lib/statifier_ui/expression.ex:570-585`) is the one place both the
  operator list and the candidate list are decided.
- The boolean value control already exists
  (`lib/statifier_ui/live/expression_input.ex:616-617`); the scout brief's
  claim that it does not is wrong.
- `keep_current/3` (`lib/statifier_ui/live/expression_input.ex:650-656`) is the
  existing precedent for "the author's choice is never dropped"; operators need
  the same treatment, in `Expression` rather than in the component, so the
  invariant holds for every consumer of `simple/2`.
- HEEx omits an attribute whose value is `nil`, so `data-declared-kind` costs
  nothing on an undeclared path - but it does **not** omit the whitespace around
  a conditional element, which is why the identity criterion is stated as
  with-assign / without-assign equality rather than as equality with 0.7.0's
  bytes.
- ADR-0007's sui-gcm amendment scopes presentation decisions to the component
  bead and its sui-94o Note records that eligibility now comes from predicator.
  Asking the grammar for a *declared* kind instead of an *observed* one changes
  which question is asked, not who answers it.

## What We're NOT Doing

- **No `statifier_datamodel` dependency, and no dependency at all.** `mix.exs`
  is untouched. Reading a datamodel document directly is a 033 candidate.
- **No version bump and no `CHANGELOG.md` edit.** 0.8.0 release prep is
  sui-oyy. This plan writes `changelog.d/sui-2vj.md` and nothing else.
- **No `docs/adr/` edit.** See "Open Questions": the analysis concludes no
  amendment is required, and writing one would be the operator's call in any
  case.
- **No rewriting of the author's source, ever** - not to coerce a string
  literal into a declared integer, not to drop an operator, not to canonicalise
  a value. A disagreement is reported and nothing else.
- **The declaration never contradicts the shape the source already has.** When
  the source's value is a list and the declaration is scalar (or the reverse),
  the observed shape wins for control and operator selection and the advisory
  reports the disagreement. Forcing a multiselect onto `plan == 'pro'` would
  write `plan == ['x']`, which is exactly the silent rewrite ADR-0007 rules
  out.
- **No change to the seeded clause `add_source/3` writes**
  (`lib/statifier_ui/live/expression_input.ex:863-872`). Adding a clause still
  seeds an empty string literal even for a path declared `:integer`. Making the
  seed kind-aware is a separate, arguably larger behaviour change; it is called
  out here so its absence is a decision rather than an oversight.
- **No `assets/` change.** The new stamps are inert to both hooks: the picklist
  hook dispatches on `[data-role]` and `[data-value-kind]`
  (`assets/js/expression_picklist.js:111,137,150,236`), and no new control
  shape and no new `data-role` is introduced. Should implementation discover a
  hook change is needed after all, note that `assets/` is in the manifest's
  `also_gated_paths`, so the phase touching it is a full-gate phase.
- **No stylesheet.** This package ships none (see sui-aln); the advisory row
  gets a class and the host styles it.

## Implementation Approach

The declaration is a *question asked of the grammar*, not an answer given
locally. Everything the declared kind decides is decided by handing that kind
to `Predicator.Simple` through `Expression.operators/1`, exactly as the
observed kind is today. Three things are genuinely local, and each is small,
named, and justified in the code:

1. **Which grammar kind a `{:one_of, values}` asks for.** `{:one_of, _}` is the
   caller map's own tag (sd-ADR-0001 decision 11 vocabulary), not a predicator
   kind, so it must be reduced to one. It is inferred from the declared values
   themselves: all binaries -> `:string`, all integers -> `:integer`, all
   floats (or a mix of integers and floats) -> `:float`, all booleans ->
   `:boolean`; an empty or otherwise mixed list -> `:string`. Inferring from
   the host's own data keeps the local judgement to arithmetic over values the
   host supplied rather than to a table about the grammar.
2. **Precedence between `:value_candidates` and `{:one_of, _}`.**
   `value_candidates` wins - it is the host's more specific statement about
   *this* path's offered values, and it already carries labels. `{:one_of, _}`
   fills the candidate list in only when `value_candidates` has no entry for
   the path.
3. **Which relative dates a date path offers.** A date declaration has no value
   list of its own, so the component offers a fixed, small set - the presentation
   choice ADR-0007's amendment leaves to the component bead. The set is built
   in `StatifierUI.Expression` (so it is testable without a browser) and every
   entry is validated against `Predicator.Simple.duration_units/0`, so a unit
   the grammar does not know is dropped rather than offered.

Three questions are answered from the declaration, and they are separate
questions with separate rules. Keeping them separate is what lets the operator
list follow the declaration - which is the bead's whole point - without ever
handing a control a value shape it cannot write.

**1. The operator list follows the declaration outright**, and the current
operator is always kept:

    operator kind =
      no declaration   -> the observed value kind (today's behaviour)
      {:one_of, values} -> the kind inferred from those values
      any other declaration -> the declaration itself

    offered operators = Expression.operators(operator kind), and then the
    entry for the row's own :op appended if that list does not already carry it

**2. The control follows the shape the value actually has.** A scalar value is
never handed a list control and a list value is never handed a scalar one,
because a control that wrote the other shape would rewrite the author's
expression - `plan == 'pro'` given a multiselect writes `plan == ['x']`:

    control kind =
      no declaration                              -> the observed value kind
      the declaration and the value are both lists,
        or both scalars                           -> the declaration
                                                     ({:one_of, _} contributes
                                                      its candidates, and the
                                                      candidate list alone is
                                                      what makes the select)
      otherwise                                   -> the observed value kind

**3. The advisory compares like with like.** The declaration describes the
*path*, and two operators put something other than the path's own kind on the
right of the clause, so the kind a value is expected to be is derived from the
declaration and the operator together:

    expected value kind =
      op is :in       -> {:list, the declared kind}
      op is :contains -> the member kind of a list declaration, else the
                         declaration (contains takes its collection on the
                         LEFT - ADR-0007's sui-94o Note - so the value beside
                         it is a member, not the collection)
      otherwise       -> the declaration

A `:value_kind` advisory renders when the expected kind and the observed kind
differ after folding `:integer` / `:float` to one number kind and
`:relative_date` to `:datetime`, comparing a list's member kind as well as its
listness.

An `:operator` advisory renders when the row's own operator was kept by rule 1
rather than offered by it - **except for `:contains`, which is never advised
against.** `contains` takes its collection on the left, so the declared kind of
the path says nothing about whether it belongs there, and
`plan CONTAINS 'pro'` on a path declared `{:list, :string}` is a correct
expression that must not be nagged about. That is one named exception, it
names no operator predicator does not, and it is the same reasoning ADR-0007's
sui-94o Note gives for `CONTAINS` widening upstream.

Phases split along the module boundary the repo already keeps: the pure half
first, the component second, the release-facing paperwork third. Each is
independently committable and leaves the full gate green.

## Phase 1: The declaration reaches the rows

### Overview

`StatifierUI.Expression` learns what a declared kind is, resolves it against
each clause's observed kind, and folds the answer into every row `simple/2`
returns. No LiveView change: the component keeps reading the row keys it reads
today, and the new keys are inert to it until Phase 2.

### Changes Required:

#### 1. New public vocabulary

**File**: `lib/statifier_ui/expression.ex`
**Changes**: a `t:declared_kind/0` typedoc, a `t:advisory/0` typedoc, three new
`t:row/0` keys, and one new public function.

```elixir
@typedoc """
A kind a host declares for a datamodel path, as the `:path_types` map carries
it: one of this module's own `t:value_kind/0`s, or `{:one_of, values}` for a
path whose values the host enumerates.

`{:one_of, _}` is the caller's tag rather than a grammar kind, so the operators
offered beside one are the operators of the kind its own values are: binaries
are `:string`, integers `:integer`, floats `:float`, booleans `:boolean`, and
an empty or mixed list falls back to `:string`.
"""
@type declared_kind :: value_kind() | {:one_of, [candidate() | term()]}

@typedoc """
Something worth telling an author about a clause, and never a reason to refuse
one. `:reason` is `:value_kind` when the value in the source is not of the kind
the host declared for the path, read through the operator, and `:operator` when
the operator in the source is one the declared kind's list does not offer -
which is the condition that keeps it offered anyway. `:contains` never raises
the second one: it takes its collection on the left, so the path's declared
kind says nothing about whether it belongs.
"""
@type advisory :: %{severity: :info, reason: :value_kind | :operator, message: String.t()}
```

The atoms are this module's; the component spells them for the DOM. Phase 2
maps `:value_kind` to `"value-kind"` explicitly rather than stringifying the
atom, because `to_string(:value_kind)` is `"value_kind"` and the stamped
vocabulary is hyphenated like every other `data-` value the component writes.

`t:row/0` gains `:declared_kind` (the declaration verbatim, or `nil`),
`:control_kind` (the resolved kind a renderer picks a control from), and
`:advisories` (a possibly empty list).

New public function, so the offered set is testable without a browser:

```elixir
@spec relative_date_candidates() :: [candidate()]
def relative_date_candidates()
```

Returning labelled `{:relative_date, units, direction}` values -
`1d ago`, `7d ago`, `30d ago`, `90d ago`, `7d from now`, `30d from now` -
each filtered out unless its unit is in `Predicator.Simple.duration_units/0`,
and the whole list empty when `simple_available?/0` is false.

`duration_units/0` is **not** added to `simple_available?/0`'s four-export
guard. That guard is documented as the condition under which the whole surface
degrades together, and widening it would silence `simple/2`, `operators/1` and
the write half over a function only this one feature calls. This function
guards itself instead:

```elixir
# The four-export guard is deliberately not widened for this: a predicator
# that can classify and write but predates `duration_units/0` should lose
# the offered dates, not the picklist. Same degradation discipline, held
# one function narrower.
def relative_date_candidates do
  module = simple_module()

  if simple_available?() and function_exported?(module, :duration_units, 0) do
    ...
  else
    []
  end
end
```

#### 2. `simple/2` takes `:path_types`

**File**: `lib/statifier_ui/expression.ex`
**Changes**: `classify/3` becomes `classify/4` and `row/3` becomes `row/4`,
carrying the map through. The `@doc` gains the option and a doctest:

```elixir
iex> {:ok, [row], nil} =
...>   StatifierUI.Expression.simple("plan == 'pro'", path_types: %{"plan" => :boolean})
iex> {row.control_kind, Enum.map(row.operators, & &1.lexeme)}
{:boolean, ["==", "===", "!=", "!==", "CONTAINS"]}
```

#### 3. The three rules, one private helper each

**File**: `lib/statifier_ui/expression.ex`
**Changes**: private helpers implementing rules 1, 2 and 3 of the
Implementation Approach, each with the reasoning at the definition.

```elixir
# Rule 1. The operator list is the declaration's own, asked of the grammar.
# `{:one_of, _}` is the caller's tag rather than a kind, so it is reduced to
# the kind of the values the caller enumerated.
defp operator_kind(nil, observed), do: observed
defp operator_kind({:one_of, values}, _observed), do: inferred_kind(values)
defp operator_kind(declared, _observed), do: declared

# Rule 1, second half. The operator the expression carries is offered whatever
# the declaration says. Narrowing that dropped it would leave a dropdown that
# cannot spell the row beneath it - the same invariant keep_current/3 holds
# for values, held one control to the left.
defp keep_current_operator(operators, module, op), do: ...

# Rule 2. The control follows the shape the value actually has: a scalar
# value is never handed a list control and a list value is never handed a
# scalar one, because either would write the other shape into the author's
# source. A disagreement is reported by an advisory instead, because ADR-0007
# rules out rewriting the expression to fit.
defp control_kind(nil, observed), do: observed
defp control_kind(declared, observed), do: ...

# Rule 3. What kind the value beside this operator is expected to be. `IN`
# takes a list of the path's kind and `CONTAINS` takes one member of it -
# contains holds its collection on the LEFT (ADR-0007's sui-94o Note) - so
# comparing the declaration to the value without reading the operator would
# report a mismatch on two clauses that are exactly right.
defp expected_kind(declared, :in), do: {:list, declared}
defp expected_kind({:list, member}, :contains), do: member
defp expected_kind(declared, _op), do: declared
```

`keep_current_operator/3` appends the current operator's entry (built the way
`operator_label/2` already finds one, over the observed kind's list, falling
back to a `:list` probe for `:in`) when the narrowed list has no entry for it.

#### 4. Tests

**File**: `test/statifier_ui/expression_test.exs`
**Changes**: a new `describe "declared path kinds"` block.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality` is green (format, credo, dialyzer, doctor, full suite with
      coverage).
- [x] `test "a declared kind decides the operator list, and the grammar still answers it"` -
      `simple("plan == 'pro'", path_types: %{"plan" => :boolean})` returns a row
      whose `operators` map to the same `:op`s as
      `Expression.operators(:boolean)`, and `refute :gt in ops`.
- [x] `test "an integer declaration offers exactly the integer operators"` -
      asserts set equality with `Expression.operators(:integer)` for the source
      `plan == 'pro'`, which is the bead's integer criterion stated in the only
      form the grammar makes observable.
- [x] `test "the operator the source carries is offered even when the declaration would drop it"` -
      `simple("plan CONTAINS 'pro'", path_types: %{"plan" => {:list, :string}})`
      offers `[:in, :contains]`: the declared list kind's own single operator,
      plus the row's `:op` kept because the source carries it.
- [x] `test "a kept CONTAINS raises no operator advisory"` - the same row's
      `advisories` carry no `:operator` entry, because `contains` holds its
      collection on the left.
- [x] `test "an operator outside a declared kind is kept, and says so"` -
      `simple("plan > 'pro'", path_types: %{"plan" => :boolean})` offers `:gt`
      (which `Expression.operators(:boolean)` does not) and carries one
      `%{reason: :operator}` advisory.
- [x] `test "IN and CONTAINS are read through the operator, not against it"` -
      `simple("step IN ['payment']", path_types: %{"step" => :string})` and
      `simple("plan CONTAINS 'pro'", path_types: %{"plan" => {:list, :string}})`
      both carry **no** `:value_kind` advisory: a list of strings is what `IN`
      expects beside a string-declared path, and a string is what `CONTAINS`
      expects beside a list-of-strings one.
- [x] `test "a one_of declaration asks the grammar for the kind of its own values"` -
      `{:one_of, [1, 2]}` yields the `:integer` operator set,
      `{:one_of, ["a"]}` the `:string` set, `{:one_of, []}` the `:string` set.
- [x] `test "value_candidates win over a one_of declaration for the same path"` -
      both supplied, and `row.candidates` are the `value_candidates` entries.
- [x] `test "a one_of declaration fills the candidate list when value_candidates has no entry"`.
- [x] `test "a date declaration offers the relative-date set"` - `row.candidates`
      equal `Expression.relative_date_candidates()`, which is non-empty and whose
      every value round-trips through `value_source/2`.
- [x] `test "every offered relative date uses a unit the grammar knows"` - each
      candidate's units are members of `Predicator.Simple.duration_units/0`.
- [x] `test "a value that disagrees with its declaration raises an advisory, not an error"` -
      `simple("amount >= 500", path_types: %{"amount" => :string})` still returns
      `{:ok, [row], nil}` with `[%{severity: :info, reason: :value_kind}] = row.advisories`.
- [x] `test "a list value is not given a scalar declaration's control kind"` -
      `simple("plan == 'pro'", path_types: %{"plan" => {:list, :string}})` has
      `control_kind` `:string` (the observed scalar, since a scalar value must
      not be handed a list control) and one `:value_kind` advisory.
- [x] `test "relative_date_candidates/0 is empty when the resolved module lacks duration_units/0"` -
      the `:predicator_simple` key pointed at a stub exporting the four guarded
      functions and not `duration_units/0`, asserted through the same
      `Application.put_env` pattern the existing degraded-source block uses.
- [x] `test "no path_types is exactly today's row"` - `simple(source)` and
      `simple(source, path_types: %{})` return equal rows for a table of
      sources, and `declared_kind` is `nil` with `advisories` empty.
- [x] `test "an unusable predicator still degrades to :outside"` - the existing
      degraded-source describe block passes `path_types` and still gets
      `:outside`.

#### Manual Verification:

- [ ] The new moduledoc / `@doc` prose reads as this module's voice and cites
      ADR-0007 where it makes a judgement.
- [ ] The relative-date set is a sensible default offer for a signup or
      card-processing date field.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate.

---

## Phase 2: The component takes `path_types` and draws the difference

### Overview

The new assign, the control cascade moving from the observed kind to the
resolved one, the relative-date route through `term/3`, the advisory rows, and
the moduledoc's data-attribute table.

### Changes Required:

#### 1. The assign

**File**: `lib/statifier_ui/live/expression_input.ex`
**Changes**: a new `attr`, and the matching `Map.put_new/3` in `normalize/1`
(the seam calls this as a bare function, so `attr` defaults never run):

```elixir
attr(:path_types, :map,
  default: %{},
  doc:
    "kinds the host declares per clause path, as `%{path => kind | {:list, kind} | " <>
      "{:one_of, values}}`. A declared kind decides the operator list and the value " <>
      "control; it never rewrites the author's source."
)
```

`classify/1` passes it into `Expression.simple/2` beside `:value_candidates`.

#### 2. The control cascade reads the resolved kind

**File**: `lib/statifier_ui/live/expression_input.ex`
**Changes**: `value_control/5` switches on `row.control_kind` rather than
`row.value_kind`, and `value_select/6` and `multiselect/4` build candidate
terms with `row.control_kind`. The three helpers that *measure how the current
value is spelled* - `hole/2`, `wrapper/2`, `escapes/4`, and `text_value/1` -
keep reading `row.value_kind`, because they describe the value that is there,
not the one the host declared. A comment says exactly that at the split.

#### 3. `term/3` gains one narrow route

**File**: `lib/statifier_ui/live/expression_input.ex`
**Changes**: a host value that is already a `Predicator.Simple` structural
relative date is passed through as itself, which is the whole route a date
candidate set needs:

```elixir
# A relative date has no bare-term spelling to build from - `30d ago` is a
# tuple in the subset's own vocabulary - so a candidate carrying one is
# already in the form a clause holds. This is the only pre-built value the
# component accepts, and it is accepted for exactly that reason.
defp term(_kind, _style, {:relative_date, _units, _direction} = value), do: {:ok, value}
```

#### 4. The advisory rows

**File**: `lib/statifier_ui/live/expression_input.ex`
**Changes**: `clauses/4` carries `declared_kind` and `advisories` onto each
clause map; the clause row renders, after the value control:

```heex
<p
  :for={advisory <- clause.advisories}
  class="statifier-ui-expression-advisory"
  role="status"
  data-advisory={advisory_reason(advisory.reason)}
  data-severity={advisory.severity}
>
  {advisory.message}
</p>
```

with the reason spelled for the DOM by a two-clause mapping rather than by
stringifying the atom, since `to_string(:value_kind)` is `"value_kind"` and
every other stamped value this component writes is hyphenated:

```elixir
# The atom is the module's word and the attribute is the DOM's. Spelling the
# two apart here keeps `data-advisory` in the same hyphenated vocabulary as
# `data-value-kind` and `data-error-position`.
defp advisory_reason(:value_kind), do: "value-kind"
defp advisory_reason(:operator), do: "operator"
```

and the clause `<div>` gains `data-declared-kind={clause.declared_kind}`, where
`clauses/4` has already spelled the declaration for the DOM - a kind is not an
attribute value until something writes it, and a tuple is not one at all:

```elixir
# The declaration as one word, because an attribute is a string: a list says
# what it is a list of, and a one_of says only that it is one - the values
# themselves are already the options of the select beside it.
defp declared_kind_attribute(nil), do: nil
defp declared_kind_attribute({:one_of, _values}), do: "one-of"
defp declared_kind_attribute({:list, nil}), do: "list"
defp declared_kind_attribute({:list, member}), do: "list:" <> to_string(member)
defp declared_kind_attribute(kind), do: to_string(kind)
```

`nil` when the path is undeclared, which HEEx omits entirely. That omission is
what makes Phase 2's identity criterion mechanical for the attribute half.

#### 5. The stamped contract

**File**: `lib/statifier_ui/live/expression_input.ex`
**Changes**: three rows added to the moduledoc's data-attribute table, which is
the testable surface ADR-0007 names:

| `data-declared-kind` | a clause row | the kind the host declared for its path (`integer`, `list:string`, `one-of`, ...), absent when none |
| `data-advisory` | an advisory row | `value-kind` or `operator`, why it is shown |
| `data-severity` | an advisory row | `info` - an advisory never blocks |

plus a short moduledoc section on what a declaration does and does not do.

#### 6. Tests

**File**: `test/statifier_ui/live/expression_input_test.exs`
**Changes**: a `describe "declared path kinds"` block, reusing the existing
`seam_html/1`, `picklist_html/3` and `picklist_controls/1` helpers. A new
`typed_html/4` helper wraps `seam_html/1` with a `path_types` override.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality` is green.
- [x] `test "no path_types renders exactly what the assign-less call renders"` -
      for a table of sources (`plan == 'pro'`,
      `status == 'active' AND amount >= 500`, `step IN ['payment']`,
      `len(plan) > 0`, `amount >= >=`),
      `picklist_html(source, paths, candidates) == typed_html(source, paths, candidates, %{})`
      **and** equality also holds against a map declaring only an unrelated path.
      String equality of the rendered fragments is the proof.
- [x] Every 0.7.0 assertion still holds verbatim:
      `git diff -U0 origin/main -- test/statifier_ui/live/expression_input_test.exs
      test/statifier_ui/expression_test.exs | grep '^-[^-]'` is empty, so the
      branch only adds test lines and never edits one.
- [x] `test "a boolean path renders the two-option control the component already has"` -
      `path_types: %{"plan" => :boolean}` over `plan == 'pro'` renders
      `data-value-kind="select"` with options whose sources are `plan == true`
      and `plan == false`, and the author's `plan == 'pro'` still selected.
- [x] `test "a one_of path renders a select"` - the bead's criterion:
      `path_types: %{"status" => {:one_of, ["active", "pending"]}}` with no
      `value_candidates` renders `data-value-kind="select"` and an option whose
      value is `status == 'pending'`.
- [x] `test "an integer path offers the integer operators"` - over
      `amount >= 500` with `path_types: %{"amount" => :integer}`, the operator
      control's option labels equal
      `Enum.map(Expression.operators(:integer), & &1.label)`, read back with
      `picklist_controls/1`.
- [x] `test "a boolean path offers no ordered comparison"` - over
      `plan == 'pro'` with `path_types: %{"plan" => :boolean}`, the operator
      control's labels equal `Expression.operators(:boolean)`'s, and the label
      of `:gt` is absent - the discriminating case, since the grammar's ordered
      scalar kinds all carry one list.
- [x] `test "the operator in the source is never dropped from the dropdown"` -
      `plan CONTAINS 'pro'` with `path_types: %{"plan" => {:list, :string}}`
      renders an operator option carrying the source verbatim and marked
      `selected`, beside the declared list kind's own `is one of`.
- [x] `test "the declared kind is stamped on the clause row"` -
      `data-declared-kind="integer"`, `data-declared-kind="list:string"` and
      `data-declared-kind="one-of"` each render for their declaration, and no
      such attribute appears for an undeclared path.
- [x] `test "a date path offers the relative-date set"` - options include one
      whose value is `created_at >= 7d ago`.
- [x] `test "a list declaration on a list value reaches the multiselect"` -
      `step IN ['payment']` with `path_types: %{"step" => {:list, :string}}`
      and candidates renders `data-value-kind="multiselect"`; without
      candidates, `readonly`.
- [x] `test "a list declaration on a scalar value does not"` - `plan == 'pro'`
      with `path_types: %{"plan" => {:list, :string}}` renders the free-text
      control, never a multiselect, so no control can write `plan == ['x']`.
- [x] `test "a disagreement is advisory and nothing else"` - `amount >= 500`
      with `path_types: %{"amount" => :string}` renders
      `data-advisory="value-kind"`, `data-severity="info"`, still
      `data-subset="inside"`, still `data-mode="picklist"`, and the input's
      `value` is the untouched source.
- [x] `test "an advisory never appears for an agreeing declaration"`.
- [x] `test "value_candidates still win over a one_of for the same path"` - the
      rendered option labels are the `value_candidates` labels.
- [x] `test "the sui-ivh recoverability property survives a declaration"` - the
      existing "every single-choice control offers the current source, and
      marks it" property re-run with a `path_types` map covering every path.
- [x] `git diff --stat origin/main -- mix.exs` is empty.
- [x] `git diff --stat origin/main -- assets/` is empty (or, if implementation
      proves a hook change necessary, that change is in this phase and the full
      gate covers it - `assets/` is an `also_gated_paths` entry).

#### Manual Verification:

- [ ] Rendered by hand in a host page: a boolean path's dropdown reads
      sensibly, and an advisory row is legible without a stylesheet.
- [ ] The advisory wording names the path and both kinds, and reads as advice
      rather than as an error.

**Implementation Note**: loop gate between edits, full gate as the phase gate.

---

## Phase 3: The changelog fragment and the release-facing prose

### Overview

The public API addition needs a fragment; nothing else about the release moves.

### Changes Required:

#### 1. The fragment

**File**: `changelog.d/sui-2vj.md` (new)
**Changes**: exactly the shape `changelog.d/README.md` prescribes - a Keep a
Changelog heading and one line per change, present tense, no nested bullets:

```markdown
### Added

- `StatifierUI.Live.ExpressionInput.expression_input/1` takes a `:path_types`
  assign, `%{path => kind | {:list, kind} | {:one_of, values}}`, which decides a
  clause's operator list and value control from the kind the host declares
  rather than from the literal in the source.
- `StatifierUI.Expression.simple/2` takes a `:path_types` option, and each row
  it returns carries `:declared_kind`, `:control_kind` and `:advisories`.
- `StatifierUI.Expression.relative_date_candidates/0` returns the relative
  dates a date-declared path offers.
```

#### 2. Nothing else

`CHANGELOG.md`, `mix.exs`'s `@version`, and `docs/adr/` are untouched, per the
campaign's constraints.

### Success Criteria:

#### Automated Verification:

- [x] `mix quality` is green.
- [x] `changelog.d/sui-2vj.md` exists and uses only standard Keep a Changelog
      headings.
- [x] `git diff --stat origin/main -- mix.exs CHANGELOG.md docs/adr/` is empty.
- [x] The terminology scan from the umbrella's `docs/terminology-firewall.md`
      is clean over the branch's diff, with a positive control.

#### Manual Verification:

- [ ] Every example added anywhere in this branch - code, doctest, test, prose -
      is a card-processing or signup example (`card.brand`, `amount`, `plan`,
      `step`, `status`, `created_at`, `myapp:*`).

---

## Testing Strategy

### Unit Tests:

- `test/statifier_ui/expression_test.exs` carries the pure half: resolution,
  narrowing, keep-current, `{:one_of, _}` inference, candidate precedence, the
  relative-date set, advisories, and the "no map is today's answer" equality.
  It also re-runs the existing degraded-source block with a `path_types` map, so
  a host on an older predicator still gets `:outside` rather than a crash.
- `test/statifier_ui/live/expression_input_test.exs` carries the rendered half,
  asserting on stamped attributes and option values rather than on markup shape,
  per the repo's "rendering is verified by what it renders" convention. The
  byte-identical criterion is a string equality between two renders, which is
  the strongest proof available without a 0.7.0 checkout.
- Edge cases with an explicit test each: an empty `{:one_of, []}`; a mixed-type
  `{:one_of, [1, "a"]}`; a declaration for a path no clause uses; a declaration
  whose listness disagrees with the value in both directions; a `{:list, nil}`
  observed kind (an empty list literal) under a scalar declaration.

### Manual Testing Steps:

1. In a host page (or the sb editor), render a `cond` field with
   `path_types: %{"plan" => {:one_of, ["free", "pro"]}, "amount" => :integer,
   "created_at" => :date}` and confirm each control matches its declaration.
2. Type `amount >= 'five'` into the text field and switch back to picklists:
   the advisory appears, the source is unchanged, and the operator dropdown
   still spells the row.
3. Remove the assign and confirm the field is indistinguishable from 0.7.0.

## Open Questions

None of these blocks implementation; each is recorded because no human was
available during planning and the plan takes the stated default.

1. **Is an ADR-0007 amendment required? The analysis says no** - see the
   explicit reasoning below - **and this plan writes no `docs/adr/` change.**
   The operator may still want a Note recording (a) the local choice of which
   relative dates a date path offers and (b) the `{:one_of, _}` reduction rule,
   both of which are judgements this package makes. Default taken: no ADR
   change, and the reasoning lives in the code comments and this plan.
2. **The offered relative-date set is a guess at a good default**
   (`1d/7d/30d/90d ago`, `7d/30d from now`). A host cannot yet override it
   except by supplying `value_candidates` for the path. Default taken: no
   override assign in this bead; if hosts want one it is a later, additive
   assign.
3. **`{:one_of, _}` with a mixed integer/float list** is reduced to `:float`,
   and an otherwise mixed list to `:string`. Default taken as recommended;
   both reach the same grammar kind (`:number`) today, so the distinction is
   only visible if predicator ever splits them.
4. **The bead's acceptance wording "an integer path offers the numeric
   operators only" is not observable as written** - predicator returns the same
   operator set for `:number`, `:string`, `:date`, `:datetime` and `:duration`.
   Default taken: the test asserts equality with `Expression.operators(:integer)`
   and the discriminating cases are `:boolean` and `{:list, _}`. The operator
   may want the bead's criterion reworded.
5. **The bead's "no map renders exactly the 0.7.0 markup" is met modulo
   whitespace.** Any advisory element added to the template contributes
   whitespace-only text nodes even when it renders nothing (probed; see Current
   State Analysis). Default taken: the criterion is proven as with-assign /
   without-assign string equality plus an additions-only test diff. The operator
   may want the bead's criterion reworded, or - if literal 0.7.0 bytes are
   required - the advisory dropped from this bead, which would remove the
   feature the bead asks for.
6. **`add_source/3` still seeds a string literal** for a path declared
   `:integer`, so "add clause" on a numeric path produces `amount == ''` and an
   immediate advisory. Default taken: out of scope, recorded in "What We're NOT
   Doing"; a kind-aware seed is a separate bead.

### Why no ADR amendment is required

ADR-0007's accepted text and its sui-gcm amendment rule three things that this
change is measured against, and it satisfies all three.

- **No second representation.** `path_types` is an *input* the host supplies on
  every render, exactly as `:candidates` and `:value_candidates` are. Nothing
  is stored, nothing survives between renders, and the source string remains the
  only representation of the condition.
- **The component never refuses or rewrites the author's expression.** The
  declaration is deliberately subordinate to the source: the operator in the
  source is always offered, the value in the source is always kept and selected,
  a scalar value is never handed a list control, and a disagreement produces an
  advisory rather than a coercion.
- **The named local exception stays closed.** The sui-94o Note records that
  operator eligibility now comes from `Predicator.Simple.operators/1`. This
  change asks that same function a different question - about the declared kind
  instead of the observed one - and adds no table of operators. The two local
  judgements it does add (which grammar kind a `{:one_of, _}` reduces to, and
  which relative dates to offer) name no operator, so neither can offer one
  predicator would reject; and the second is presentation, which the amendment's
  "What this does not decide" paragraph leaves to the component bead.

## References

- Bead: `sui-2vj` (campaign 032, lane U; blocks `sui-oyy` and `sui-aln`)
- Related ADRs: `docs/adr/0007-text-first-authoring.md` (the sui-gcm amendment
  and its sui-94o Note), `docs/adr/0004-one-package-with-optional-integrations.md` (the one-way
  dependency arrow),
  `docs/adr/0009-javascript-ships-as-source.md`
- The pure half: `lib/statifier_ui/expression.ex:101-115`, `:334-343`,
  `:396-406`, `:570-585`, `:674-678`
- The component: `lib/statifier_ui/live/expression_input.ex:579-603`,
  `:605-622`, `:650-656`, `:819-821`, `:827-841`
- Upstream vocabulary: `deps/predicator/lib/predicator/simple.ex:358-460`
- Similar implementation: `docs/plans/260902-sui-wqr-expression-input.md`
- Changelog convention: `changelog.d/README.md`

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The new moduledoc / `@doc` prose reads as this module's voice and cites
      ADR-0007 where it makes a judgement.
- [ ] The relative-date set is a sensible default offer for a signup or
      card-processing date field.

**Implementation Note**: Use `mix quality --profile loop` between edits; the
full `mix quality` is the phase gate.

---

### Phase 2

- [ ] Rendered by hand in a host page: a boolean path's dropdown reads
      sensibly, and an advisory row is legible without a stylesheet.
- [ ] The advisory wording names the path and both kinds, and reads as advice
      rather than as an error.

**Implementation Note**: loop gate between edits, full gate as the phase gate.

---

### Phase 3

- [ ] Every example added anywhere in this branch - code, doctest, test, prose -
      is a card-processing or signup example (`card.brand`, `amount`, `plan`,
      `step`, `status`, `created_at`, `myapp:*`).

---
