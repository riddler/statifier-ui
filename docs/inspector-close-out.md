# Livebook inspector: close-out audit

Audit of the `sui-t36` epic against the milestone text it was filed with,
written 2026-09-02 for `sui-tld`. All eight children closed on 2026-08-22
(PRs 12, 13, 14, 28, 29, 30, 32, 34), and later work extended the panes
through PR 64. The epic itself stays open: its acceptance is the manual
walk of `notebooks/inspector.livemd`, which is a human's to perform. This
document is the audit, not the close.

It records three things, in this order: what the milestone asked for and
where each clause landed, whether the notebook's every code reference
still resolves against `lib/`, and what remains, as bead ids.

## The milestone text

> A Kino widget subscribing to a `Statifier.Session`: current-configuration
> rendering, event log keyed by `(macrostep, round)`, event-injection form
> fed by the fixtures event palette, datamodel explorer tree against
> fixture scenarios or the live session. Rendering may start Mermaid/smcat
> based (accepting the cross-hierarchy transition limit) and swap to the
> elkjs SVG renderer later. Needs only statifier + kino - no Phoenix. The
> Stately-inspector bridge is explicitly out of scope.

## Shipped, changed, remaining

| Milestone clause | Verdict | Where it lives | PRs |
|---|---|---|---|
| Kino widget over a `Statifier.Session` | shipped | `StatifierUI.Kino.inspect/3`, assembling `StatifierUI.Inspector` over `StatifierUI.Trace.Subscriber` | 14, 34 |
| Current-configuration rendering | shipped | `StatifierUI.Diagram` (Mermaid `stateDiagram-v2`, pure, no Kino dependency) | 28, 58 |
| Event log keyed by `(macrostep, round)` | shipped | `StatifierUI.EventLog` with `.Macrostep`, `.Round`, `.Labels`, `.Markdown` | 29, 33 |
| Event-injection form fed by the fixtures palette | shipped | `StatifierUI.EventInjection` with `.Palette`, `.Draft`, `.Entry`, over `StatifierUI.Fixtures` | 13, 30, 43 |
| Datamodel explorer against fixtures or the live session | shipped | `StatifierUI.DatamodelExplorer` with `.Entry`, `.Scope`, `.Markdown` (authoring mode and live mode both) | 32 |
| Needs only statifier + kino, no Phoenix | shipped | `StatifierUI.Kino` is the only Kino-touching module and compiles absent; `StatifierUI.Live` is the separate optional LiveView half | 34, 62 |
| Stately-inspector bridge out of scope | shipped as stated | not built, and nothing in `lib/` reaches for it | - |
| Rendering may start Mermaid and swap to elkjs later | **shipped differently** | Mermaid only. See below. | 28 |

### Shipped beyond the milestone

Work after the epic's children closed extended the same four panes rather
than replacing them, and the notebook walk exercises it:

| Addition | Where | PRs |
|---|---|---|
| Trace projection and redaction (ADR-0012) | `StatifierUI.Trace.Projection` | 55 |
| Macrostep scrubber linking the diagram to the log | `StatifierUI.Inspector`, `StatifierUI.EventLog` | 59 |
| Deep links from a macrostep to its trace | `StatifierUI.EventLog.DeepLink`, `StatifierUI.Trace.DeepLink` | 61 |
| Read-only ops components for LiveView hosts | `StatifierUI.Live`, `StatifierUI.Live.State` | 62 |
| A halted chart's final configuration in the diagram | `StatifierUI.Inspector.active_configuration/2`, reading `trace.done` | 63 |
| Refusing datamodel edits over a projected trace | `StatifierUI.EventInjection`, `StatifierUI.DatamodelExplorer` | 64 |
| OTel correlation carried on the wire | `StatifierUI.Trace.Otel` | 56, 57 |

### The one clause that shipped differently

**The elkjs renderer is not built.** `StatifierUI.Diagram` emits Mermaid
and nothing else; the repo has no `assets/` tree, so ADR-0008's
client-side elkjs SVG renderer exists as an accepted decision with no
implementation behind it. The smcat half of the milestone's
"Mermaid/smcat" was never started either, and is not planned - Mermaid
was the compromise taken.

This is recorded, not silently dropped. `docs/adr/0008-client-side-elkjs-layout.md`
(accepted 2026-08-16) is the decision; `lib/statifier_ui/diagram.ex`'s
moduledoc names the Mermaid backend as the interim under a stable
"machine plus configuration in, source out" interface and enumerates the
six things Mermaid cannot express as accepted limits rather than
defects; `lib/statifier_ui/live.ex` names the same renderer as the
destination for its `phx-hook` seam.

Consequence for the reader of this audit: the cross-hierarchy transition
limit the milestone said it would accept is still accepted, and swapping
the backend is still the open work.

## Remaining, as bead ids

| Gap | Bead |
|---|---|
| Step-through controls over a persisted trace, including a datamodel diff between adjacent steps (the notebook's step 6 notes the datamodel explorer does not move with the scrubber) | `sui-2uz` |
| Trace capture ergonomics: record, save, reload as a one-liner | `sui-pb2` |
| Stale `sui-t36.8` moduledoc claims in three files | `sui-9pc` |
| Embedding and theming verification in a realistic host asset pipeline | `sui-191` |
| `mix.exs` `files:` omits `assets/` though ADR-0009 requires it be published | `sui-2ke` |

No new beads were filed by this audit. The one gap with no bead - an
implementation for ADR-0008's elkjs renderer - is raised as a candidate
in this bead's pull request rather than filed, because filing outside the
campaign's enumerated beads is the operator's call.

## Notebook reference check

Every `Module.fun` `notebooks/inspector.livemd` calls or cites, checked
against `lib/` and `deps/statifier/lib/` on 2026-09-02. All eight resolve;
nothing in the notebook is dead, so this audit changed no notebook text.

| Reference | Resolves to |
|---|---|
| `Statifier.compile/1` | `deps/statifier/lib/statifier.ex:102` (`compile/2`, second arg defaulted) |
| `Statifier.Session.start_link/2` | `deps/statifier/lib/statifier/session.ex:568` |
| `Statifier.Session.invocations/1` | `deps/statifier/lib/statifier/session.ex:748` |
| `StatifierUI.Fixtures.new/1` | `lib/statifier_ui/fixtures.ex:132` |
| `StatifierUI.Kino.inspect/3` | `lib/statifier_ui/kino.ex:122` (and the no-Kino clause at 371) |
| `StatifierUI.Inspector.active_configuration/2` | `lib/statifier_ui/inspector.ex:128` |
| `StatifierUI.Trace.Subscriber` | `lib/statifier_ui/trace/subscriber.ex:1` |
| `Process.exit/2` | Elixir standard library |

The option keys the notebook passes were checked the same way:
`:events` on `Fixtures.new/1`, `:source` on `Kino.inspect/3` (taken
through to the subscriber alongside `:capacity`), and `:trace` and
`:record` on `Session.start_link/2` are all live.

## What is left before the epic closes

The manual walk of `notebooks/inspector.livemd`, steps 1 through 9, by a
human at a Livebook. Nothing in this audit substitutes for it: the walk
checks rendered output against prose expectations, which is exactly the
class of check an agent defers.
