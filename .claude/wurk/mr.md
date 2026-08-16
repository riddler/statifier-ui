# Statifier-ui extension: /wurk:mr

Two project facts. Adds only - see `~/.claude/skills/wurk:mr/SKILL.md` for
everything this does not repeat.

## The request is a record, not a review gate

One contributor, no CI. Nothing runs when the request opens and nobody else is
going to look at it, so:

- **Do not wait for checks or review.** There are none to wait for. A request
  that sits open pending a signal that will never arrive is just a branch that
  has not landed.
- **The gate ran before the push or it did not run at all.** Step 4's full
  `mix quality` is the only thing that ever verified this branch. Treat a
  skipped or scoped gate here as a hard stop, not a formality to catch up on
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
