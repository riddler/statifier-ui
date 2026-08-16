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
blanket - an action whose trigger has not fired is still unauthorized, and an
explicit "do not commit", "do not push", or equivalent from the current user
overrides every row here.

| Action | Trigger | Still unauthorized when |
|---|---|---|
| `bd` task tracking (`create`, `claim`, `update`, `note`) | any time | never - this is the default profile too |
| `mix quality` in any profile | any time | never - running the gate costs nothing but time |
| `git commit` | the claimed bead's work is complete **and** full `mix quality` is green; a change touching no Elixir code has no gate to run and may commit on review of the diff alone | on a red gate, on a `--profile loop` or otherwise scoped run, or with unrelated changes in the tree |
| `git push` | the user asks for it in their own words | inferred from "the work is done"; finishing a bead is not a request to publish it |
| `bd close <id>` | the work is on `origin/main`, verified against the remote | at commit time, or on a local commit that has not been pushed |
| `bd dolt push` | bead state changed locally **and** the git side of the same change has already reached `origin` | as a way to publish beads for work that is not on `origin/main` yet |

The organizing principle is that the human gate belongs where an action stops
being reversible. A local commit is undone with `git reset --soft HEAD~1`; a
push and a closed bead are visible to other machines, so those keep their gate.

**There is no CI and no second reviewer.** One contributor means the local gate
is the only thing standing between a mistake and `origin/main`, which is why
the `git commit` row above spends its whole trigger on a full green rather than
a scoped one. A profiled or scoped run is not evidence for that row.

Authority always belongs to the session that owns the work, not to a subagent
it delegates to. A subagent that believes it has satisfied a trigger reports
that; it does not act on it.

Note on the current state: worktrees, per-bead branches, and the `/wurk:*`
manifest arrive with sui-lgz. Until then the repo has one branch, and the
"the user asks for it in their own words" trigger on `git push` is carrying
more weight than usual.

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
before any commit. The gate formats your code for you - do not run `mix format`
as a separate step. See the ExQuality section at the end of this file for the
rules the gate expects you to follow.

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
  AI attribution trailers. (sui-a61 makes these mechanical.)
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
