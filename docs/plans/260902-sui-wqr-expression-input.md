# Rich expression-editing component Implementation Plan

## Overview

sb ADR-0005 decision 9 renders an `:expression` field as a plain text input and
decision 15 defers the richer affordance - "Rich expression editing is
statifier-ui's" - to a component sb consumes through its `expression_component`
seam. No such component exists anywhere in the fleet. This plan ships it: a
LiveView function component in this package, its first JavaScript, and the
completion data behind it.

Bead: sui-wqr. Upstream half: px-15q (`Predicator.Vocabulary`), landed on
predicator-ex main at 780e4319d9b9458cd99d2e4212296cab54ffcc7f and **not
published to Hex**, so this branch carries an interim git pin.

## Current State Analysis

**The seam.** `StatifierBlocks.Editor.Field` (`lib/statifier_blocks/editor/field.ex:284-306`)
calls the override as a bare one-argument function - not through a HEEx
component tag - with a fixed map:

```elixir
{@expression_component.(%{
  field: @field,
  id: input_id(@field),
  name: input_name(@field),
  value: to_text(@field.value),
  candidates: @path_candidates
})}
```

Two consequences fix the component's shape:

- **`attr` defaults do not apply.** A direct function call passes the map
  verbatim, so the component must supply its own defaults for every assign
  outside that five-key set or a missing key raises at render.
