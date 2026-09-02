# ADR-0009: JavaScript ships as source

Status: accepted (2026-08-16)

## Context

The LiveView side of this package is hook-driven: the editor pane, the SVG
viewer, and the explorer all need client-side JavaScript, and the editor in
particular carries a real third-party dependency tree. A hex package has
three ways to deliver that JavaScript to a Phoenix host:

- **Colocated hooks and colocated CSS** (LiveView 1.1/1.2): JS lives next to
  the component that uses it and LiveView extracts it into the host's build.
  The official LiveView documentation is explicit that this covers small
  self-contained hooks only - libraries with real npm dependencies still
  hand-bundle or ship source. An editor built on a modular dependency graph
  cannot ride colocation.
- **A precompiled ESM bundle in `priv/static`** (the `live_monaco_editor`
  pattern): the package bundles everything ahead of time and the host serves
  the blob. Zero npm requirements on the host, but the host's bundler can
  neither tree-shake the blob nor dedupe its dependencies against the host's
  own, and this repository would need a Node toolchain to produce it.
- **Source in `assets/`, recompiled by the host** (the `live_toast`,
  `Backpex`, `live_svelte`, `live_vue` pattern): the host adds
  `"statifier_ui": "file:../deps/statifier_ui"` to its own
  `assets/package.json` and imports the hooks from its `app.js`; the host's
  esbuild compiles, tree-shakes, and dedupes the whole dependency tree.

The editor choice decides which of these is viable, so it belongs in the
same record. The research doc
(`docs/research/260816-sui-kua-gui-research-and-direction.md`, "LiveView
packaging") found that Livebook itself uses CodeMirror 6, not Monaco - it
migrated after the CM6 rewrite landed, and maintains
`codemirror-lang-elixir` as grammar prior art this project can lean on. CM6
is distributed as many small npm packages (`@codemirror/state`,
`@codemirror/view`, language and lint modules) composed by the consumer;
that modularity is exactly what a precompiled blob throws away and exactly
what a host bundler exploits.

Two standing constraints frame the choice. This repository's toolchain is
deliberately thin - `mise.toml` provisions no Node, and the gate never runs
a JS bundler (`CLAUDE.md`, "Build & Test"). And the JS in question is a
consumer of engine output, not engine behavior: whichever way it ships, the
text-first contract (ADR-0007) and the one-way dependency arrow (ADR-0004)
are untouched.

## Decision

**JavaScript ships as source in `assets/`, and the host's own bundler
compiles it.** A Phoenix host adds
`"statifier_ui": "file:../deps/statifier_ui"` to its `assets/package.json`
and imports the hooks into its `app.js`; no precompiled JS artifact is the
default delivery.

**The editor is CodeMirror 6.** Livebook's migration from Monaco is the
ecosystem's verdict, `livebook-dev/codemirror-lang-elixir` is directly
reusable prior art, and CM6's modular package graph is the concrete reason
source-recompile beats a precompiled blob: the host's bundler pulls only
the CM6 modules the hooks import, and dedupes them against any CM6 the host
already uses.

- **Colocated hooks/CSS are ruled out for anything touching npm
  dependencies.** They remain fine for a genuinely self-contained hook with
  no imports, but nothing that pulls CodeMirror - or any other third-party
  package - may ride them. This is LiveView's own documented boundary, not
  a local preference.
- **This repository's toolchain stays Node-free.** Shipping source means
  the gate never bundles; `assets/` is published as files in the hex
  package like any other, and correctness of the JS is verified the same
  way the rest of the package is - by what it renders, in the host's
  pipeline.
- **The precompiled ESM bundle in `priv/static` stays open as a later
  fallback, not the default.** If a class of zero-npm hosts materializes
  that source distribution cannot serve, offering a bundle alongside the
  source is an additive change - it does not supersede this record. Making
  it the default, or making it the only delivery, would.

**What this decision does not do:**

- It does not decide the rendering stack for the viewer. elkjs layout and
  plain SVG are sui-p61's decision; this record only fixes how whatever JS
  exists reaches the host.
- It does not decide how the Kino/Livebook integration gets its JavaScript.
  A Livebook host has no `assets/package.json` for a `file:` dependency to
  land in; see the open question below.
- It does not commit to building the fallback bundle, or to the toolchain
  that would produce it. If the fallback is ever exercised, how a Node-free
  repository produces a checked-in or released bundle is that ADR's problem
  to solve, not a debt this one incurs.

**Open question.** Kino widgets deliver their JS through `Kino.JS`, which
serves assets shipped inside the package rather than through a host
bundler - Livebook offers no npm pipeline for `file:../deps/` to plug into.
The Livebook inspector is this project's first milestone (research doc,
"Decisions extracted"), so the Kino integration may need a prebuilt asset
long before any zero-npm Phoenix host does. Whether that asset can stay
small enough to hand-write, whether it triggers the fallback above, and
where it gets built given the Node-free toolchain, is unresolved here and
should be settled by the bead that builds the inspector (sui-t36), with a
superseding or amending record if the answer contradicts this one.

## Consequences

- **Phoenix hosts need Node and a bundler in their own asset pipeline.**
  Every host adds the `file:../deps/statifier_ui` line and an import to
  `app.js` - two documented steps, but real ones, and a host with no npm
  usage at all cannot consume the LiveView components until the fallback
  exists. This is the standard cost of the `live_toast`/`Backpex` pattern
  and is what the hex package's install docs must walk through.
- The host's bundler owns optimization: tree-shaking unused CM6 modules,
  deduping CodeMirror against the host's own editor usage, and applying the
  host's minification and sourcemap settings. A precompiled blob could do
  none of these.
