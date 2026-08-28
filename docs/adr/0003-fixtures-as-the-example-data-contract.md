# ADR-0003: Fixtures as the example-data contract

Status: accepted (2026-08-16)
Amendment status: **proposed** (2026-08-27, sui-0of) - see below; the
accepted text is unchanged and stays authoritative until the amendment is
read and accepted.

## Amendment proposed 2026-08-27 (sui-0of): canonical example domains

*Proposed, not accepted. Nothing below this section has been edited.*

The fleet ruling of 2026-08-27 fixes exactly two example domains for the
whole family - credit-card processing (accounts, budgets, transactions,
authorization and settlement) and a signup wizard with A/B testing (steps,
variants, conversion events) - and retires per-repo ad-hoc domains. This
record's illustrations predate that ruling and are off it.

`sui-6ld` set the precedent that a substitution reaching an accepted ADR's
own text is recorded as a dated amendment rather than made silently. This
amendment goes one step further and does not edit the accepted text at
all: it proposes the substitution and leaves the reading to the operator.

**Names and example values only. No part of the contract changes.** Two
maps, two delivery paths, one struct; the sidecar shape, the version field,
the inference rule, and every rejected alternative all stand exactly as
accepted. Only the strings the claims are demonstrated with move.

Proposed substitutions, by site:

| Site | Accepted text | Proposed |
|---|---|---|
| Decision, "Shape", scenarios bullet | scenario `"gold-tier-user"` | `"within-budget-account"` |
| Decision, "Shape", events bullet | event `"payment.success"` mapped to `{"amount": 1999, "currency": "USD"}` | `"authorize.approved"` mapped to `{"amount_cents": 1999, "currency": "USD"}` |
| Decision, "Delivery", sidecar bullet | a chart at `payment.scxml` may carry `payment.fixtures.json` | `authorization.scxml` may carry `authorization.fixtures.json` |
| Consequences, first bullet | `_event.data.` inside `<transition event="payment.success">` | `<transition event="authorize.approved">` |

`"gold-tier-user"` is a loyalty tier, which belongs to neither canonical
domain; `"within-budget-account"` is the card-processing situation the same
claim needs (a complete host-supplied datamodel for one account). The event
rename carries `amount` to `amount_cents` with it, because the canonical
card-processing examples are minor-unit integers throughout and an example
payload that disagrees with them teaches the wrong shape.

On acceptance, the same substitution applies to whatever still carries this
corpus, so the record and the executable examples continue to agree. As of
this amendment that is `test/support/fixtures/payment.fixtures.json`,
`test/support/fixtures/payment_source.ex`, and the tests that read them;
`lib/` moved under `sui-v91` and `docs/fixture-bundles.md` under `sui-6ez`.

## Context

Predicator is dynamically typed and non-evaluative (statifier ADR-0004,
adopted here by ADR-0002), so an author writing a guard or an assignment gets
no ambient information about what is in scope. What is knowable about a
chart's datamodel comes in three tiers, identified in the research doc and
restated in `docs/architecture.md` ("The fixtures contract"):

1. **Static from the document.** `<data id>` declarations on the compiled
   Machine; their initial values are evaluable directly.
2. **Static from the platform.** System variables with spec-fixed shapes
   (`_sessionid`, `_name`, `_ioprocessors`, and `_event` with its SCXML
   5.10.1 fields - `Statifier.Evaluator.SystemVariables` is literally the
   schema), plus predicator function providers, enumerable today via the
   `Provider` behaviour's `functions/0` callback (`name -> {arity, impl}`),
   covering built-ins and host-registered providers alike.
3. **Host-only.** Initial data the host supplies, the shape of `_event.data`
   per event, and host function return values. Unknowable statically; only
   the host that will eventually run the chart knows them.

Tiers 1 and 2 need no new contract. Tier 3 is the gap, and four planned
features all starve without it: the datamodel explorer's authoring mode has
nothing to show, editor completions and hover have nothing to complete,
the scratchpad evaluator has nothing to bind identifiers against, and a
simulator's event palette can only fire events with empty payloads.

The engine does not need this data - statifier compiles and runs charts
without it - so the contract cannot come from statifier, and per ADR-0002 the
engine is not asked to change for it from here. It also has to work in two
settings: a host application that owns real Elixir modules, and a corpus or
CLI setting where a chart is just an `.scxml` file on disk with no host code
around it. The research doc left the sidecar's naming and shape as an open
question for this bead to settle.

## Decision

Hosts provide example data through a **first-class fixtures contract**: one
artifact per chart, consumed as one struct, powering all four features above.

**Shape.** A fixture bundle is two maps:

- **Scenarios**: named example datamodels - each a name (for example
  `"gold-tier-user"`) mapped to a complete example of the host-supplied
  datamodel for that situation.
- **Events**: example events keyed by event name, each carrying a sample
  `_event.data` payload (for example `"payment.success"` mapped to
  `{"amount": 1999, "currency": "USD"}`). One sample payload per event name;
  multiple samples per event is a possible later extension, not part of this
  contract.

**Types are inferred shapes from example values**, not a declared schema
language. An example is concrete and immediately evaluable - the explorer
renders it, the scratchpad evaluates against it, completions walk its keys,
the palette fires it. A schema layer (declared optionality, unions,
constraints) is explicitly optional-later, layered on top of examples if the
need materializes, never a prerequisite for using fixtures at all.

**Delivery, both ways, one consumed struct:**

- **A behaviour module for host apps**: a module implementing a
  `StatifierUI.Fixtures.Source` behaviour whose callback returns the fixtures
  struct (`%StatifierUI.Fixtures{scenarios: %{...}, events: %{...}}`). Host
  code can build examples from its own factories or fixtures rather than
  duplicating them.