- **`field` is a `StatifierBlocks.ViewModel.Field` struct.** This package must
  not depend on statifier_blocks (ADR-0004's one-way arrow), so the component
  accepts the key and never reads it.

**The change event already exists.** The field renders inside
`StatifierBlocks.Editor.ConfigForm`'s `<form phx-change="config-change">`
(`lib/statifier_blocks/editor/config_form.ex:63-70`). An `<input>` carrying the
supplied `name` therefore round-trips with no event of its own; the hook only
has to dispatch a bubbling `input` event after it writes a completion in.

**The vocabulary.** `Predicator.Vocabulary` (px-15q) enumerates 58 fixed
lexemes as `%{lexeme, token_type, category, display, doc}` and resolves
callable functions through the provider chain as `functions/1`, each with an
`:arity` and a `:display` of the form `len(...)`. `mix.lock` here pins hex
predicator 9.0.0, which does not have the module.

**The packaging guard.** `test/packaging_test.exs` (sui#73, landed today) goes
red the moment a file exists under `assets/` unless `mix.exs`'s `package()`
`files:` names `assets` in the same commit. This is the first `assets/` file,
so the entry and the directory land together here.

**ADR-0009 governs the JavaScript** and is not amended by this work. It decides
delivery (source under `assets/`, host bundler compiles) and it decides the
*editor* is CodeMirror 6. This component is a single-line expression field
inside another package's inspector, not the SCXML editor pane, and its hook has
no imports at all - the case ADR-0009 explicitly keeps open ("individual
dependency-free hooks may still use it where it genuinely fits"). What ADR-0009
left unspecified is the `assets/` **layout**, which it simultaneously declared
public API; this commit fixes that layout de facto, so it is recorded in a
dated Note rather than left to be inferred from a directory listing.

## FILE MAP

New:

| Path | What |
|---|---|
| `lib/statifier_ui/expression.ex` | pure: `completions/2`, `datalist/1`, `vocabulary_available?/0` over `Predicator.Vocabulary` + declared paths |
| `lib/statifier_ui/live/expression_input.ex` | the function component (LiveView-guarded, with the absent-LiveView stub arm) |
| `assets/package.json` | npm identity for `file:../deps/statifier_ui/assets`; no dependencies |
| `assets/js/index.js` | the package entry point; named + default hook exports |
| `assets/js/expression_input.js` | the `StatifierUIExpressionInput` hook, dependency-free |
| `test/statifier_ui/expression_test.exs` | vocabulary source, degraded source, datalist filter |
| `test/statifier_ui/live/expression_input_test.exs` | render, direct-call assigns, round-trip, degraded paths |
| `changelog.d/sui-wqr.md` | Added fragment |

Modified:

| Path | What |
|---|---|
| `mix.exs` | `assets` into `package()` `files:`; predicator to the interim git pin with `override: true` |
| `docs/adr/0009-javascript-ships-as-source.md` | a dated Note appended, fixing the layout (family Note shape; ZERO removed lines) |
| `mix.lock` | the git pin |
| `README.md` | embedding section: the `file:` line, the hook name, the seam call |

Untouched, and declared so a sibling rebase is cheap: every ADR except
`0009`, whose file gains an appended Note and loses no line;
`lib/statifier_ui/live.ex`; every existing test.

## Phase 1 - the pure completion source

`StatifierUI.Expression`. `completions(candidates, opts)` returns
`[%{label, insert, kind, detail}]`: one entry per declared path (`kind:
"path"`), one per grammar lexeme (`kind:` the px category), one per resolved
function (`kind: "function"`, `insert` the name plus `(`). The predicator
module is reached through
`Application.get_env(:statifier_ui, :predicator_vocabulary, Predicator.Vocabulary)`
and guarded with `Code.ensure_loaded?/1` + `function_exported?/3`, so a host
resolving a predicator without `Vocabulary` gets `[]` for the grammar half and
keeps its declared paths - the degraded path the bead names, and the reason the
git pin is convenience rather than a hard floor.

`datalist/1` narrows a completion list to the word-shaped entries, which is
what a native `<datalist>` can usefully filter on.

- Automated: `mix quality --profile loop` green; the new test file passes,
  including the injected-absent-module case.

## Phase 2 - the component and its JavaScript

`StatifierUI.Live.ExpressionInput.expression_input/1`, compiled behind the same
`Code.ensure_loaded?(Phoenix.Component)` guard `StatifierUI.Live` uses, with a
raising stub in the else arm. It normalizes the assign map (defaults for
everything outside sb's five keys), renders

```
<div class="statifier-ui-expression">
  <input id name value list phx-hook data-completions data-vocabulary ...>
  <datalist id>…word-shaped options…</datalist>
</div>
```

and stamps the completion set as JSON on the input. No JS and no hook: the
native datalist is the affordance. Hook attached: it removes `list` on mount
and takes over.

`assets/js/expression_input.js` exports the hook - token under the caret,
prefix filter, a popup appended to `document.body` (so LiveView's DOM patching
never sees it), Up/Down/Enter/Tab/Escape, and a bubbling `input` event after an
insert so the host form's `phx-change` fires. `assets/js/index.js` re-exports
it as a named export and as a `hooks` default object.

- Automated: render assertions on the stamped structure (ADR-0007's
  data-attribute contract), the direct-call five-key invocation, a
  `phx-change` round-trip through a test LiveView, the LiveView-absent stub.
- Manual (deferred): the popup's keyboard behaviour in a real browser.

## Phase 3 - packaging, docs, and the record

`mix.exs`: `assets` into `files:` (the guard turns green with it), predicator
to `{:predicator, github: "riddler/predicator-ex", ref: "780e431…",
override: true}`. `mix hex.build` must succeed. README embedding section gains
the `file:../deps/statifier_ui/assets` line, the hook name, and the sb seam
call. The ADR-0009 Note records the layout. Changelog fragment.

- Automated: full `mix quality` green; `mix hex.build` succeeds and lists
  `assets/`; `git diff origin/main -- docs/adr/` shows zero removed lines.

## Deferred Manual Verification

- The completion popup's live keyboard behaviour and appearance (captured on a
  private port against the shipped asset; keyboard-driven insertion is
  scripted, visual judgement is the operator's).
- That a real Phoenix host's esbuild resolves `file:../deps/statifier_ui/assets`
  and the import - this repo has no Node and ADR-0009 accepts that.
- The end-to-end sb consumption (that half of the arc is a separate bead).
