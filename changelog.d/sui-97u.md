### Added

- `StatifierUI.Trace.Replay.from_events/4` produces the v1 trace wire format
  from a persisted session event log, with no live `Statifier.Session`, no
  process, and no clock - the same message stream
  `StatifierUI.Trace.Subscriber` produces from a live run, `session.terminated`
  excepted. A recording made without `trace: true` is refused rather than
  replayed into a silently `trace.*`-free stream. See ADR-0017.
