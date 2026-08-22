# Statifier-ui extension: /wurk:mr

Two project facts. Adds only - see `~/.claude/skills/wurk:mr/SKILL.md` for
everything this does not repeat.

## The request is a record and a CI run, not a human review gate

One contributor, no second reviewer. CI (`.github/workflows/ci.yml`) runs the
full gate on every pull request, so a check does run when the request opens -
but nobody else is going to read the diff, so:

- **Do not wait for human review.** There is none to wait for. The CI check is
  worth confirming green, but a request that sits open pending a reviewer who
  will never arrive is just a branch that has not landed.
- **The gate still runs before the push.** Step 4's full `mix quality` is what
  verifies this branch before it becomes public; CI replays the same command
  (read from `.claude/wurk.json`'s `gate.full`) only after. Treat a skipped
  or scoped local gate here as a hard stop, not something CI will catch up on
  later.

What the request is for is the record: a diff with a written rationale, linked
to its bead, that can be read later. That is worth opening one for even with an
audience of one.

## Branch protection is not set up yet

`main` currently accepts direct pushes, and some of this repo's early history
landed that way at the user's explicit request. That is a transitional state,
not the workflow. Do not read it as license to skip the branch: work a bead on
its own branch and open a request for it unless the user asks otherwise in
their own words for that specific change.
