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

## Status

Early. The first milestone is the Livebook inspector:
`StatifierUI.Kino.inspect/3` over a running `Statifier.Session` -
[`notebooks/inspector.livemd`](https://github.com/riddler/statifier-ui/blob/main/notebooks/inspector.livemd)
walks it end to end.

## Documentation

Published guides on [hexdocs](https://hexdocs.pm/statifier_ui/):

- [Architecture](docs/architecture.md) - the layers of statifier-ui, what
  each piece is for, and the boundary with the engine it visualizes.
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
