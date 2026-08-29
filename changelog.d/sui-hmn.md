### Added

- `StatifierUI.Trace.Projection` projects a trace stream down to structure,
  transitions, outcomes and ordering, replacing datamodel and payload values
  with the reserved `{"$redacted": true}` sentinel (ADR-0012). Build a
  profile with `profile/2` and pass it to
  `StatifierUI.Trace.Subscriber.start_link/1` as `:projection`; every message
  is projected before it is buffered or fanned out, so a projected stream can
  be rendered, encoded or persisted without any of those having held a value.
- A profile allows values back by path prefix (`allow_paths`, matching
  `effect.datamodel_change`'s `location_path` encoding) or by naming an
  unlocated position (`allow_positions`). A prefix longer than a write's own
  path descends into the written value, so an allowed leaf passes while its
  withheld siblings are redacted. `allow_source: false` additionally redacts
  `session.start`'s chart source.
- `session.start` carries a `projection` header naming the mode and profile
  whenever the stream is projected, so a projected capture is always
  distinguishable from a full one.
- `StatifierUI.Value` decodes `{"$redacted": true}` to the new `:redacted`
  atom and encodes it back; `StatifierUI.Shape` gains a matching `:redacted`
  shape that renders as `redacted`.

### Fixed

- `StatifierUI.EventLog.Markdown` no longer raises `Protocol.UndefinedError`
  when a `session.terminated` message carries a non-string `reason`. It and
  the datamodel explorer now render a withheld value as `(redacted)` rather
  than as unbound or as a literal one-key map.

### Changed

- The wire format's reserved one-key `$`-prefixed shape admits `$redacted`,
  making five reserved forms rather than four. The format version stays `1`:
  no existing stream changes, and full fidelity remains the default and is
  byte-unchanged.
