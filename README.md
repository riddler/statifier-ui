# StatifierUI

[![CI](https://github.com/riddler/statifier-ui/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier-ui/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_ui.svg)](https://hex.pm/packages/statifier_ui)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_ui.svg)](https://hex.pm/packages/statifier_ui)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_ui/)
[![License](https://img.shields.io/hexpm/l/statifier_ui.svg)](https://github.com/riddler/statifier-ui/blob/main/LICENSE)

UI components for authoring, observing, inspecting, and debugging
[statifier](https://github.com/riddler/statifier-ex) statecharts and
[predicator](https://github.com/riddler/predicator) expressions.

Debug-first and text-first: SCXML is the source of truth, and the visualization
reads it. See the
[GUI research and direction document](https://github.com/riddler/statifier-ui/blob/main/docs/research/260816-sui-kua-gui-research-and-direction.md)
for how that direction was reached, and the
[architecture decision records](https://github.com/riddler/statifier-ui/tree/main/docs/adr)
for the decisions themselves.

Statifier already emits trace effects at every Appendix D phase boundary,
stamps them with `(macrostep, round)` counters, and retains source locations on
states, transitions, and expressions. A UI is one more interpreter of those
effects; the engine needs nothing changed to support it.

## Installation

```elixir
def deps do
  [
    {:statifier_ui, "~> 0.1"}
  ]
end
```

The `:kino` (Livebook) and `:phoenix_live_view` integrations are optional
dependencies - add whichever your host actually renders with.

## Observing a run

The panes are pure folds over a trace message list, so the whole package is
usable without Livebook, without Phoenix, and without a display. This is a card
authorization that settles - the chart, a subscriber, one event, and the
rendered panes.

```elixir
xml = """
<?xml version="1.0" encoding="UTF-8"?>
<scxml xmlns="http://www.w3.org/2005/07/scxml" initial="pending" version="1.0">
    <datamodel>
        <data id="amount_cents" expr="1999"/>
        <data id="captured_cents" expr="0"/>
    </datamodel>
    <state id="pending">
        <transition event="authorize.approved" target="authorized"/>
        <transition event="authorize.declined" target="declined"/>
    </state>
    <state id="authorized">
        <transition event="capture.settled" target="captured">
            <assign location="captured_cents" expr="amount_cents"/>
        </transition>
    </state>
    <final id="captured"/>
    <final id="declined"/>
</scxml>
"""

{:ok, machine} = Statifier.compile(xml)

# Start the subscriber first and hand it to the session as a subscriber, so it
# sees the initialize burst. `Session.start_link/2` initializes to quiescence
# before it returns, so anything that attaches afterwards has already missed it.
{:ok, sub} = StatifierUI.Trace.Subscriber.start_link(machine: machine, source: xml)

{:ok, session} =
  Statifier.Session.start_link(machine,
    trace: true,
    subscribers: [sub],
    session_id: "sess_card_demo"
  )

:ok = StatifierUI.Trace.Subscriber.attach(sub, session, subscribe: false)

# `send_event/2` is a cast: it enqueues, and the run happens in the session.
:ok = Statifier.Session.send_event(session, "authorize.approved")
Process.sleep(50)

messages = StatifierUI.Trace.Subscriber.messages(sub)
```

`messages` is the whole run so far. Every pane is a function of it.

`StatifierUI.Inspector.diagram(machine, messages)` renders the configuration as
Mermaid, with the active state classed `active`:

```
stateDiagram-v2
    state "pending" as s1
    state "authorized" as s2
    state "captured (final)" as s3
    state "declined (final)" as s4
    [*] --> s1
    s1 --> s2 : authorize.approved
    s1 --> s4 : authorize.declined
    s2 --> s3 : capture.settled
    classDef active fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e
    class s2 active
```

`StatifierUI.Inspector.event_log(messages)` renders the run as collapsible
Markdown, one section per macrostep, newest open:

```markdown
# Event log: sess_card_demo

<details>
<summary>Macrostep 1: initialize, 2 rounds, quiescent at <scxml>, pending</summary>

| round | event | selected | exited | entered |
| --- | --- | --- | --- | --- |
| 0 | - | - |  | <scxml>, pending |
| 1 | (eventless) | none |  |  |
</details>

<details open>
<summary>Macrostep 2: authorize.approved, 2 rounds, quiescent at <scxml>, authorized</summary>

| round | event | selected | exited | entered |
| --- | --- | --- | --- | --- |
| 0 | authorize.approved | authorize.approved: pending -> authorized | pending | authorized |
| 1 | (eventless) | none |  |  |
- authorize.approved: pending -> authorized: 
</details>
```

The trailing bullet is the transition's executable content, listed with the
source location of each element. This transition carries none; the one on
`capture.settled` would list its `<assign>`.

`StatifierUI.Inspector.datamodel(messages)` renders the live datamodel with a
marker on what the last macrostep changed, and
`StatifierUI.Inspector.status(StatifierUI.Trace.Subscriber.stats(sub))` renders
the one-line session header. Sending `capture.settled` next moves the highlight
to `captured` and marks `captured_cents` as changed.

To hand the same stream to a UI written in something other than Elixir,
`StatifierUI.Trace.Json.encode_lines(messages)` emits it as JSON Lines in the
language-neutral [trace wire format](docs/wire-format.md).

## Checking expressions

Datasets and expressions are the other half of the fixtures contract
(ADR-0006): named example datamodels, named predicator expressions, and the
expected result of each pairing. Here they cover a signup wizard's A/B
completion check.

```elixir
{:ok, fixtures} =
  StatifierUI.Fixtures.new(
    datasets: %{
      "variant-a-early" => %{"signup" => %{"steps_completed" => 1, "variant" => "A"}},
      "variant-b-complete" => %{"signup" => %{"steps_completed" => 4, "variant" => "B"}}
    },
    expressions: %{
      "is-complete-variant-b" => %{
        "source" => "signup.steps_completed >= 3 and signup.variant == 'B'",
        "expect" => %{"variant-a-early" => false, "variant-b-complete" => true}
      }
    }
  )

fixtures
|> StatifierUI.TruthTable.build()
|> StatifierUI.TruthTable.Markdown.render()
```

renders every expression against every dataset:

```markdown
# Truth table

**true**, false, and _undefined_ are three separate results. _undefined_ means the expression's inputs were absent, not that it evaluated to false.

| dataset | is-complete-variant-b |
| --- | --- |
| variant-a-early | false |
| variant-b-complete | **true** |

Expressions:
- **is-complete-variant-b**: `signup.steps_completed >= 3 and signup.variant == 'B'`
```

The `"expect"` entries are executable, not documentation:
`StatifierUI.Fixtures.Expectations.check(fixtures)` returns `:ok` when the
table matches and `{:error, results}` naming each disagreement, so a host can
run its own fixtures as part of its test suite. See
[fixture bundles](docs/fixture-bundles.md) for the per-fragment layout and the
sidecar file format.

## The Livebook inspector

`StatifierUI.Kino.inspect/3` composes the four panes above - configuration
diagram, datamodel explorer, event injection, event log - into one live widget
over a running session:

```elixir
{:ok, session} = Statifier.Session.start_link(machine, trace: true, record: true)
StatifierUI.Kino.inspect(session, fixtures, source: xml)
```

`record: true` is what lets the widget catch up on everything that happened
before the cell was evaluated (statifier ADR-0049); without it the panes are
labeled **Live-only** rather than presenting a partial stream as whole.

A scrubber above the diagram - **|< First**, **< Prev**, **Next >**, **Live** -
moves the diagram from the live tip to any macrostep in the event log and back.
Selecting a macrostep draws the configuration that macrostep settled in, opens
its entry in the log and marks it *shown in the diagram*, and prints a line
saying which point is on screen. Nothing is recomputed to do it: every
configuration shown was stamped by the engine on a `trace.macrostep_stable`,
and a caught-up stream got there through replay, which re-drives the core
rather than rewinding a live session (statifier ADR-0034). The decisions are
`StatifierUI.Inspector`'s - `active_configuration/2`, `points/1`, `step/3`,
`selection_note/2` - so a LiveView or other host gets the same behaviour
without Kino.

[`notebooks/inspector.livemd`](https://github.com/riddler/statifier-ui/blob/main/notebooks/inspector.livemd)
walks the whole widget end to end and doubles as its manual acceptance test.

## What is in the package

| Module | Renders |
|---|---|
| `StatifierUI.Diagram` | Mermaid `stateDiagram-v2` source for a machine and a configuration |
| `StatifierUI.EventLog` | the run as macrosteps and rounds, with the transitions each selected |
| `StatifierUI.DatamodelExplorer` | the datamodel, live from a trace or authoring-time from a chart |
| `StatifierUI.EventInjection` | the palette of example events a fixture set defines |
| `StatifierUI.TruthTable` | expressions evaluated across datasets |
| `StatifierUI.Fixtures` | the example-data contract: scenarios, events, datasets, expressions |
| `StatifierUI.Trace.Subscriber` | a session's effect stream, normalized and buffered |
| `StatifierUI.Inspector` | the four panes composed, as strings |
| `StatifierUI.Kino` | the same, as Livebook widgets (optional `:kino`) |

Everything except `StatifierUI.Kino` is pure and dependency-free: build the
strings, render them wherever you like.

## Documentation

Published guides on [hexdocs](https://hexdocs.pm/statifier_ui/):

- [Architecture](docs/architecture.md) - the layers of statifier-ui, what
  each piece is for, and the boundary with the engine it visualizes.
- [Fixture bundles](docs/fixture-bundles.md) - the per-fragment fixture
  layout, the sidecar file format, and how bundles are discovered.
- [Trace wire format](docs/wire-format.md) - the normative specification of
  the language-neutral JSON trace stream a UI consumes.

## Development

```bash
mise install     # provision erlang + elixir
mix deps.get
mix quality      # the full gate: format, compile, credo, dialyzer, docs, tests
```

`mix quality --profile loop` is the faster inner-loop variant - it skips
dialyzer and coverage and runs only the tests covering changed code.

CI runs the same gate on every push and pull request. See `.quality.exs`.

## License

MIT. See
[LICENSE](https://github.com/riddler/statifier-ui/blob/main/LICENSE).
