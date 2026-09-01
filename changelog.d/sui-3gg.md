### Added

- The Livebook inspector's diagram can be moved to any macrostep in the
  event log and back, pairing the two panes into a comprehension surface
  for one point in a run rather than only the live tip (sui-3gg). Four
  buttons above the diagram - **|< First**, **< Prev**, **Next >**,
  **Live** - drive it; the selected macrostep's entry in the log is
  opened and marked `- shown in the diagram`, and a note above the
  diagram names the point on screen.
- `StatifierUI.EventLog.configuration_at/2` returns the configuration in
  force at a macrostep, distinguishing `{:quiescent, configuration}` from
  `{:carried, from, configuration}` (the macrostep never settled, so an
  earlier one's configuration is shown) and `:before_first`. A carried
  configuration is never presented as a measured one - which is what
  surfaces `sui-dc7`'s halting macrostep out loud instead of silently.
- `StatifierUI.Inspector` gained the `:selection` option (`:live` or
  `{:macrostep, n}`), plus `points/1`, `step/3`, `resolution/2`, and
  `selection_note/2`. Every decision the scrubber makes lives here, so a
  LiveView or other host gets the same behaviour without Kino.
- `StatifierUI.EventLog.Markdown.render/2` gained `:selected`, which
  suffixes one macrostep's summary with `- shown in the diagram`.

Nothing here re-derives a configuration: every one it can show was
stamped by the engine on a `trace.macrostep_stable`, and a caught-up
stream got there through statifier ADR-0034 replay. Time travel is a read
of replay output as data (ADR-0002's inherited clause), so selecting a
macrostep neither touches the session nor needs anything new from the
engine.

### Changed

- `StatifierUI.Inspector.event_log/1` is now `event_log/2`, taking the
  same options as the other fold functions. The one-argument call is
  unchanged in behaviour.
