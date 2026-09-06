# ADR-0004: One package with optional integrations

Status: accepted (2026-08-16)

## Context

This project ships UI for two host environments that rarely coexist: a
Livebook notebook, where the integration surface is `Kino`, and a Phoenix
application, where it is `Phoenix.LiveView`. The obvious packaging axes are
one package per integration (`statifier_ui_kino`, `statifier_ui_live_view`),
one umbrella-style core plus adapter packages, or a single package.

Most of what this project builds is integration-neutral: trace effect
handling, fixture parsing (ADR-0003), the three-tier datamodel value tree,
and eventually the wire-format consumer are the same code whichever host
renders them. Splitting by integration would put that shared core in a third
package immediately, tripling the release surface for a scaffold-stage,
sole-contributor project before any component exists. Elixir already has a
first-class mechanism for the actual problem - a host paying only for the
integration it uses - in optional dependencies.

The research doc (`docs/research/260816-sui-kua-gui-research-and-direction.md`,
"Decisions extracted") settled the direction: one hex package, core depending
only on statifier, both integrations optional, MIT. Two adjacent facts
belong in the same record because they are set at package-creation time and
are expensive to revisit: the license, and the repository's name.

## Decision

**One hex package, `statifier_ui`.** No per-integration packages, no core
package, no umbrella.

- **Core depends only on `statifier`.** Until statifier publishes to hex,
  that dependency is a git dependency on `riddler/statifier-ex` with the SHA
  pinned in `mix.lock`; it becomes an ordinary version requirement the day
  statifier publishes. Nothing else in this decision depends on which form
  it takes.
- **`kino` and `phoenix_live_view` are both `optional: true`,** and optional
  is enforced at compile time, not only at dependency resolution: any module
  under `lib/` that touches `Kino` or `Phoenix.LiveView` guards the
  reference behind `Code.ensure_loaded?/1` (or an equivalent compile-time
  check) so it tolerates the dependency's absence. A Livebook host pays
  nothing for LiveView, and a Phoenix host pays nothing for Kino. Shared
  logic used by both integrations lives in modules that reference neither.
- **The dependency arrow points one way.** Statifier never depends on this
  package, optionally or otherwise. A UI is one more interpreter of the
  engine's effects (ADR-0002, via statifier ADR-0003); the engine does not
  know its interpreters exist.
- **Split later only under a real forcing function:** an integration whose
  footprint optional dependencies cannot hide - build-time requirements
  imposed on hosts that did not opt in, a dependency that cannot be marked
  optional, or similar. Growth in module count alone is not that; a split
  is a superseding ADR, not a drift.
- **License: MIT**, matching statifier-ex and predicator-ex, so code and
  fixtures move between the repos without license friction. The `LICENSE`
  file at the repo root is the instance of this decision.
