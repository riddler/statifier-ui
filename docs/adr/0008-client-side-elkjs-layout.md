# ADR-0008: Client-side elkjs layout rendering plain SVG

Status: accepted (2026-08-16)

## Context

ADR-0007 fixed the direction of data flow - the diagram is a read-only
rendering of SCXML text - and explicitly left the rendering stack to its own
decision, this one. What remains to decide is where layout runs and what
draws the result.

The renderer's input domain sets the bar. Because charts are the conformance
corpus's `.scxml` files (ADR-0007, statifier ADR-0006), the renderer must
draw everything conformant SCXML contains: compound states nested to
arbitrary depth, parallel regions, history pseudo-states, and transitions
between substates of different composite states - the cross-hierarchy edges
that SCXML's LCCA semantics make routine rather than exotic. A layout engine
that cannot place children inside their parents while routing edges across
that hierarchy is not a candidate.

The renderer's output also carries obligations already accepted elsewhere.
ADR-0007's sync contract requires each rendered element to be stamped with
the engine's document-order identities (`data-state-index`, `data-t-index`,
`data-c-index`) and nothing diagram-native; live highlighting consumes trace
effects at the seams adopted by ADR-0002. And this repo's conventions
require rendering to be verified by the structure it produces, not pixels.

Finally, the toolchain is deliberately thin. `mise.toml` provisions Erlang
and Elixir only - no Node - and the JavaScript ships as source that the
host's own bundler compiles (the `file:../deps/` strategy, sui-8tj). Any
layout dependency has to live comfortably inside that: a browser-side
library imported by a hook, not a server-side runtime.

The research doc (`docs/research/260816-sui-kua-gui-research-and-direction.md`)
surveyed the landscape - dedicated statechart tools, web canvas frameworks,
diagram DSLs, commercial libraries - and this record extracts its rendering
verdict.

## Decision

**Statechart layout runs client-side, in the viewer's JS hook, using elkjs -
the ELK layered algorithm with `hierarchyHandling: INCLUDE_CHILDREN` - and
the hook renders the computed layout as plain SVG.** No React, no canvas
editor framework, no server-side layout step. The server sends chart
structure and engine identities; geometry is computed and drawn where it is
displayed.

**Why elkjs.** ELK layered with `INCLUDE_CHILDREN` is the only credible
answer to compound-state layout in the open-source web ecosystem: it lays
out a nested hierarchy as one problem, so edges can route across composite
boundaries instead of each container being an opaque box laid out in
isolation. That capability is not incidental - ELK originated in statechart
research tooling (KIELER), so hierarchical state layout is its home ground,
not an adaptation. It is EPL-2.0, which an MIT package can depend on.

**Why client-side.** ELK is a Java engine; elkjs is its JS transpilation.
Running that JS port on the server would mean adding Node to a toolchain
that deliberately has none, to compute geometry for a browser that is
already running a JS engine - it buys nothing for a browser UI. Client-side
layout also puts the computation next to what it needs: node dimensions
depend on rendered label sizes, which are a browser measurement. And it
keeps the server's output honest per ADR-0007 - structure and identities on
the wire, never coordinates, so no layout state exists server-side to drift.

**Why plain SVG.** The viewer is read-only (ADR-0007), so it needs none of
what a node-editor framework provides - drag handles, connection logic,
editing state - and every framework brings a runtime the host must adopt.
Plain SVG built by the hook has no framework dependency at all, which
matters twice over: LiveView hosts are not made to carry React for a
read-only picture, and the Kino inspector renders in Livebook's iframe with
the same code. SVG elements also take the `data-*` identity stamps directly,
and the resulting DOM is exactly the assertable structure the "verified by
what it renders" convention wants tests to assert on.

**The known risk, named so it gets budgeted.** Parallel regions and history
pseudo-states are the layout cases expected to need tuning: parallel
regions stress how `INCLUDE_CHILDREN` partitions siblings that must render
as adjacent orthogonal compartments, and history pseudo-states are small
decorated nodes whose conventional placement (inside the parent, near its
boundary) is a styling convention ELK does not know. Neither is expected to
be disqualifying - both are configuration and post-processing, not missing
capability - but the first renderer bead should plan real time for them
rather than discovering the cost mid-implementation.

