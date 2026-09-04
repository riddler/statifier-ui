# Statifier-ui extension: /wurk:commit

Additional required steps. Adds only - see
`~/.claude/skills/wurk:commit/SKILL.md` for everything this does not repeat.

## Changelog: fragments

`changelog.mode` is `fragments` with `changelog.dir` at `changelog.d`
(sui-6vy, adopted fleet-wide 2026-08-21 so the convention exists before
parallel work starts, not after the first conflict). A user-facing change
gets one file per bead under `changelog.d/`; the rules - when a fragment is
and is not warranted, format, naming - live in `changelog.d/README.md`.

The package is published on Hex and has released versions behind it - the
version in `mix.exs` and the sections in `CHANGELOG.md` are the record; do
not restate either number here or anywhere else that can rot. The
consequence for this file is that the fragment test now bites both ways.
It is no longer safe to assume the answer is usually no: a public API
addition or change, a behavior change, or a change to a published contract
(the fixtures layout, the trace wire format) is something a released
consumer can see, and it gets a fragment. Apply the README test honestly -
could someone who only ever calls the public API tell the difference? -
rather than defaulting to "skip it".

The one-pass-from-git-history route (sui-n0r) was a first-release-only
device: it worked because there was no prior release to diff against. That
no longer holds. Every version section after the first is assembled from
the fragments that landed since the previous one.

`CHANGELOG.md` exists and is maintained. It is still **never edited outside
a release**: at release the fragments in `changelog.d/` are assembled into a
new version section and deleted in the same commit, per the "At release"
section of `changelog.d/README.md`. An ordinary commit adds a fragment; it
does not touch `CHANGELOG.md`.

## Version bump: none

`mix.exs`'s `@version` attribute is the single source of truth for the
package version - read it there, and never repeat it into prose that will
outlive it. Never edit the version field as part of an ordinary commit; a
release bead moves it.

The manifest does carry a `release` recipe - `kind: "hex"`, `version_file`
`mix.exs`, `readme_pin` true - so `/wurk:release` runs here, driven by that
block together with the required steps in `.claude/wurk/release.md`. None of
that is a commit-time concern: the recipe runs on an operator-authorized
release bead, and it still stops short of tagging, pushing and publishing,
which `CLAUDE.md`'s authority table holds for the operator in every campaign.
What it means for an ordinary commit is only this: if a version change turns
up in the diff and you are not on a release bead, that is the finding -
report it and stop, do not commit it.

`.claude/wurk.json`'s `release` block and `.claude/wurk/release.md` are
authoritative on release mechanics; this file defers to them and never
restates them. Where this paragraph and those two disagree, they are the
evidence and this paragraph is the defect.

## Gate thresholds are a human's call

The manifest lists `.quality.exs`, `coveralls.json`, and `.doctor.exs` in
`gate.moving_files`, and `.claude/settings.json` denies all three to the
file-editing tools. That is a deliberate half-measure: statifier-ex enforces
this with a `mix gate.check` stage and a ledger file, and this repo has
neither, so a deny rule is what is available. It does not cover `Bash` - a
`sed -i` or a `>` redirect goes straight through. The point is not to make the
edit impossible but to make it unmistakably deliberate in a diff.

The three deny entries and `gate.moving_files` are the same list written
twice. Changing one means changing the other.

The rule the deny rules approximate:

**A diff that moves a number in one of those files needs the user to have asked
for it.** Not "the gate went red and the threshold looked too strict" - that is
the signal working. Report the finding and stop. Each of those files carries
the reason for its numbers at the number; a change that moves a threshold
without moving its reason is incomplete regardless of who asked.

## Commit message limits: reviewed, not just inherited

`.claude/wurk.json`'s `commits` block started as a straight copy of
statifier-ex's values (6d99b05). sui-a61 reviewed them against this repo's
own history rather than accepting the copy silently.

- **`total_lines_max: 40` - kept.** At the time of the review the longest
  message on `main` was well clear of the limit, and it still is - though the
  headroom has narrowed since, as messages here have grown longer. Check it
  rather than trusting a number written down once:

  ```bash
  git log origin/main --format=%H \
    | while read h; do echo "$(git log -1 --format=%B "$h" | wc -l) $h"; done \
    | sort -rn | head -3
  ```

  The limit is not binding today, but nothing in this repo's commit style
  argues for a different number either, so there is no reason to move it.
