# ADR-0001: Record architecture decisions

Status: accepted (2026-08-16)

## Context

This repository exists because of a research conversation held elsewhere (see
`docs/research/260816-sui-kua-gui-research-and-direction.md`). Its direction -
text-first authoring, a language-neutral trace wire format, one hex package with
optional integrations - was settled in that conversation and will be refined
continuously during implementation, by one person and several AI models.
Decisions made in conversation evaporate; decisions made in code are invisible
until someone trips over them.

Two things make this sharper here than in a standalone project. The work is
driven by AI sessions whose context windows are short relative to the project,
so "we already decided this" has to live in a file to survive at all. And the
project sits downstream of `statifier` and `predicator`, whose own ADRs this
repo depends on but does not own, so citations cross repository boundaries
routinely.

## Decision

We record architecturally significant decisions as numbered ADRs in `docs/adr/`,
one file per decision, in this format: Context, Decision, Consequences. This
matches statifier ADR-0001, deliberately - the same reader moves between these
repos and should not have to learn a second convention.

- Files are named `NNNN-kebab-case-title.md`, numbered sequentially from 0001.
- Status is one of `proposed`, `accepted`, `superseded by NNNN`, with the date
  the status was reached.
- An ADR is amended by a new ADR that supersedes or amends it in part, never by
  rewriting history. The superseded ADR's status line records what replaced it.
- `docs/adr/README.md` carries the index: number, title, status. It is updated
  in the same commit as the ADR it lists.
- **ADR numbers are repo-local.** A citation of an ADR belonging to another
  repository is always qualified: "statifier ADR-0012", "predicator ADR-0010".
  A bare "ADR-0012" means this repo's.

## Consequences

- The "why" survives model context windows, branch boundaries, and time.
- Plans, beads, and pull requests can cite ADR numbers instead of re-arguing
  settled questions.
- Superseded decisions remain visible as the path taken, not erased.
- The index is a second place to update, and an ADR merged without it is a
  latent gap. This is accepted as cheap relative to an unlisted decision.
- Every other ADR in this repo depends on this format being settled, which is
  why this one comes first.
