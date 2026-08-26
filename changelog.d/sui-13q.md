### Added

- `StatifierUI.Fixtures.Bundle` lets an ADR-0003/ADR-0006 fixture bundle
  travel with one reusable chart fragment instead of with a whole chart, so
  a palette entry can carry its own executable examples. A fragment supplies
  its bundle as a `StatifierUI.Fixtures` struct, an atom-keyed Elixir map, a
  string-keyed sidecar map, or a path to a `.fixtures.json` file; all four
  route through the existing validation and converge on one struct.
- `StatifierUI.Fixtures.Bundle.discover/2` loads every entry's bundle across
  a palette of modules, and `discover_dir/2` does the same for a directory
  of `<fragment>.fixtures.json` files. Neither is all-or-nothing: a fragment
  that ships no examples is reported as an absence, and one malformed bundle
  is reported against its own name while the rest still load.
- `StatifierUI.Fixtures.Bundle.Markdown` renders a fragment's "test this
  step" panel - its truth table and its expectation results together - and
  `render_discovery/2` renders a whole palette's worth. The expectations
  summary reports four counts rather than a pass or a fail, because
  `Expectations.check/2` and `Fixtures.Lint` deliberately disagree about
  whether an `expect` key naming no dataset is a failure or a warning.
- `StatifierUI.Kino.test_panel/2` and `StatifierUI.Kino.palette_panel/2`
  wrap those renderings as `Kino.Markdown` widgets. Like `truth_table/2`
  they need no session and no chart; without the optional `:kino`
  dependency the stubs point at the pure renderers instead.
- `docs/fixture-bundles.md` documents the convention and walks an embedder
  through wiring a palette entry's bundle, discovering a whole palette, and
  running every fragment's expectations in a host suite.
