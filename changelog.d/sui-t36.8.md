### Added

- `StatifierUI.Kino.inspect/3` assembles the Livebook inspector: the
  configuration diagram, datamodel explorer, event injection, and event
  log panes composed over one shared subscriber, live-updating, detaching
  cleanly on cell re-evaluation. Compiled only when the optional `:kino`
  dependency is present.
- `StatifierUI.Trace.Subscriber.attach/3` accepts `catch_up: true`: on a
  session started with `record: true` the missed prefix is replayed into
  the buffer atomically with the subscription (statifier ADR-0049); an
  unrecorded session falls back to live delivery with a `:not_recorded`
  diagnostic the inspector surfaces as "Live-only".
- `StatifierUI.Inspector` - the pure pane-assembly fold the Kino shell
  renders, usable by any other frontend.
- `notebooks/inspector.livemd` - the demo notebook, doubling as the
  milestone's manual acceptance test.
