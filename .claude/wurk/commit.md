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
