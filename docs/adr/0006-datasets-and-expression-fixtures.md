# ADR-0006: Datasets and expression fixtures

Status: accepted (2026-08-16); corpus amended 2026-08-27 (sui-6ld) - the
worked example moved off an ad-hoc age-eligibility domain and onto the
family's canonical example domains; dataset names, expression names, and
example values only, no part of the contract changed
Amendment status: a **proposed** second amendment (2026-08-27, sui-0of)
reaches two illustrative names the first pass left behind - see the note
below; the accepted text is unchanged until it is read and accepted

**Amendment note.** *(2026-08-27, sui-6ld, executing the fleet ruling of the
same date.)* The record originally illustrated both new keys with an
age-eligibility corpus - datasets `"minor"` and `"adult-us"`, the expression
`user.age >= 18 and user.country == 'US'`. That domain is not one of the two
the family uses for examples (card processing, and a signup wizard with A/B),
and unlike the rest of this package's illustrations it appeared inside the
Decision section rather than in prose around it. Illustrations elsewhere are
fix-forward; decision text is not, so the substitution is recorded here
rather than made silently.

The corpus below is the signup-wizard equivalent, chosen to preserve the
original's semantic coverage one for one: a compound predicate over a numeric
comparison and a string equality (`is-complete-variant-b`), two datasets that
make it false and true respectively (`variant-a-early`, `variant-b-complete`),
and a non-boolean, sometimes-absent field exercising both the `$date` and the
`$undefined` spellings (`started-date`). Every claim the record makes about
datasets, expressions, matching, `expect` encoding, versioning, and the four
powered features is unchanged - only the names and values the claims are
demonstrated with. The same substitution was applied in the same commit to the
fixture files and tests that carry this corpus, so the executable examples and
the record continue to agree.

**Second amendment, proposed 2026-08-27 (sui-0of) - two sites the first one
did not reach.** *Proposed, not accepted; nothing below this note has been
edited.* The sui-6ld pass moved the worked corpus in the Decision and left
two illustrative names elsewhere in the record off the canonical domains:

| Site | Accepted text | Proposed |
|---|---|---|
| Alternatives considered, "Reuse scenarios as the `expect` axis" | every pointed situation an expression wants (`"variant-a-early"`, `"expired-card"`) | (`"variant-a-early"`, `"over-budget"`) |
| Open questions carried, "Dataset-overlays-a-base-scenario ergonomics" | `"variant-b-complete"` as scenario `"gold-tier-user"` plus overrides | as scenario `"within-budget-account"` plus overrides |

`"expired-card"` is card-processing flavored and so is not off-domain in
subject, but it names no dataset that exists anywhere in the repo, which is
the reason to move it: `"over-budget"` is a dataset the fixture-bundles
guide actually carries, so a reader who goes looking finds it. The
`"gold-tier-user"` pairing is the stronger of the two - it is a loyalty tier
in a signup-wizard sentence, off-domain twice over - and
`"within-budget-account"` is the same substitution proposed for ADR-0003.

Names and example values only. Nothing about the overlay question, the
rejected alternatives, or the contract changes.

## Context

ADR-0003 settled the fixtures contract: one bundle per chart, two maps
(scenarios and events), delivered by behaviour or JSON sidecar, consumed as
one struct. It also accepted a cost honestly: examples "can drift from the
host's real payloads with no mechanism here to detect it."

Per user direction (2026-08-16), a family of expression-centric features
needs something the bundle does not carry. The scratchpad wants to evaluate
one predicator expression across many situations and render the results as a
truth table. Simulation wants to annotate a chart's guards with what they
evaluate to under several situations at once. The explorer wants more tier-3
variants than the handful of full scenarios a host writes. And fixture
documentation wants to be executable, so that an example claiming
`signup.steps_completed >= 3 and signup.variant == 'B'` is true for a
completed variant-B signup is checked by a test suite rather than trusted.

Two units are missing: a named, reusable situation smaller in intent than a
full scenario, and a named expression that carries expected results. This
record extends ADR-0003 with both. It contradicts nothing in that record;
per ADR-0001's amendment rule it is a new ADR rather than a rewrite, and
ADR-0003 stays accepted as it stands.

## Decision

**The fixture bundle gains two additive keys, both optional, both maps:**

