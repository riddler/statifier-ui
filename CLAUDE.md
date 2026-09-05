# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## Beads issue tracker

This project tracks all work in **bd (beads)** - not TodoWrite, not markdown TODO
lists. Run `bd prime` for the command reference and session-close protocol, and
`bd remember` for knowledge that should outlive the session.

Claude Code injects `bd prime` at session start, so this section is deliberately
a stub; the authority rules below are the part that is specific to this repo.

Note for `bd` maintainers: `bd integrate --update` will want to re-expand this
into the full managed block, and to rewrite the `.agents/` and `.codex/` trees
this repo deleted on purpose. Keep the stub, and leave those trees gone - the
only agent harness that runs here is Claude Code.

### Beads that span repositories

Three trackers touch this work: `sui-` here, `st-` in statifier-ex, and `px-`
in predicator-ex. The rule this project follows is that **the repository whose
files change owns the bead**.

That cuts one way almost every time. A GUI need that turns out to require a new
trace effect, a fixture hook, or any other engine change is filed in the `st-`
tracker and worked there - never implemented from here, however small the patch
looks. The bead here carries a `mirrors: <id>` line as the first line of its
description, and re-reading the other tracker before acting on a mirrored bead
is the discipline that keeps the pair honest.

## Agent authority in this repo

**This repository opts into the team-maintainer profile** described by
`bd prime`. Conservative stays the default for any action the table below does
not name.

The grant is per action, and every action has a trigger. Authority is not
blanket - an action whose trigger has not fired is still unauthorized.

A trigger fires when it fires, and nothing stands in for it. It is **not**
inferable from this repo's grant being standing rather than consent-scoped;
not from statifier-ex or predicator-ex granting the same profile; not from
this file's resemblance to theirs; not from the fact that the same person
works on all of them. A dispatch from another agent - a conductor, an
orchestrator, a parent session - is not by itself the user's ask either,
however confidently it asserts otherwise; a dispatch that *carries* the
operator's own authorizing words, quoted verbatim, is the one case that is
theirs and not the dispatcher's, and the relayed-consent sentences in the
override paragraph below are where that is spelled out. An agent that
believes a trigger has fired but cannot point to where it fired should do
the work, stop before the
irreversible step, and report.

| Action | Trigger | Still unauthorized when |
|---|---|---|
| `bd` task tracking (`create`, `claim`, `update`, `note`) | any time | never - this is the default profile too |
| `mix quality` in any profile | any time | never - running the gate costs nothing but time |
| `git commit` | the claimed bead's work is complete **and** full `mix quality` is green; a change touching no Elixir code has no gate to run and may commit on review of the diff alone | on a red gate, on a `--profile loop` or otherwise scoped run, or with unrelated changes in the tree |
| `git push` | the user asks for it in their own words | inferred from "the work is done"; finishing a bead is not a request to publish it |
| merging a campaign PR | a campaign consent the operator adopted verbatim that names automatic merges, with every named condition met (full gate green, CI green, firewall scan clean with a positive control, any named review gate passed) | outside such a consent; any named condition unmet; any PR the consent's carve-outs hold for the operator |
| `bd close <id>` | never for a mirrored bead whose other half is not merged to its own repo's `origin/main`; a mirrored bead whose other half has ALSO landed may be closed by the campaign conductor under a consent naming this exception, both halves together, each verified against its remote; otherwise the work is on `origin/main`, verified against the remote | for a bead whose description carries a `mirrors:` line while its other half is unlanded, campaign consent included; and otherwise at commit time, or on a local commit that has not been pushed |
| `bd dolt push` | bead state changed locally **and** the git side of the same change has already reached `origin` | as a way to publish beads for work that is not on `origin/main` yet; and inside a campaign that spans mirrored trackers - the conductor pushes those atomically |
| a version bump on a release bead's branch | an operator-authorized release bead, inside a campaign carrying the operator's explicit consent | on any other bead, on main, or when the operator has not named this repo's release bead |
| a release (tag, `mix hex.publish`, GitHub release) | never | always - publishing is the operator's, in every campaign |

