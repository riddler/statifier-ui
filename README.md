# StatifierUI

UI components for authoring, observing, inspecting, and debugging
[statifier](https://github.com/riddler/statifier-ex) statecharts and
[predicator](https://github.com/riddler/predicator) expressions.

Debug-first and text-first: SCXML is the source of truth, and the visualization
reads it. See
[`docs/research/260816-sui-kua-gui-research-and-direction.md`](docs/research/260816-sui-kua-gui-research-and-direction.md)
for how that direction was reached, and [`docs/adr/`](docs/adr/) for the
decisions themselves.

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
[`notebooks/inspector.livemd`](notebooks/inspector.livemd) walks it end to end.

## Development

```bash
mise install     # provision erlang + elixir
mix deps.get
mix quality      # the full gate: format, compile, credo, dialyzer, docs, tests
```

`mix quality --profile loop` is the faster inner-loop variant - it skips
dialyzer and coverage and runs only the tests covering changed code.

There is no CI; the local gate is the only gate. See `.quality.exs`.

## License

MIT. See [LICENSE](LICENSE).
