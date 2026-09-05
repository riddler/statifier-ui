### Fixed

- A `trace.event_dequeued` for an `error.execution` or `error.communication`
  event now reaches a consumer. The engine puts an unconstrained reason term
  in those events' data, which is not a value, so the whole message used to
  fail to normalize and be dropped - the inspector showed a run in which the
  failure simply was not there.

### Added

- The wire `error` object gains a `class` discriminator (`"expression"` or
  `"reason"`), and on the reason arm a `kind` token derived from the term's
  tag, a human-readable `reason` string, and a `content_path` naming the
  enclosing `<if>` or `<foreach>` when the failure was raised inside one.
  Adding fields is not a format version bump, so the format version stays
  `1`. See ADR-0014 and `docs/wire-format.md`.

### Changed

- `error.reason` is redacted under every projection profile, beside
  `session.terminated`'s `reason`: it is `inspect/1` of a whole engine term
  and can embed a datamodel value verbatim. `class`, `kind`, and
  `content_path` are never projected.
