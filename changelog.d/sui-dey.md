### Added

- `StatifierUI.Expression.simple/2` classifies a source string against the
  picklist-renderable subset, returning `{:ok, rows, connective}` for source a
  row of dropdowns can draw, `:outside` for a valid expression it cannot, and
  `{:error, error}` for source that does not parse. Each row carries the field
  path, the operator, the value, and the value's kind in both structural and
  source form.
- `StatifierUI.Expression.operators/1` returns the operators a picklist offers
  beside a value of a given kind, and
  `StatifierUI.Expression.value_candidates/2` normalizes the values a host
  declares for a path.
- `StatifierUI.Expression.simple_available?/0` reports whether the resolved
  predicator exposes `Predicator.Simple`. A host on an older predicator gets
  `:outside` for every source string rather than an error.
