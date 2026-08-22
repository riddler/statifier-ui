### Added

- Every `effect.*` wire message now carries the engine's `round` stamp in
  its envelope, alongside `macrostep` and `microstep` -
  `effect.budget_exhausted` already carried it, and the other nine types
  gain it. An additive field under the wire format's must-ignore rule, so
  the format version stays 1; consumers reading older recorded streams
  must still tolerate `effect.*` messages without the key.
