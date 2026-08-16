# ADR-0010: Cross-repo tracker authority and mirrors

Status: accepted (2026-08-16)

## Context

Three trackers now touch this work: `sui-` here, `st-` in statifier-ex, and
`px-` in predicator-ex. How the first two relate to each other is settled:
predicator ADR-0010 ("Tracker authority follows the artifact, and mirrors
pull") derives the rules - who owns a decision recorded in two trackers, what
a `mirrors:` note obliges and in which direction, and how work in a
trackerless repo is held - and statifier ADR-0025 adopts them from the
statifier side, which is what moved predicator's record from proposed to
accepted. Those two records verify the discipline pairwise: each side checked
that the pull obligation is performable from where it stands rather than
assuming it.

This repository is the third tracker and has been living the discipline
without recording it. `CLAUDE.md`'s "Beads that span repositories" section
already states the rule in enforcement form - "the repository whose files
change owns the bead" - and ADR-0002's adopted-by-reference rule already
depends on it: an engine gap discovered here "is filed as an `st-` bead in
statifier-ex ... under the mirror discipline in this repo's `CLAUDE.md`",
which cites a discipline this repo had not yet given a record of its own.
ADR-0003 and ADR-0007 lean on the same sentence. The reasoning behind the
enforcement section has to live somewhere on this side; statifier ADR-0025
weighed exactly this question (a CLAUDE.md section alone versus a section
backed by a local ADR) and its grounds transfer whole: a reader here should
not need a checkout of another repo to learn why this one is built the way it
is, the local record carries content the siblings could not write (the
sui-side artifact list, and the verification that the pull is performable
from here), and CLAUDE.md separates enforcement from reasoning by citing a
record rather than re-arguing one.

One thing is genuinely different about the third adoption. Predicator and
statifier are peers with traffic in both directions - statifier consumes the
language, predicator takes requirements back. This repo is almost purely a
consumer of both, and it consumes them asymmetrically: statifier for engine
semantics and trace emission, predicator for the expression language.
"Authority follows the artifact" therefore cuts one way almost every time
from here, and the sharpest failure mode is the one ADR-0002 names: a UI
bead hits an engine gap and a session, seeing only this repository, patches
it here. What this record adds to ADR-0002 is the tracker side of that rule -
where the bead for such work lives, what the paired beads owe each other, and
who wins when ownership looks ambiguous.

## Decision

**This repo adopts the three rules of predicator ADR-0010 as statifier
ADR-0025 adopted them: rules 1 and 2 verbatim, rule 3 with a local reading of
its scope. The adoption extends the mesh from two trackers to three; the
obligations are pairwise between any two of them, and neither sibling record
is changed by this one.**

### 1. Authority follows the artifact the decision changes

A decision is owned by the repository whose files change if it goes the other
way, and the bead in that repository is authoritative; where two trackers
disagree, the owning side is correct by construction. Read from this side:

- **This repo owns** the UI and UX (rendering, components, interaction,
  layout - ADR-0007's text-first contract and everything downstream of it),
  the fixtures contract (ADR-0003: the bundle shape, the sidecar format, the
  behaviour, the lint), the packaging (ADR-0004: one package, optional
  integrations, what the hex package ships), the trace wire-format
  specification (`docs/wire-format.md` per ADR-0005 - statifier-ex's own
  observability page lists the wire format as a non-goal, so the
  serialization seam is this repo's artifact even though statifier implements
  the first producer), and how this repo consumes anything upstream: which
  seams it attaches to, what its components do with an engine value or error
  shape, when its dependency pins move.
- **This repo defers** engine semantics, trace effect emission, retained
  locations and identities, fixture hooks in the engine, and everything else
  behind the statifier seams to `st-`; and the expression language, grammar,
  ISA, compiled envelope, and provider metadata to `px-`. ADR-0002 already
  adopts the substance of those decisions by reference; this rule places the
  beads for changing them.

The tie-breaker when ownership looks ambiguous is the same question
predicator ADR-0010 ends on: **which repository's files change if the
decision goes the other way?** There is deliberately no ownership table
beyond the lists above - it would go stale, and the question does not. The
wire format is the instructive local case: the spec document is this repo's
file, so the spec's content is this repo's call, while a producer's failure
to emit what the spec requires changes statifier's files and is an `st-`
bead.

A requirement discovered here but owned there is raised as a bead here,
decided there, and mirrored - never implemented from here, however small the
patch looks. This is ADR-0002's rule given its tracker half: a trace effect
that does not exist, a counter that is not granular enough, a fixture hook,
richer provider metadata - the bead here carries the UI need and waits; the
`st-` or `px-` bead carries the decision and the work. sui-czr (the span
resolver ADR-0007 rides on) and sui-qay (attribute locations on the Machine
layer) are the live models of the shape.

### 2. Mirrors pull; nobody pushes

Adopted verbatim, and now pairwise across three trackers rather than
symmetric between two:

- Both halves of a pair carry `mirrors: <id>` as the first line of the
  description. It lives in the description - not `external_ref` - because it
  must be multi-valued and findable by search, per predicator ADR-0010's
  verification of what `bd` indexes.
- A reconciliation note is a dated snapshot. Age alone is never a defect,
  and the authority side owes the mirror nothing on any schedule. The note
  becomes a defect the moment someone schedules, claims, plans against, adds
  or drops a dependency on, or cites the status of a mirrored bead without
  re-reading the other tracker first: refresh, write a new dated note above
  the old one, then act.
- **A `mirrors:` id that does not resolve is broken immediately**, not
  stale - it makes the pull unperformable. Whoever notices fixes it with one
  `bd update`, in whichever repo they are standing in.
- **Closed beads are out of scope.** They will never be pulled on, and
  rewriting them edits the record of what was believed at the time.

The pull obligation is performable from here, checked 2026-08-16: sessions
in this repo have the statifier-ex and predicator-ex checkouts and their
`bd` trackers readable as siblings of this repo's worktree root. Because
this repo is the consuming side of nearly every pair it will ever be half
of, refresh-before-acting is a cost paid here more often than in either
sibling; as statifier ADR-0025 puts it, that is the correct side to charge,
since it is the side about to benefit from the answer. Nothing on this side
wants a push obligation it would almost always be on the receiving end of,
for the enforceability reasons predicator ADR-0010 records: two offline
embedded databases synchronized on independent schedules cannot detect an
unperformed push, and a silently violated rule makes the notes look more
trustworthy than they are.

**When a change spans two repos**, it is two beads, one per repo, split
along the artifact line and paired with `mirrors:` lines on both halves.
The owning side's bead is authoritative for the shared decision; the
consuming side's bead is authoritative for how this repo consumes the
result, and it waits - blocked on, not duplicating, the other half. The
st-t3f/px-h66 pair both sibling records cite is the model: the upstream
semantics were the upstream repo's call, what the consumer did with the
result was the consumer's. A pair created without `mirrors:` lines on both
halves is a pair with no pull path, and rule 2 has nothing to operate on.

### 3. Trackerless-repo work - adopted, and narrowest here

Work in a repo with no tracker (today, the `riddler/predicator` monorepo) is
held by an `upstream` bead in the repo that is waiting on it, with the
GitHub issue in `bd`'s single-valued, unsearchable `external_ref` field once
a human has opened it; an empty field means the issue has not been raised,
never a gap to fill. Opening the issue is publish-tier work under this
repo's authority table in `CLAUDE.md` - visible to other people, so it takes
a human ask.

The sui-side reading: this repo's upstream needs target statifier-ex and
predicator-ex, both of which have trackers, so its pairs are rule 2 pairs
and rule 3 is expected to apply here rarely if ever - plausibly only if this
repo someday waits directly on a sibling-language interpreter of the wire
format living in a trackerless repo. If that day comes, the mechanism is
adopted unchanged.

**What this decision does not do:**

- It does not change either sibling record. Predicator ADR-0010 and
  statifier ADR-0025 settled the `px-`/`st-` pair between themselves and
  are whole; this record joins the mesh without amending them. If any repo
  later changes rule 2's obligation, all three records move together.
- It does not re-derive the arguments. Why a push obligation is
  unenforceable, what `external_ref` does and does not index, why closed
  beads are history - predicator ADR-0010 carries the derivations and this
  record cites them, the same by-construction answer to drift that
  statifier ADR-0025 gives.
- It does not adopt the siblings' process decisions wholesale. This is one
  discipline adopted on its own grounds, consistent with ADR-0002's stance
  that upstream process ADRs are context, not binding premises.
- It does not decide what the engine or the language should do about any
  gap this repo files. That is the whole point: the `st-` or `px-` bead is
  where that decision happens, with this repo's need stated as input.

## Consequences

- **`CLAUDE.md`'s "Beads that span repositories" section now has the record
  it points at.** Enforcement stays in the table, reasoning lives here; the
  section's rule ("the repository whose files change owns the bead") is
  rule 1's tie-breaker stated in one sentence, and the two must move
  together if either ever changes.
- ADR-0002's "filed as an `st-` bead ... under the mirror discipline" and
  the matching sentences in ADR-0003 and ADR-0007 now resolve to a local
  record rather than to an unrecorded practice. Plans and reviews cite
  ADR-0010 when a bead implements upstream work from here or acts on a
  mirrored bead without refreshing it.
- The three-tracker mesh is pairwise, so nothing new is owed between `st-`
  and `px-` - their records already cover that edge - and a `sui-` bead can
  mirror either sibling (or, for a need that spans both, one bead per
  sibling) under one discipline.
- **Refresh-before-acting lands hardest here.** Nearly every mirrored pair
  this repo is half of has the authority on the other side, so nearly every
  scheduling decision against one begins with a read of another repo's
  tracker. Accepted as the price of no push obligation, paid by the side
  that benefits.
- **Nothing detects a rule 2 violation**, exactly as in both sibling
  records: an agent that acts on an unrefreshed note builds a plan on stale
  status and no gate catches it. The mitigation is inherited - the failure
  is loud when it lands rather than silent, which the push version would
  have been.
- The wire-format split (spec owned here, first producer built in
  statifier-ex) guarantees this repo's most consequential pairs will
  straddle rule 1's line in both directions at once. The rule handles it -
  spec content decided here, emission changes decided there - but it is the
  place a session is most likely to need the tie-breaker question rather
  than the artifact lists.
- Reversing any of this - a push obligation, a mirror registry, a shared
  tracker across the three repos - means superseding this record and both
  sibling records together, not adding a mechanism beside them.

**Open questions carried, not resolved here:**

- Whether the sibling records should each gain a line acknowledging the
  third tracker. Nothing in them is made false by this adoption - their
  obligations were stated pairwise - so no amendment is owed; but if either
  is amended for its own reasons, naming the `sui-` tracker in its mesh
  would be a natural rider. That is those repos' call, raised from here as
  an `st-`/`px-` bead only if it ever matters in practice.