- **Datasets**: named, reusable datamodel records - each a name (for example
  `"variant-a-early"`, `"variant-b-complete"`) mapped to an example
  datamodel for that situation. Datasets are shared across expressions
  rather than inlined per expression: a truth table is only a matrix
  because its columns are the same named situations for every row, the
  same situation exercises many expressions without duplication, and a
  dataset name is a column header a human can read.
- **Expressions**: named entries each carrying a free-standing predicator
  `"source"` string and an `"expect"` map keyed by dataset name:

  ```json
  {
    "source": "signup.steps_completed >= 3 and signup.variant == 'B'",
    "expect": {"variant-a-early": false, "variant-b-complete": true}
  }
  ```

  An `expect` map may cover any subset of the datasets; an absent key means
  no expectation is stated for that dataset. A key naming no dataset is a
  dangling reference, flagged by lint.

**Expressions are free-standing, matched to chart guards by source-text
equality only - never by index.** An expression is its own artifact first: a
scratchpad seed, a documented example of a host function, a truth table row.
When its source text is byte-equal to a guard expression in the chart, the
match lets simulation annotate that guard per dataset and lets the editor
surface the expression's expectations at the guard. Index-based matching is
ruled out because SCXML transitions have no ids to name, and the engine's
`t_index`/`c_index` identities are stable only within one compiled Machine
(ADR-0005): they are document-order positions, and any edit above a
transition shifts them. An index-matched fixture would silently pin the
wrong guard after an edit - an active misread, worse than no match. Source
text is the one identity the author controls and can see in both files.

**An unmatched expression degrades to a lint warning, not an error.** The
same severity logic as ADR-0003's fixture lint applies: absence of a match
is weaker evidence than presence of a contradiction. Free-standing
expressions that match no guard are a feature of this contract, not a
defect, so unmatched must be a legal state; the warning exists for the
near-miss case, where an expression looks like it was meant to track a
guard whose text has drifted (reformatting included - matching is exact).

**`expect` values are plain JSON plus the sidecar spelling for undefined.**
Predicator's value domain is closed (ADR-0002, via predicator
`Predicator.Types.value/0`), and ADR-0005 already fixed its JSON encoding:
native values map to themselves, and the non-native members use the
reserved `$`-prefixed one-key shapes - in particular `{"$undefined": true}`
where an expression is expected to evaluate to the undefined sentinel, and
`{"$date": ...}`, `{"$datetime": ...}`, `{"$duration": {...}}` where the
expected value is one of the non-native types. One encoding, shared with
the wire format; this record introduces no second spelling.

**The sidecar version stays 1.** The criterion is ADR-0005's versioning
rule, adopted here for the sidecar explicitly: consumers ignore unknown
keys, additive change is not a version bump, and a bump means a consumer of
the old version would misread the file. `"datasets"` and `"expressions"`
are additive top-level keys; a consumer that does not know them reads
scenarios and events exactly as before and misreads nothing. The bead
phrased this as "the loader decides", and the loader's answer is
determined by the fact that no loader has shipped (ADR-0003's module names
are intent; the repository is a scaffold): the first loader is written
with these keys and the ignore-unknown-keys discipline, so no version-1
consumer exists that could reject or misread them. Had a strict version-1
loader already shipped, its rejection would have been the bump trigger;
none has.

**What the two keys power**, recorded so the features cite this number:

- **Scratchpad truth tables**: one expression evaluated across all datasets,
  rendered as a result matrix - datasets as columns, expressions as rows.
- **Executable examples**: the UI flags `expect` mismatches live as the
  author types, and a test helper / mix task runs every expectation in the
  host's suite, so fixture documentation cannot rot silently. This is the
  direct, opt-in mitigation of the example-drift cost ADR-0003 accepted
  with "no mechanism here to detect it": an expression with expectations
  is the mechanism.
- **Per-dataset guard annotation in simulation**: a guard matched by source
  text shows its truth value under each dataset alongside the chart.
