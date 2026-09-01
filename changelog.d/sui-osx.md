### Added

- `StatifierUI.Live` - read-only LiveView function components for a host
  application's ops views: `ops_view/1` composing `status/1`, `scrubber/1`,
  `diagram/1`, and `event_log/1` over one trace stream in wire format v1,
  live or persisted. Compiled only when the optional `:phoenix_live_view`
  dependency is present (ADR-0004); without it every component raises with
  instructions. `docs/ops-embedding.md` is the embedding guide.
- `StatifierUI.Live.State` - the pure read model a host keeps in its socket:
  `new/2` over a persisted message list, `push/2` for a live subscriber's
  fan-out (dropping any message whose `seq` is not newer than the newest one
  held, so the `add_listener` then `sync/2` overlap costs nothing),
  `sync/2` to pull a subscriber's buffer and stats in one call, and
  `scrub/2` / `select/2` over `StatifierUI.Inspector`'s selection.
- The event log renders as HTML rather than Markdown in a LiveView host, so
  clicking a macrostep entry moves the diagram to it - the link the Livebook
  pane cannot have, because a Markdown document has no click target.
- `docs/ops-embedding.md` - embedding the ops view in a host LiveView, live
  and persisted, with the styling hooks and the Mermaid client the diagram
  pane expects a host to supply.
