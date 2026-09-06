### Added

- `StatifierUI.Live.ExpressionInput.expression_input/1` takes a `:document`
  assign: a decoded datamodel document, projected through
  `StatifierDatamodel.Index.path_types/1` for the kinds `:path_types` would
  otherwise carry. A non-empty `:path_types` wins over it.
- `t:StatifierUI.Expression.declared_kind/0` admits `:number`, the tag that
  projection answers for a document's `integer` and `decimal` alike.

### Changed

- Adds a required dependency on `statifier_datamodel ~> 0.1` (see ADR-0004's
  2026-09-06 note).
- "Add clause" seeds the new row's literal from the path's declared kind - `0`
  for a number, `true` for a boolean, today for a date, the first value of a
  `{:one_of, _}`, a `CONTAINS` clause for a list - instead of always seeding an
  empty string.

### Fixed

- Adding a clause on a path declared `:number` no longer produces a row that
  immediately carries a value-kind advisory about its own seed.