- **Repository: `riddler/statifier-ui`, unported - no `-ex` suffix.** Unlike
  statifier-ex and predicator-ex, this repo is not the Elixir port of a
  language-neutral thing; it is the deliberately singular UI. The trace
  wire format is meant to be language-neutral (see "The wire format
  boundary" in `docs/architecture.md`; its specification is sui-w1b's
  decision, not this one's), so one UI can eventually serve interpreters
  written in other stacks - the way a debug adapter protocol serves many
  language backends. An `-ex` suffix would misname that intent. The hex
  package name `statifier_ui` is the same name in hex's underscore
  convention, not a second decision.

**What this decision does not do:**

- It does not decide the wire format or where its specification lives; it
  only records the naming consequence of the wire format being
  language-neutral. The format itself is sui-w1b.
- It does not decide how JavaScript ships. The source-recompile
  `file:../deps/` strategy is its own concern (sui-8tj, summarized in
  `docs/architecture.md`, "The JS strategy") and is compatible with either
  packaging shape.
- It does not commit to a hex publish date. Publishing waits at least until
  the statifier dependency can be a hex version requirement, since hex
  rejects packages with git dependencies.

## Consequences

- One `mix.exs`, one version, one changelog, one release. For a sole
  contributor this is the difference between releasing and coordinating
  releases.
- Every module under `lib/` inherits a rule, already stated in `CLAUDE.md`'s
  conventions: integration code guards its optional dependency, and shared
  logic stays integration-free. The gate cannot fully verify "compiles
  without kino" and "compiles without phoenix_live_view" from one dependency
  set, so guard discipline is carried by convention and review until a
  dedicated check exists.
- `Code.ensure_loaded?/1` guards are a real cost: they blur compile-time
  errors into runtime ones when a guard is wrong, and modules mixing guarded
  and unguarded references fail subtly. Accepted as the standing price of
  optional dependencies; the mitigation is structural (keep integration
  modules thin and leaf-like) rather than clever.
- The one-way dependency arrow means anything the engine would need to know
  about UIs - a trace effect, a fixture hook - is an engine seam requested
  through an `st-` bead (ADR-0002), never a `statifier -> statifier_ui`
  dependency, however convenient.
- Consumers get one coherent name to depend on now; if a split ever happens,
  it is a breaking change for them. The forcing-function clause above is
  what keeps that from happening casually.
- MIT and the unported name are recorded here so neither gets re-litigated
  at publish time, when renaming a repo and relicensing are at their most
  disruptive.

**Alternatives considered:**

- **One package per integration** (`statifier_ui_kino`,
  `statifier_ui_live_view` over a `statifier_ui_core`): the ecosystem's
  shape for large integration matrices, but here it triples the release
  surface to solve a problem optional dependencies already solve, and the
  shared core is most of the code. Rejected now; this is the shape a
  forced future split would likely take.
- **Umbrella project in one repo**: packages the internals apart without
  helping consumers, who still see multiple hex packages or one merged one.
  Rejected.
- **Non-optional dependencies on both integrations**: simplest to build
  against, but forces LiveView into every Livebook host and Kino into every
  Phoenix host, contradicting "optional dependencies are genuinely
  optional" in this repo's conventions. Rejected.

## Note (2026-09-06): `statifier_datamodel` is the third required dependency

A dated note rather than an amendment, because no clause of the decision
moves. There is still one hex package, `kino` and `phoenix_live_view` are
still both optional and still guarded, the dependency arrow still points one
way, the license is still MIT and the repository is still unported. Nothing
above this line changes.

The note exists because the decision's first bullet reads **"Core depends only
on `statifier`"**, and `mix.exs` now carries three required dependencies:
`statifier`, `predicator`, and `{:statifier_datamodel, "~> 0.1"}`.

That bullet stopped being literally true on 2026-08-26, not with this note:
dce46f9 declared `predicator` directly, because `lib/` calls `Predicator.*`
itself and a dependency a module compiles against does not belong to a
transitive edge. What sui-p6v adds is the second such dependency, and the
first occasion anyone wrote the divergence down.

**Why this one is not the split the bullet guards against.** The bullet's
subject is the *integration* axis - the thing this record exists to keep out
of the core is a host environment's UI toolkit, which is why the two optional
dependencies are named in the very next bullet and why "split later only under
a real forcing function" is written in terms of an integration's footprint.
`statifier_datamodel` is on the other axis entirely: it is a pure library with
no dependencies of its own, no processes, and no integration surface. A
Livebook host and a Phoenix host pay for it identically, which is exactly the
asymmetry `optional: true` exists to prevent and the reason it would be the
wrong tag here.

**Why it is a dependency rather than a local reading.** The expression editor
takes a datamodel *document* and needs the path-to-kind projection
`StatifierDatamodel.Index.path_types/1` computes from it. sd owns that
document's shape and that projection (statifier_datamodel ADR-0001, decisions
7 and 11).
Reading the document a second time in this package would be a drifting copy of
someone else's contract - the same duplication `StatifierUI.Expression`
already refuses for the predicator grammar, for the same reason: a rule
restated is a rule that goes stale.

**The consequence for a host.** One more package resolves, and no host is
required to have a document: `:path_types` remains a plain map a host can
supply with no document anywhere in sight, and it wins when both are given.
The dependency is required so that the projection is always callable, not so
that it is always called.
