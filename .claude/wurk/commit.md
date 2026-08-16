# Statifier-ui extension: /wurk:commit

Additional required steps. Adds only - see
`~/.claude/skills/wurk:commit/SKILL.md` for everything this does not repeat.

## Changelog: none

`changelog.mode` is `none` in the manifest, so there is no fragment step and
nothing to ask about.

This is a decision, not an omission. While the package is `0.1.0-dev` with no
users and no public API, every entry would say some version of "the package
started existing" - and 0.1.0's changelog is better written in one pass from
git history than assembled from a pile of per-bead fragments, which is only
possible while there is no prior release to diff against.

sui-n0r switches this to `fragments` when the first release is on the horizon,
and says why fragments rather than a single `CHANGELOG.md`. Do not start
writing changelog entries before then; do not let `none` outlive the release.

## Version bump: none

`mix.exs` holds `0.1.0-dev` until a release bead says otherwise. Never edit the
version field as part of an ordinary commit.

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

- **`total_lines_max: 40` - kept.** The longest message on `main` is 24 lines
  (`Sets up the wurk manifest and extensions`); nothing is within striking
  distance of 40. The limit is not binding today, but nothing in this repo's
  commit style argues for a different number either, so there is no reason to
  move it.
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
  in the bead asked them to be re-litigated. Worth knowing in practice: two
  commits on `main` have a body line of 73 characters, one over the limit.
  That is not a reason to move the limit - it says the 72-character wrap is
  already binding, which is the check doing its job the first time it will
  actually run.

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

Reasons: this repo has one contributor and no CI (`CLAUDE.md`'s authority
table), so `/wurk:commit` is already the only path a commit takes in
practice - a plain `git commit` bypassing it would be a self-inflicted
problem, not an outside contributor's. A hook is also another uninstalled-by-
default file: git hooks are not checked in or wired up automatically, so
shipping one here would need its own installer step this repo does not have,
for a case (bypassing the one workflow the one contributor uses) that has not
come up. This repo removed `.beads/hooks` for the same reason - nothing read
them. Revisit if a second contributor, or a habit of using plain `git commit`,
actually shows up.

## No CI means the gate is the whole check

The authority table in `CLAUDE.md` makes a full green `mix quality` the trigger
for `git commit`, and there is no second net behind it - no CI run, no
reviewer. So:

- A `--profile loop` green is not the trigger. It skips dialyzer, doctor,
  dependencies, and coverage.
- `mix quality` reports two permanent `○` skips, Gettext and Sobelow. Both are
  declared in `gate.not_applicable_skips` and explained in `CLAUDE.md`. A
  third skip line is not covered by that explanation - read it rather than
  assuming it belongs.