- **Datasets as tier-3 variants in the explorer**: authoring mode's tier-3
  source (ADR-0003's tier model) can offer datasets alongside scenarios,
  multiplying the situations a host can flip between without authoring
  full scenarios.

**Scope boundary.** Implementation is not sui-t36 scope. The Livebook
inspector needs scenarios and events only - its palette, explorer, and
event log draw nothing from datasets or expressions. The two keys are
implemented alongside the scratchpad and editor-intelligence work, which
is where their first consumers live.

**What this decision does not do:**

- It does not change scenarios or events, their shapes, or either delivery
  path. Both ADR-0003 maps mean what they meant; a bundle with neither new
  key is exactly as valid as before.
- It does not touch the engine. Evaluating an expression against a dataset
  is predicator's pure evaluation returning `{:ok, value} | {:error, e}`
  (ADR-0002); a mismatch or an evaluation error is data the UI and the
  test helper render. Any engine-side want this surfaces is an `st-` or
  `px-` bead, per ADR-0002.
- It does not decide whether expression fixtures join the language-neutral
  spec normatively; that is carried as an open question below.
- It does not add a schema language, for the same reasons as ADR-0003:
  datasets are examples, expectations are values, and a schema layer stays
  optional-later.

## Consequences

- ADR-0003's accepted drift cost gains a countermeasure: any host that
  writes expressions with expectations gets a suite-enforced check that its
  fixture documentation still tells the truth. The residual risk moves to
  the author deleting or ignoring a failing expectation - drift now
  surfaces as a red test rather than silence, which is the improvement.
- Expect maps are themselves examples and can encode a wrong belief; the
  executable-example mechanism catches disagreement between expectation and
  evaluation, not between either and the host's production reality. That
  remaining gap is ADR-0003's inferred-shapes cost, unchanged.
- Source-text equality is brittle under formatting edits: reformatting a
  guard silently unmatches its expression, degrading annotation to a lint
  warning that can be ignored. Accepted for the same reason the fixture
  lint is a warning at all; the alternative identities (indexes, invented
  ids) fail worse, as argued above.
- Scenarios and datasets are two named-map families that look alike, and
  the distinction has to be teachable: a scenario is a complete example of
  the host-supplied datamodel for running a chart; a dataset is a
  situation for evaluating expressions, and may be as small as the
  expression needs. The overlay open question below is where the two may
  partially converge; until it resolves, duplication between a dataset and
  a near-identical scenario is authored by hand.
- Version 1 now carries four possible top-level keys, and the
  ignore-unknown-keys rule is load-bearing for the sidecar, not only for
  the wire format. The first loader must implement it, and its tests are
  where "additive keys parse cleanly" is verified rather than assumed.

**Alternatives considered:**

- **Inline datamodels per expression** (each expression carries its own
  example data): no shared axis, so no truth-table matrix; the same
  situation is copied into every expression that uses it and the copies
  drift. Rejected.
- **Reuse scenarios as the `expect` axis** (no separate datasets key):
  scenarios are chart-complete datamodels, and every pointed situation an
  expression wants ("variant-a-early", "expired-card") would pollute the
  scenario list every chart-level consumer renders. Rejected as the base
  shape; the overlay question keeps convergence open without coupling the
  lists.
- **Match guards by `t_index`**: shifts under edit and silently pins the
  wrong guard, as argued in the decision. Rejected.
- **Match guards by author-supplied transition ids**: SCXML gives
  transitions no id attribute, so this invents a chart-annotation
  convention the engine ignores - decorating the source of truth for
  fixture bookkeeping, against text-first. Rejected.
- **Unmatched expression as an error**: punishes free-standing expressions,
  which are a purpose of the key, not a defect of it. Rejected.
- **Bump the sidecar to version 2 defensively**: forces every consumer to
  handle two versions for a change none can misread, and contradicts the
  additive-change rule adopted from ADR-0005. Rejected.

**Open questions carried, not resolved here:**

- **Dataset-overlays-a-base-scenario ergonomics.** Whether a dataset may
  declare itself a delta over a named scenario (for example
  `"variant-b-complete"` as scenario `"gold-tier-user"` plus overrides),
  which would remove the
  hand-duplication the consequences above accept - and what it entails:
  merge depth, a spelling for key removal, and whether overlay resolution
  happens in the loader or per consumer. A call for the scratchpad /
  editor-intelligence beads that first feel the duplication.
- **Whether expression fixtures join the sui-w1b language-neutral spec
  alongside the sidecar.** ADR-0005 settled that the sidecar's shape joins
  `docs/wire-format.md` as a companion contract and that `session.start`
  may carry the bundle inline verbatim - so the additive keys already ride
  the wire either way. The open question is normative status: whether a
  conformant non-Elixir interpreter is expected to evaluate `expect` maps,
  making expectations part of cross-language conformance the way golden
  traces are, or the keys remain UI-side annotation the spec merely
  tolerates. Settled when the spec document is written, with this record
  keeping both keys plain JSON so nothing here forecloses it.
