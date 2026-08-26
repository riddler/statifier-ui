### Added

- `StatifierUI.Fixtures` gains `datasets` and `expressions` fields (ADR-0006):
  named example datamodels for evaluating expressions against, and named
  free-standing predicator expressions carrying an `expect` map keyed by
  dataset name.
- `StatifierUI.Fixtures.Source` gains optional `datasets/0` and
  `expressions/0` callbacks so a host can supply the two new maps from
  Elixir alongside `scenarios/0` and `example_events/0`.
- `StatifierUI.Fixtures.Lint` reports an expression matching no compiled
  guard and an `expect` key naming no dataset, both as warnings.
- `StatifierUI.Fixtures.Expectations` runs every `expect` entry against its
  named dataset and reports whether the stated value held, for wiring into a
  host's own test suite.
- Depends directly on `predicator` (`~> 9.0`) rather than only transitively
  through `statifier`.