**What this decision does not do:**

- It does not reopen the direction of data flow. The viewer stays a
  read-only output of the text (ADR-0007); this record only chooses what
  computes and draws that output.
- It does not decide the Livebook inspector's first rendering. Whether
  sui-t36 ships a temporary Mermaid rendering (accepting the
  cross-hierarchy limit for a first cut) or waits for the elkjs renderer is
  that bead's call; this record fixes only the destination stack.
- It does not decide JS distribution mechanics. elkjs is a dependency of
  the shipped JS source; how that source reaches a host's bundler is
  sui-8tj's decision, and this record only requires that the answer remain
  a browser-side import.
- It does not pin elkjs configuration beyond the algorithm and
  `hierarchyHandling`. Spacing, edge routing style, port constraints, and
  the parallel-region and history treatments above are implementation
  tuning, owned by the renderer beads and adjustable without amending this
  record.
- It does not preclude static SCXML-to-SVG for documentation.
  state-machine-cat (active, reads real SCXML) covers the
  render-a-chart-for-the-docs case if it ever arises; that would be an
  offline tool producing pictures, not a second viewer, and it carries none
  of the identity-stamping obligations.

## Consequences

- **Layout cost lands in the browser.** Large charts pay it at view time
  rather than build time. elkjs runs in a web worker if that cost ever
  blocks the main thread noticeably - an implementation option this record
  leaves open, not a commitment.
- The hook owns measurement: ELK needs node dimensions before layout, so
  label sizing happens browser-side before elkjs runs. This is a
  consequence of layout living where text metrics live, and it is why a
  server-side port could never have produced faithful geometry anyway.
- The whole corpus domain must render - the same obligation ADR-0007's
  consequences already state - and elkjs is the piece that makes it
  satisfiable. Cross-hierarchy transitions, the case that disqualified
  Mermaid, are the regression cases the renderer's tests should carry from
  the start.
- Parallel-region and history-pseudo-state tuning is a named line item in
  renderer estimates, per the risk above.
- Rendering tests assert on produced SVG structure and the stamped
  `data-*` attributes (the contract ADR-0007's consequences already made
  public), never on coordinates or pixels - layout numbers are elkjs's
  output, not this repo's promise.
- No framework means no framework ecosystem: minimaps, auto-fit,
  pan/zoom come from small purpose-built code or small libraries, not from
  a canvas framework's feature list. Accepted - a read-only viewer's
  interaction surface is small, and the trade buys freedom from React in
  LiveView hosts and Livebook alike.
- elkjs (EPL-2.0) joins the dependency tree of an MIT package. EPL-2.0 as
  an unmodified dependency imposes no obligations on this package's own
  license; recorded here so it is not re-litigated at publish time.

**Alternatives considered:**

- **Server-side layout** (Node running elkjs, or the JVM running ELK
  proper): adds a runtime the toolchain deliberately lacks, separates
  layout from the text metrics it needs, and puts geometry on the wire
  where ADR-0007 wants only structure and identities. Buys nothing for a
  browser UI. Rejected.
- **React Flow**: the emerging default canvas for bespoke statechart
  editors, and exactly the wrong shape here - it is a node-editor
  framework, and ADR-0007 already ruled out editing on the canvas. Adopting
  it would force React into LiveView hosts to get features this viewer must
  not have. Rejected.
- **Mermaid stateDiagram-v2**: disqualified for execution-accurate
  rendering - it cannot draw transitions between substates of different
  composite states, which SCXML's LCCA semantics make routine. A renderer
  that cannot draw them misrepresents the charts the corpus contains.
  Rejected for the viewer; sui-t36 decides whether it serves as a
  temporary first rendering in the Livebook inspector.
- **state-machine-cat**: active, honest SCXML support, static SVG output -
  but a whole-document renderer with its own layout, offering no seam for
  per-element identity stamping or live trace-driven highlighting. Kept in
  the back pocket for static documentation export; not a foundation for
  the interactive viewer. Rejected for this role.
- **Commercial canvas libraries** (JointJS+, GoJS, ~$2,900-3,495 per
  developer): add nothing over elkjs plus SVG that this viewer needs, at a
  per-seat price incompatible with an open-source component library whose
  hosts would each need licenses. Rejected.
