# Statifier-ui extension: /wurk:commit

Additional required steps. Adds only - see
`~/.claude/skills/wurk:commit/SKILL.md` for everything this does not repeat.

## Changelog: none

`changelog.mode` is `none` in the manifest, so there is no fragment step and
nothing to ask about. Nothing here is released yet; the day it is, that
decision changes in `.claude/wurk.json` rather than in a habit.

## Version bump: none

`mix.exs` holds `0.1.0-dev` until a release bead says otherwise. Never edit the
version field as part of an ordinary commit.

## Gate thresholds are a human's call

The manifest lists `.quality.exs`, `coveralls.json`, and `.doctor.exs` in
`gate.moving_files`. There is no `mix gate.check` stage here and no ledger file
to write, so the enforcement is this instruction rather than a script:

**A diff that moves a number in one of those files needs the user to have asked
for it.** Not "the gate went red and the threshold looked too strict" - that is
the signal working. Report the finding and stop. Each of those files carries
the reason for its numbers at the number; a change that moves a threshold
without moving its reason is incomplete regardless of who asked.

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