- **`trailer.key: "Refs"` - kept.** History has exactly one trailer at all,
  `Beads: sui-kua`, and it was written by `bd` itself (a bd-driven commit),
  not by `/wurk:commit` - it is not a precedent for what this workflow's
  trailer key should be. Weighed against that single tool-authored line is
  consistency with statifier-ex, the sibling repo this project deliberately
  mirrors and where fixtures and conventions move back and forth in both
  directions. Consistency with the sibling wins over one non-`/wurk:commit`
  data point.
- **`subject_under: 50` and `body_line_max: 72` - unchanged**, and out of
  scope for this review: they already match the CLAUDE.md prose and nothing
  in the bead asked them to be re-litigated. Worth knowing in practice:
  `main` carries a commit with a body line of 73 characters, one over the
  limit. That is not a reason to move the limit - it says the 72-character
  wrap is already binding, which is the check doing its job the first time it
  will actually run.

## The attribution ban will reject some legitimate messages here

`commit_message.rb`'s attribution check is hardcoded (not manifest-driven) to
reject any message containing `Co-Authored-By`, `Generated with`, or the
exact string `Claude`. That rule lives in `~/.claude/skills/wurk:kit/`,
outside this repo, so it cannot be configured away from here - and it should
not be: the ban exists to keep AI attribution out of commit messages, which
is a real rule this project wants.

The check is a case-sensitive `String#include?`, which matters here: this
repo's own project instructions file is named `CLAUDE.md` (all caps) and its
manifest lives under `.claude/` (all lowercase) - neither trips the ban,
because neither is the exact capitalization `Claude`. Typing those paths in a
commit body is safe.

The one real collision on `main` is 2a01433 ("Removes the bd-generated
.agents and .codex scaffolding"), whose body says "This project drives beads
from Claude Code only" - the exact capitalization, so it trips the ban.
Verified directly: `git log -1 --format='%B' 2a01433 | ruby
~/.claude/skills/wurk:kit/scripts/commit_message.rb check` fails on
`no_attribution` (`found forbidden attribution text: "Claude"`) and, as an
unrelated finding from the same replay, also fails `subject_length` (its
subject is 55 characters against the 49-character limit) - useful evidence
that both limits bind in practice, not just in theory.

**Write around it only when a sentence would name the coding agent itself**
(write `the project's coding agent`, not `Claude`) - not for file paths,
which are already safe as written (`CLAUDE.md`, `.claude/wurk.json`). This is
not a workaround for the rule - it is describing the same thing without
tripping a substring match the rule was never meant to catch.

## No commit-msg git hook

Decision: **do not add a `commit-msg` hook.** Enforcement stays inside
`/wurk:commit` (Step 2 pre-commit, Step 4.4 post-commit verification).

Reasons: this repo has one contributor, and CI (`.github/workflows/ci.yml`)
replays the quality gate but checks nothing about commit messages, so
`/wurk:commit` is already the only message check a commit gets in practice -
a plain `git commit` bypassing it would be a self-inflicted problem, not an
outside contributor's. A hook is also another uninstalled-by-
default file: git hooks are not checked in or wired up automatically, so
shipping one here would need its own installer step this repo does not have,
for a case (bypassing the one workflow the one contributor uses) that has not
come up. This repo removed `.beads/hooks` for the same reason - nothing read
them. Revisit if a second contributor, or a habit of using plain `git commit`,
actually shows up.

## CI replays the gate; the local run is still the trigger

The authority table in `CLAUDE.md` makes a full green `mix quality` the trigger
for `git commit`. CI (`.github/workflows/ci.yml`) runs the same full gate on
pushes to `main` and on pull requests, reading the command out of
`.claude/wurk.json`'s `gate.full` so the two stay one definition - but it
runs after a push, not before a commit, and there is still no second
reviewer. The local full green remains the trigger:

- A `--profile loop` green is not the trigger. It skips dialyzer, doctor,
  dependencies, and coverage.
- `mix quality` reports two permanent `○` skips, Gettext and Sobelow. Both are
  declared in `gate.not_applicable_skips` and explained in `CLAUDE.md`. A
  third skip line is not covered by that explanation - read it rather than
  assuming it belongs.

## The gate attests its own run

The manifest declares `gate.attest` as `mix quality.verify`, the attestation
task ex_quality ships (the dependency is pinned in `mix.exs`; the resolved
version is in `mix.lock`). `gate.rb` runs it after a full `gate.full` pass
and reports `data.attested`, so an unattended commit can prove the green it
is committing on came from a run that was not narrowed - no `--skip`, no
`--quick`, no scoped profile. Without the key the gate could only report
that a command exited zero.

It attests the shape of the run, not the content of the checks. A full green
that is attested is still not evidence that a weakened threshold was not the
thing that made it green; that is what the "Gate thresholds are a human's
call" section above is for.