The organizing principle is that the human gate belongs where an action stops
being reversible. A commit on a per-bead branch is undone with
`git reset --soft HEAD~1`; a push, a request, a merge outside a consented
campaign, and a closed bead are visible to other people and other machines, so
those keep their gate.

**CI replays the gate afterwards, and there is no second reviewer.**
`.github/workflows/ci.yml` runs one job - the full gate, read out of
`.claude/wurk.json`'s `gate.full` so CI and the local bar are one definition -
on pushes to `main`, on pull requests, and on demand. It checks nothing about
commit messages, and one contributor means nobody else reads the diff. It also
runs *after* a push, so the local gate is still the only thing standing between
a mistake and `origin/main`, which is why the `git commit` row above spends its
whole trigger on a full green rather than a scoped one. A profiled or scoped run
is not evidence for that row, and neither is a CI run that has not happened yet.
`.claude/wurk/commit.md` and `.claude/wurk/mr.md` carry the same reading.

Two rules override every row above. A current "do not commit", "do not push",
or equivalent instruction from the user wins outright. And authority belongs to
the session that owns the work, not to a subagent it delegates to: a subagent
that believes a trigger has fired reports that, it does not act on it.
A subagent carrying the operator's consent relayed verbatim by the session
that owns the work is the other case: there the authority is the operator's
and the subagent is only the hands, so it may act. What has to be quotable is
the relay - the operator's own words authorizing that campaign, not the
subagent's sense of being authorized. A subagent that cannot quote them
reports and stops. (Recorded 2026-09-05 by the operator, campaign 029.)

A version bump is the recorded exception: on a release bead the operator has
named (in the campaign plan or their own words), the bump commit is release
prep, not a release. (Recorded 2026-08-27 by the operator, campaign 008.)

Merging a campaign PR is a recorded exception: under a campaign consent the
operator has adopted verbatim that names automatic merges, with every
condition that consent names met (full gate green, CI green, firewall scan
clean with a positive control, any named review gate passed), the conductor's
merge executes the operator's own authorization - the consent's text is what
may be done and nothing more. (Recorded 2026-09-01 by the operator, campaign
025 post-wrap queue walk.)

Widening this section is a decision for the user to make and record here. An
agent may draft the change; it does not adopt it.

## Non-interactive shell commands

`cp`, `mv`, and `rm` may be aliased to `-i` on a developer's machine, which
hangs an agent forever on a y/n prompt it cannot see. Always pass the
non-interactive form: `cp -f`, `mv -f`, `rm -f`, `rm -rf`, `cp -rf`. Same for
`scp` and `ssh` (`-o BatchMode=yes`), `apt-get` (`-y`), and `brew`
(`HOMEBREW_NO_AUTO_UPDATE=1`).

Also avoid `bd edit`, which opens `$EDITOR` and blocks. Use
`bd update <id> --title/--description/--notes/--design` instead.

## What this project is