- This repository never debugs a bundler configuration of its own, but it
  also cannot fully verify the JS end-to-end in its gate - there is no
  Node to run one. Hook correctness at the boundary is exercised through
  what the LiveComponents render (stamped structure, per ADR-0007's
  data-attribute contract); compile-level breakage in the JS surfaces in a
  host's build, not this repo's. Accepted as the price of the thin
  toolchain; an example host app, when one exists, is the natural place to
  catch it earlier.
- `assets/` becomes public API. Its entry points, export names, and the
  hook names hosts register are a compatibility surface with the same
  versioning obligations as the Elixir modules.
- CM6 major-version churn lands on hosts as an npm dependency update
  mediated by this package's `package.json` constraints, not as a silent
  blob swap - visible, and resolvable with the host's usual npm tooling.
- The Kino open question above is a known gap in this record's coverage:
  the decision as stated fully serves the LiveView integration and leaves
  the Livebook-first milestone's JS delivery to be confirmed.

**Alternatives considered:**

- **Colocated hooks and colocated CSS** (LiveView 1.1/1.2): the
  lowest-friction path for hosts, but explicitly scoped by LiveView's own
  documentation to exclude third-party npm dependencies, which is precisely
  what CodeMirror is. Rejected as the delivery mechanism; individual
  dependency-free hooks may still use it where it genuinely fits.
- **Precompiled ESM bundle in `priv/static`** (`live_monaco_editor`
  pattern): zero npm burden on hosts, but defeats tree-shaking and
  deduping, ships every host the whole editor whether used or not, and
  forces a Node toolchain into a repository that deliberately has none.
  Rejected as the default; retained as the documented fallback for
  zero-npm hosts, adopted only if that need materializes.
- **Monaco as the editor**: the other mainstream embeddable editor, and
  the one `live_monaco_editor` wraps - but it ships as a monolith that
  practically requires the precompiled-blob pattern, and Livebook migrated
  away from it to CM6. Choosing Monaco would have forced the rejected
  distribution model. Rejected.

---

## Note (2026-09-02): the `assets/` layout the first JavaScript fixed

A dated note rather than an amendment, because no clause of the decision
moves. JavaScript still ships as source under `assets/`, the host's bundler
still compiles it, the editor is still CodeMirror 6, the precompiled
`priv/static` bundle is still the documented fallback and still not the
default, and the Kino open question is still open. Nothing above this line
changes.

The note exists because this record made two commitments that only one of them
could be checked against an empty directory. It said the JavaScript would live
in `assets/`, and it said **"`assets/` becomes public API. Its entry points,
export names, and the hook names hosts register are a compatibility surface
with the same versioning obligations as the Elixir modules."** Until sui-wqr
there was no `assets/`, so that public API had no members and no shape. The
first file to land settles the shape by existing, whether or not anyone writes
it down. This writes it down.

**The layout.**

```
assets/
  package.json          name "statifier_ui", "type": "module", main js/index.js
  js/
    index.js            the entry point: named hook exports + StatifierUIHooks
    expression_input.js the StatifierUIExpressionInput hook
```

**The `file:` target is `assets/`, not the package root.** A host adds

```json
"statifier_ui": "file:../deps/statifier_ui/assets"
```

This differs by one path segment from the line the decision above quotes, and
the reason is mechanical rather than a change of mind: npm resolves a `file:`
dependency against the directory holding `package.json`, and this package's
root already has a `mix.exs` and a hex `files:` list. Putting `package.json`
at the root would mean publishing a second manifest at the top of an Elixir
package and adding the root's non-JavaScript neighbours to npm's view of it.
This is a deliberate departure from the four packages this record named as
the pattern being adopted, not a precedent borrowed from them: `live_toast`,
`Backpex`, `live_svelte`, and `live_vue` all keep their `package.json` at the
repository root and are installed as `file:../deps/<package>`. The mechanical
reason above is why this package does not follow them. The decision's own
commitment - source, `file:`, host bundler - is unchanged; only the segment
the path ends on is now stated.

**`assets/js/index.js` is the entry point, and the export names are the API.**
`StatifierUIExpressionInput` is exported by name; `StatifierUIHooks` is every
hook this package ships, keyed by the name its component renders, so a host
registers all of them by spreading one object. A hook name is rendered as
`phx-hook` by the Elixir side and typed into a host's `app.js` by hand, which
makes renaming one exactly as breaking as renaming a public Elixir function,
and it is versioned that way.

**The first hook has no imports, and that is inside this record rather than an
exception to it.** The decision rules out colocated hooks "for anything
touching npm dependencies" and keeps them "fine for a genuinely self-contained
hook with no imports"; CodeMirror 6 is chosen as **the editor**, meaning the
source-editing pane. `StatifierUIExpressionInput` is neither: it upgrades a
one-line `<input>` inside another package's inspector form, and it imports
nothing. It ships as source under `assets/` anyway, because that is the
delivery this record decides for all of this package's JavaScript and a second
delivery mechanism for one file would be the thing worth avoiding. A host that
registers no hook keeps the field, which renders a native `<datalist>` and
needs no JavaScript at all.

**What the gate can and cannot say about any of this.** The toolchain stays
Node-free, so nothing here lints, bundles, type-checks, or executes the
JavaScript, exactly as the Consequences above predict. Two things are
mechanically held: `test/packaging_test.exs` fails the moment a file exists
under `assets/` that `mix.exs`'s hex `files:` list does not publish, and
`StatifierUI.Live.ExpressionInput`'s tests assert the hook name and the
`data-completions` payload the hook reads. The JavaScript's own correctness
still surfaces in a host's build, which is the price this record already
accepted.

No decision moves, no clause is edited, and no text above this line changes.
Filed with `sui-wqr`, campaign 027's condition-editor arc.
