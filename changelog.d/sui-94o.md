### Changed

- `StatifierUI.Expression.operators/1` reads per-value-kind eligibility from
  `Predicator.Simple.operators/1` instead of a table kept here, so the
  operators offered beside a value are the ones the grammar admits for that
  kind. Every scalar kind now also offers `===`, `!==` and `CONTAINS`, and a
  string offers the ordered comparisons.
- Each entry `StatifierUI.Expression.operators/1` returns gains `:lexeme`, the
  source spelling the expression will carry, and its `:label` is now the
  grammar's display phrase (`"is at least"` for `">="`) rather than the
  spelling. Read `:lexeme` where you were reading `:label` to build source
  text; nothing stored changes, since a row is still written back through
  `Predicator.Simple.to_source/1`.
- `StatifierUI.Live.ExpressionInput`'s operator dropdown shows those phrases.
  The `value` attribute on every option is unchanged: it is still the writer's
  own untouched output.

### Added

- `StatifierUI.Expression`'s `t:value_kind/0` gains `:float`, so a float-valued
  clause is offered the operators a number is offered once the resolved
  predicator admits float literals to the subset.