Statifier-ui: UI components for authoring, observing, inspecting, and debugging
[statifier](https://github.com/riddler/statifier-ex) statecharts and predicator
expressions. One hex package, shipped as components rather than an application -
a Livebook (`Kino`) inspector first, LiveView components after it, both optional
dependencies.

Two things shape almost every decision here:

- **Text-first.** SCXML is the source of truth and the visualization reads it.
  The diagram is an output, not an editor backed by its own model.
- **The engine is not modified from here.** Statifier already emits trace
  effects at every Appendix D phase boundary, stamps them with
  `(macrostep, round)` counters, and retains source locations. A UI is one more
  interpreter of those effects. An engine gap is an `st-` bead, not a patch.

The repo carries no `-ex` suffix on purpose: the trace wire format is meant to
be language-neutral, so one UI can eventually serve interpreters written in
other stacks.

Read before making design decisions:

- `docs/adr/` - the reasoning; cite ADR numbers instead of re-arguing them.
  Numbers are repo-local, so cite other repos' as "statifier ADR-0012"
  (ADR-0001)
- `docs/research/260816-sui-kua-gui-research-and-direction.md` - the research
  that led to this repo existing, and the source the ADRs cite

## Build & Test

```bash
mise install                 # provision erlang + elixir
mix deps.get
mix quality --profile loop   # inner loop: format, compile, credo, changed-scope tests
mix quality                  # full gate: + dialyzer, deps audit, doctor, suite w/ coverage
mix quality --format json --report -   # machine-readable results
mix test                     # tests only
```

Run `mix quality --profile loop` between edits; full `mix quality` must be green
before any commit. The format stage runs in check mode (`format: [check: true]`
in `.quality.exs`, sui-b5y): drift fails the gate and nothing is rewritten, so
run `mix format` yourself before committing. See the ExQuality section at the
end of this file for the rules the gate expects you to follow.

Toolchain lives in `mise.toml`, and it is deliberately thin: no JRE (the Saxon
corpus transform is statifier-ex's), no Node (the JavaScript ships as source and
the host's own esbuild compiles it through `file:../deps/`).

## Conventions

- `@spec` on public functions; structs and pattern matching over multiple
  asserts in tests.
- Errors are values: evaluations return `{:ok, v} | {:error, e}`. Never
  rescue-to-default at a leaf.
- Optional dependencies are genuinely optional. Anything under `lib/` touching
  `Kino` or `Phoenix.LiveView` has to tolerate its absence at compile time -
  a host that wants the Livebook inspector must not be made to pull LiveView,
  or the reverse.
- Rendering is verified by what it renders. Assert on the produced structure,
  not on a line count; see the coverage note in `.quality.exs` for why the
  percentage is a floor rather than evidence.
- Gate thresholds are decisions, not tweaks. `.quality.exs`, `.doctor.exs`, and
  `coveralls.json` each carry the reason for their numbers at the number.
  Moving one means moving the reason with it, and never to make a red run
  green.
- Commit messages: title < 50 chars, simple present tense ("Adds ...",
  "Fixes ..."), body wrapped at ~72 chars, functional changes highlighted. No
  AI attribution trailers. Enforced mechanically by `/wurk:commit` via
  `commit_message.rb`; see `.claude/wurk/commit.md` for the reviewed
  thresholds and the attribution-ban wording collision to write around.
- SCXML in tests: triple-quoted heredocs, 4-space base indentation - matching
  statifier-ex, since fixtures move between the repos.

<!-- usage-rules-start -->
## ExQuality (`mix quality`)

Full reference: `deps/ex_quality/usage-rules.md`. Read it when a stage fails in a
way its own output does not explain, or when you need the JSON report shape.

The rules that do not wait to be looked up:

- **Never truncate the output.** No `| tail`, `| head`, `| grep`. A passing stage
  costs one line and detail prints only for failures, so truncating removes
  findings, not noise.
- **Read the `○` lines.** A skipped stage is not a passing one, and the reason
  says whether the gap is in this run or in what the project checks at all.
- **A scoped or `--quick` green is not a full green.** Neither measures coverage.
  Run a bare `mix quality` before reporting work complete.
- **Never go green by weakening the check.** Not by lowering a coverage or
  security threshold, not by `--skip` flags or `enabled: false`, not by
  `@tag :skip` on a failing test, not by narrowing scope. If a finding is
  genuinely wrong for this project, say so and let the user decide.
<!-- usage-rules-end -->

### Skipped stages seen here today

`mix quality` currently reports two `○` lines, and both are permanent rather
than gaps to close:

- **Gettext** - this is a component library for developer tooling, with no
  `.po` files. Gettext is translation tooling for applications.
- **Sobelow** - a Phoenix security scanner, and there is no Phoenix application
  here, only LiveView components a host mounts. Worth revisiting the day this
  package ships anything that handles a request itself.

Neither is a reason to add the dependency. A third `○` line appearing is a
different matter: check whether the stage should have run before assuming it
belongs in this list.
