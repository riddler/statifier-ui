### Changed

- The predicator requirement is `~> 9.4`, up from `~> 9.2`: a host on 9.2 or
  9.3 has to move up, and gets `Predicator.Simple.value_kind/1`, which
  `StatifierUI.Expression` now asks what kind a clause value is instead of
  keeping its own table.
- `StatifierUI.Expression.simple_available?/0` also requires the resolved
  `:predicator_simple` module to export `value_kind/1`. A host that points that
  key at its own module has a fourth function to provide; every published
  predicator at the new floor already carries it.
