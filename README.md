# StatifierUI

[![CI](https://github.com/riddler/statifier-ui/actions/workflows/ci.yml/badge.svg)](https://github.com/riddler/statifier-ui/actions/workflows/ci.yml)
[![Hex.pm Version](https://img.shields.io/hexpm/v/statifier_ui.svg)](https://hex.pm/packages/statifier_ui)
[![Hex Downloads](https://img.shields.io/hexpm/dt/statifier_ui.svg)](https://hex.pm/packages/statifier_ui)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/statifier_ui/)
[![License](https://img.shields.io/hexpm/l/statifier_ui.svg)](https://github.com/riddler/statifier-ui/blob/main/LICENSE)

Viewers and inspectors for [statifier](https://github.com/riddler/statifier-ex)
executions: a Livebook inspector, LiveView components, and an expression field
for [predicator](https://github.com/riddler/predicator-ex) expressions. Every
pane reads one trace stream, written down as a language-neutral wire format, so
a UI in another language can read the same stream.

## Why a UI over the trace

An execution in a session is a process holding a configuration and a
datamodel, and without a viewer the way to learn why it stands where it does is
to read logs or add prints to the host. Statifier already emits a trace effect
at every phase boundary of its algorithm, stamped with its macrostep and round,
with source locations kept on states, transitions and expressions. This
package folds that stream into panes - the active configuration as a diagram,
an event log by macrostep and round, the datamodel with what the last
macrostep changed - and nothing in the engine changes to support it. Each
pane is a pure function of the message list, so the same view renders in
Livebook, in a LiveView page, or as a string in a test.

## Install

```elixir
def deps do
  [
    {:statifier_ui, "~> 0.10.0"}
  ]
end
```

The `:kino` (Livebook) and `:phoenix_live_view` integrations are optional
dependencies: add whichever your host renders with.

## Basic usage

A library loan, renewed once and then due, observed by a subscriber and
rendered as panes:

```elixir
xml = """
<scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
  <datamodel>
    <data id="renewals" expr="0"/>
  </datamodel>
  <state id="on_loan">
    <transition event="loan.renew" target="on_loan">
      <assign location="renewals" expr="renewals + 1"/>
    </transition>
    <transition event="loan.due" target="due"/>
  </state>
  <state id="due">
    <transition event="loan.returned" target="returned"/>
    <transition event="loan.lost" target="lost"/>
  </state>
  <final id="returned"/>
  <final id="lost"/>
</scxml>
"""

{:ok, chart} = Statifier.compile(xml)

# Hand the subscriber to the session at start, so it sees the initialize burst.
{:ok, sub} = StatifierUI.Trace.Subscriber.start_link(machine: chart, source: xml)

{:ok, session} =
  Statifier.Session.start_link(chart, trace: true, subscribers: [sub], session_id: "loan_42")

:ok = StatifierUI.Trace.Subscriber.attach(sub, session, subscribe: false)

# send_event/2 is a cast; the snapshot call returns once both macrosteps are done.
:ok = Statifier.Session.send_event(session, "loan.renew")
:ok = Statifier.Session.send_event(session, "loan.due")
_ = Statifier.Session.snapshot(session)
messages = StatifierUI.Trace.Subscriber.messages(sub)

StatifierUI.Inspector.diagram(chart, messages)   # Mermaid, with "due" classed active
StatifierUI.Inspector.event_log(messages)        # Markdown, one section per macrostep
StatifierUI.Inspector.datamodel(messages)        # Markdown, "renewals" at 1
```

`messages` is the whole execution so far, and every pane is a function of it.
`StatifierUI.Trace.Json.encode_lines(messages)` writes the same stream as JSON
Lines in the trace wire format, for a UI written in something other than
Elixir.

## Documentation

- Learn
  - [Basic usage](https://hexdocs.pm/statifier_ui/readme.html#basic-usage) -
    an execution observed and its panes rendered, without Livebook or Phoenix
  - [The inspector notebook](https://github.com/riddler/statifier-ui/blob/main/notebooks/inspector.livemd) -
    the Livebook widget over a live session, end to end
- Do
  - [How to embed the ops view in a host LiveView](docs/ops-embedding.md) -
    the hooks' asset pipeline, the classes and data attributes to theme, and
    rendering your own surfaces off the wire format
  - [How to observe an execution from a LiveView host](docs/guides/observe-an-execution.md) -
    one execution's current state on your own page, kept current as it
    moves
  - [Add an expression field with completion](https://hexdocs.pm/statifier_ui/StatifierUI.Live.ExpressionInput.html) -
    the field, its declared path kinds and its hook; the API reference until a
    guide page exists
  - [Open the inspector in Livebook](https://hexdocs.pm/statifier_ui/StatifierUI.Kino.html) -
    the widget, its scrubber and why it wants `record: true`; the API reference
    until a guide page exists
  - [Check fixture expectations in your test suite](https://hexdocs.pm/statifier_ui/StatifierUI.Fixtures.Expectations.html) -
    each stated `expect` evaluated against its dataset; the API reference until
    a guide page exists
- Look up
  - [API reference](https://hexdocs.pm/statifier_ui/api-reference.html) -
    every public module and function
  - [The trace wire format](docs/wire-format.md) - the normative specification
    of the JSON trace stream a UI consumes
  - [CHANGELOG](CHANGELOG.md) - what changed in each release, with every
    breaking change marked
- Understand
  - [Architecture](docs/architecture.md) - the layers, what each piece is for,
    and the boundary with the engine it visualizes
  - [Per-fragment fixture bundles](docs/fixture-bundles.md) - how a reusable
    chart fragment carries its own executable examples
  - [Telemetry and the OTel bridge half](docs/telemetry.md) - what this
    package emits about its own work, and how a host correlates it
  - [Why the viewer speaks a wire format and not the engine](docs/explanation/why-a-wire-format.md) -
    why every pane reads a documented trace stream rather than the engine,
    what that buys and costs, and the alternatives considered
  - [The decision records](https://github.com/riddler/statifier-ui/tree/main/docs/adr) -
    why the package is built the way it is

## Compatibility

- Elixir `~> 1.18`.
- Runtime dependencies: `statifier ~> 2.5`, `predicator ~> 9.4`,
  `statifier_datamodel ~> 0.4`; optional: `kino ~> 0.14`,
  `phoenix_live_view ~> 1.0`.
- The LiveView hooks ship as JavaScript source, so a host that registers them
  needs a Node step in its asset pipeline; without the hooks every component
  still renders, without the JavaScript enhancement.
- Pre-1.0: a minor release may rename modules, callbacks, telemetry events or
  error vocabulary with no compatibility shim. Every such change is under a
  bold **Breaking** heading in the [CHANGELOG](CHANGELOG.md), and pinning to
  an exact minor (`~> X.Y.0`) is the recommended way to consume the package
  until 1.0.

## Contributing

```bash
mise install     # provision erlang + elixir
mix deps.get
mix quality      # the full gate: format, compile, credo, dialyzer, docs, tests
```

`mix quality --profile loop` is the faster inner-loop variant. CI runs the
full gate on every push and pull request; see `.quality.exs`.

## License

MIT. See
[LICENSE](https://github.com/riddler/statifier-ui/blob/main/LICENSE).
