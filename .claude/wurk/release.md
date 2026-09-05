# Release extension

Additional required steps for `/wurk:release` in this repo. The skill reads
this file before step 1 of its `kind: "hex"` recipe and treats what is here as
required steps placed where this file says. Extensions add; they never
override, and nothing below rewrites a step the skill already performs.

Read this together with `.claude/wurk.json`'s `release` block. Between them
they name every file a release commit here touches, and no others.

The reference for every shape below is **the most recent release-prep commit
on `main`**, resolved when you read this rather than named here. Find it with:

```bash
git log --oneline --no-patch -L '/@version/,+1:mix.exs'
```

The first line is the last commit that moved `@version`, and the last commit
that moved `@version` is the last release prep by definition. Where this file
and that commit disagree, the commit is the evidence and this file is the
defect.

**This file names no SHA for that reference, on purpose, and it carries no
version string anywhere.** A hard-coded reference stops being the most recent
the moment the next release lands: the sentence that used to sit here named a
commit and asserted it was the latest, and it went two releases stale before
`sui-040` caught it. Nothing below needs editing at a release, and a release
commit does not touch this file - the table at the end lists every file it
does touch, and this is not one of them.

Commits cited further down are historical evidence for a claim about the past
("this happened once, in that commit"). They are not the reference, and they
stay correct as releases accumulate.

## Why the recipe names no changelog

`kind: "hex"`'s changelog step renames a `## [Unreleased]` heading in one file
to `## [X.Y.Z] - YYYY-MM-DD`. This repo has no such heading and never will:
`changelog.mode` is `fragments`, and `CHANGELOG.md` says so in its own header -
unreleased work lives one file per issue in `changelog.d/`, and the fragments
are assembled into a version section at release. Pointing `release.changelog`
at `CHANGELOG.md` would make the skill's precondition read for an unreleased
section that is not there, and its edit rename a heading that does not exist.

So `release.changelog` is deliberately absent, and a recipe that does not name
a changelog names no changelog edit. The promotion this repo actually performs
is step A below - a required step, not an optional one. A release commit
without it is not a release commit.

The unreleased-work check the skill makes before anything else reads
`changelog.d/` here: if the directory holds no fragment other than its own
`README.md`, there is nothing to release, and the run stops exactly as it
would on an empty unreleased section.

## Step A: promote the changelog fragments

Placed where the skill's changelog step would have been, in the same commit as
the version bump, and modeled on the reference prep commit above.

1. Read every `changelog.d/*.md` fragment except `README.md`. Each is a Keep a
   Changelog section heading followed by its bullets.
2. Insert a new `## [X.Y.Z] YYYY-MM-DD` section into `CHANGELOG.md` directly
   below the file's explanatory header block and directly above the previous
   version's section, dated today. The heading form is the one the file
   already uses - the bracketed version and the date, **with no separator
   between them**. It is not the skill's own `## [X.Y.Z] - YYYY-MM-DD`, and
   copying that dash in would make the new section the only one in the file
   shaped differently from its neighbours.
3. Under the heading, write a short lead paragraph saying what the release is,
   then the fragments' bullets grouped by heading and ordered `Added`,
   `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
   **Carry every bullet over byte for byte.** The lead paragraph is the only
   prose written at release time; reordering, consolidating or rewording a
   fragment's bullet is an editorial pass a human does separately, before the
   release.
4. **Add no link reference.** `CHANGELOG.md` here carries no link-reference
   block at all - no `[X.Y.Z]:` line, no releases/tag URLs - and no release
   prep has ever added one. The bracketed version in the heading is plain text
   in this file, not a Markdown link with a definition owed somewhere below.
   Adding a reference block at release time would be introducing a convention,
   which is a decision for a human and not a mechanical release step.
5. Delete the promoted fragment files in the same commit. `README.md` stays.
   `changelog.d/README.md` states the same rule from the other side.

Whether the release is major, minor or patch is not decided here - the version
is explicit input to the skill. The fragments' headings are evidence for that
judgement, not a rule that computes it.

## There is no second version carrier

Nothing in `lib/` or `docs/` carries the package version a second time. The
version lives once, as `@version` at the top of `mix.exs`, and
`version: @version` in `project/0` reads it from there. There is no
compiler-style stamped constant here and no parity assertion in the suite, so
the recipe's `version_file` edit is the whole of the version bump.

One near-miss is worth naming so it is not rediscovered as a bug every
release: `assets/package.json` has a `"version"` field that does **not** track
the Hex version. It is **not** a release carrier and a release commit does not
touch it. That file describes the JavaScript source package the host's own
esbuild compiles through `file:../deps/`; it was created already carrying its
string rather than bumped into it (`61d647f`), no release prep has moved it
since, and nothing asserts it against `Mix.Project.config()[:version]`. Its
value is deliberately not quoted here - read it with
`grep '"version"' assets/package.json` when you need it. If it should track
the Hex version, that is a decision to record and then a step to add here -
not something to infer from two strings happening to match on the day someone
looked.

## The README install pin

`release.readme_pin` is `true`. `README.md` carries a
`{:statifier_ui, "~> X.Y"}` pin in its `def deps` snippet - the major/minor
form with the patch component dropped that the skill's own step bumps, so the
pin needs no step of its own here. It is named only so that the carriers a
release moves are all listed in one place.

The pin's current value is not written down here, for the same reason no
version is written down anywhere else in this file. Read it and check it
against the version file instead:

```bash
grep 'statifier_ui, "~>' README.md   # the pin
grep '@version "' mix.exs            # the version it should track
```

They should agree on major and minor. If they ever do not, the pin edit
repairs the drift in one move rather than stepping one release at a time: it
goes straight to the current major/minor, and that is the recipe working, not
a mistake to correct back. That has happened once - the 0.2.0 prep bumped the
version file without bumping the pin, and the following prep carried the pin
across two minors in a single edit. The two carriers have agreed since.

## The files a release commit touches

Exactly these, and a release commit that touches anything else is wrong:

| File | Moved by |
|---|---|
| `mix.exs` | the recipe's `version_file` |
| `README.md` | the recipe's `readme_pin` |
| `CHANGELOG.md` | step A |
| `changelog.d/*.md` (deleted) | step A |

## What a release here still is not

The skill does not tag, push, open a request or publish, and this extension
does not either. In this repo those are the operator's, in every campaign and
outside every campaign. `CLAUDE.md`'s authority table says it twice: a version
bump on a release bead's branch is authorized only on "an operator-authorized
release bead, inside a campaign carrying the operator's explicit consent", and
"a release (tag, `mix hex.publish`, GitHub release)" carries the trigger
`never`. The one thing a release-prep request contains is the version bump and
the fragment promotion above.