- **A JSON sidecar next to the chart** for corpus and CLI use: a chart at
  `payment.scxml` may carry `payment.fixtures.json` beside it. The sidecar is
  a JSON object with a `"version"` field (initially `1`) and `"scenarios"`
  and `"events"` keys matching the shape above. The loader parses it into
  the **same struct** the behaviour returns; every consumer downstream of the
  loader is indifferent to which path the data arrived by.

Naming these modules is intent, not description: no fixture code exists in
`lib/` yet (the repository is a scaffold), and the first consumer is the
Livebook inspector (sui-t36). Exact function signatures are settled at
implementation time; the contract - two maps, two delivery paths, one
struct - is settled here.

**The tier model is part of the contract.** Consumers render all three tiers
through one value tree: tier 1 from the compiled Machine's `<data>` ids,
tier 2 from the spec-fixed system variable shapes and the Provider
behaviour's `functions/0` enumeration, tier 3 from fixtures. This is what
lets the datamodel explorer be one component with two modes - only the
tier-3 source switches between fixture data (authoring) and the live
session's datamodel (debug).

**Fixture-aware linting** falls out of the same artifact: walk the compiled
instruction streams for identifier references that no tier provides -
"`user.tier` referenced in the guard at line 23, but no scenario or event
fixture defines it" - and flag them at author time. This catches the most
common statechart bug, a typo'd path silently evaluating to undefined. The
lint is a **warning**, not an error: absence of a fixture entry is weaker
evidence than presence of a contradiction, and a chart with no fixtures at
all must still lint clean on tiers 1 and 2.

**What this decision does not do:**

- It does not add anything to the engine. Where fixture-adjacent needs turn
  out to require engine change - a fixture hook in statifier, richer
  provider metadata (parameter names, return shapes, docs) beyond
  `functions/0` - that is upstream work, filed as an `st-` bead in
  statifier-ex or a `px-` bead in predicator-ex under the mirror discipline
  in `CLAUDE.md`, never implemented from this repository (ADR-0002).
- It does not make fixtures part of the trace wire format. Whether the
  sidecar's JSON shape graduates into the language-neutral spec (sui-w1b) so
  that non-Elixir interpreters share fixture files is that decision's
  question, not this one's; this record only requires that the sidecar be
  plain JSON so nothing here forecloses it.
- It does not decide a schema language. If schemas arrive later they extend
  this contract; they do not replace examples as the base layer.

## Consequences

- Four features draw from one artifact, so authoring effort amortizes: a
  host that writes fixtures once gets the explorer tree, context-sensitive
  completions (`_event.data.` inside `<transition event="payment.success">`
  completes from that event's fixture), a safe keystroke-by-keystroke
  scratchpad (predicator evaluation is pure and sandboxed, per ADR-0002's
  adopted premises), and a populated event palette.
- Charts travel between repos with their example data: an `.scxml` plus its
  `.fixtures.json` is self-contained, which matters because fixtures move
  with charts between statifier-ex and here, and because a corpus needs no
  host code.
- **What inferred shapes cost**, accepted honestly: a single example cannot
  express optionality (a field absent from the sample but sometimes present
  at runtime is invisible), unions (a field that is sometimes a string,
  sometimes a map, shows only one arm), constraints (nothing says an amount
  is non-negative), or intent (a `null` example is ambiguous between "always
  null" and "unknown"). Completions and lint are therefore only as good as
  the examples, and examples can drift from the host's real payloads with no
  mechanism here to detect it. This is the price of zero schema authoring
  cost and of examples being directly evaluable; the schema layer stays
  available later for hosts that outgrow it.
- The one-sample-per-event simplification sharpens that cost for events
  specifically: an event whose payload genuinely varies by circumstance is
  represented by one arm of it. Accepted for now; multiple samples are the
  natural first extension if it bites.
- The lint's warning severity means a typo'd path can still ship if warnings
  are ignored; the alternative (error severity) would punish every chart
  that legitimately has no fixtures. Accepted.
- Two delivery paths mean two loaders to keep convergent on one struct; the
  struct being the single consumer-facing type is what keeps that cheap.

**Alternatives considered:**

- **A declared schema language first** (JSON Schema or similar): highest
  fidelity for completions and lint, but imposes authoring cost before any
  feature works, is not directly evaluable (a scratchpad and a palette need
  values, so examples would be needed anyway), and imports a specification
  dependency this early contract does not need. Rejected as the base layer;
  kept as the optional later addition.
- **Behaviour only**: leaves the corpus and CLI settings, and any future
  non-Elixir interpreter, with no path. Rejected.
- **Sidecar only**: forces host apps to serialize example data out of the
  code that already owns it, duplicating factories into JSON by hand.
  Rejected.
- **Engine-side fixture support** (statifier learns to carry example data):
  the engine does not need fixtures to run charts, and ADR-0002 bars asking
  it to change for a UI need from here. If a genuine engine seam is ever
  wanted, it is an `st-` bead. Rejected here regardless.
- **Per-feature ad hoc data** (the palette takes its own event list, the
  explorer its own tree): four small contracts instead of one, drifting
  independently, with linting impossible because no single artifact states
  what the host provides. Rejected.

**Open questions carried, not resolved here:**

- Whether the sidecar shape joins the language-neutral wire-format spec
  (sui-w1b decides; this record keeps the sidecar plain JSON so it can).
- How a scenario is selected by a consumer when several exist (a default
  scenario key, first-listed, or explicit selection only) - a UI-affordance
  call for the first consumer (sui-t36) to make, not a contract change.
