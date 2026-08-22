### Added

- `StatifierUI.EventInjection.build/1` turns an `ADR-0003` fixture bundle
  (or `nil`) into the event-injection pane model: a sorted palette of
  editable event buttons via `StatifierUI.EventInjection.Palette`, a
  `free_form_only?` flag for the fixture-less degraded mode, and
  `send/2`/`send_draft/3` to deliver a `StatifierUI.EventInjection.Draft`
  through `Statifier.Session.send_event/2` - the ordinary recordable input
  path, per statifier ADR-0029.
