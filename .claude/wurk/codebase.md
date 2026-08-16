# Project orientation: statifier-ui

UI components for authoring, observing, inspecting, and debugging statifier
statecharts. A component library, not an application: the host mounts what it
wants.

**This repo is early.** As of sui-lgz, `lib/` holds one module. An orientation
file for a codebase that barely exists is a promise about where things will go,
so treat the layout below as the intended shape and check it against reality
before relying on it. Correct it as the code lands rather than letting it drift.

## Layout, intended

`lib/statifier_ui/` splits by integration, because the integrations are
optional and must not reach into each other:

- `kino/` - the Livebook inspector (first milestone, sui-t36). Depends on
  `:kino`, which is an optional dep.
- `live/` - LiveView components. Depends on `:phoenix_live_view`, also
  optional.
- `trace/` - the language-neutral wire format and the code that turns
  statifier trace effects into it. Depends on neither integration, and that is
  the point: it is the layer a non-Elixir interpreter could target.
- `assets/` (repo root, not under `lib/`) - CodeMirror 6 and elkjs sources,
  distributed as source for the host's own esbuild to compile via
  `file:../deps/`. Never bundled here.

The split is a build constraint, not taste. Anything under `lib/` touching
`Kino` or `Phoenix.LiveView` has to tolerate that module being absent at
compile time.

## Where the real information is

Most of what a session needs to know about statecharts is not in this repo:

- `../statifier-ex/docs/observability.md` - the trace effects, their
  `(macrostep, round)` stamps, and the subscriber seam. This is the input this
  whole package renders (statifier ADR-0012).
- `../statifier-ex/docs/architecture.md` - the pure core and the effect model.
- `../statifier-ex/lib/statifier/effect/trace/` - one struct per trace effect.
  The wire format is a projection of these; read them before inventing a field.
- `docs/research/260816-sui-kua-gui-research-and-direction.md` - why this repo
  exists and why each major choice was made. The ADRs cite it.
- `docs/adr/` - the settled decisions. Cite the number instead of re-arguing.

## Terms of art (the best search keys)

From statifier, and worth grepping there rather than here: `macrostep`,
`microstep`, `configuration` (full versus leaf-state view), `t_index` /
`c_index`, `Effect`, `Trace`, `Replay`, `record: true`.

This repo's own coinages, as they land: the wire format's event names, fixture
sidecar names, and the elkjs layout options.

## Reading rules

- **The engine is read-only from here.** A missing trace effect or fixture hook
  is an `st-` bead in statifier-ex, not a patch applied from this repo. This is
  the single most important rule in this file.
- **Text is the source of truth.** SCXML in, visualization out. A change that
  makes the diagram authoritative over the source is a design error, not a
  feature.
- **The wire format is language-neutral on purpose.** Before adding an Elixir
  term, a pid, or a struct to something that crosses it, check whether another
  interpreter could produce it. Usually the answer is no.
- Optional deps are genuinely optional: a Livebook host must not be made to
  pull LiveView, or the reverse.
