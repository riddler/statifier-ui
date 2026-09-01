### Fixed

- An event whose data is an expression-evaluation failure no longer fails to
  normalize. Previously `StatifierUI.Value.encode/1` rejected the failure
  payload and the whole trace message was dropped, so the diagnostic a
  consumer most needs never reached the wire.

### Added

- Such an event now carries an `error` object naming the failure kind, the
  expression, the span within it, and the absolute, pre-resolved document
  location of the failing subexpression - so a consumer underlines it
  directly with no span composition of its own. `docs/wire-format.md` now
  states the end-exclusive convention for spans and locations explicitly.
