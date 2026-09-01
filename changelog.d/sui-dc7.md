### Fixed

- The configuration pane now shows a halted chart's final configuration
  (sui-dc7). A run that ends by entering a top-level `<final>` never
  reaches quiescence in its last macrostep, so it emits no
  `trace.macrostep_stable` for it; `StatifierUI.Inspector` read only that
  message type and therefore kept highlighting the state the chart had
  *left*, while the datamodel pane showed the assignment that moved it
  out. Both stamping messages are read now, newest wins.

  The wire format is what settles that `trace.done` may be read this way:
  its `configuration` field is defined as "the full configuration as it
  stood at exit, a genuine set, sorted ascending" - the same shape and the
  same authority as a `trace.macrostep_stable` payload. Nothing here
  re-derives an exit configuration from the exit sets that precede
  `trace.done`; the format version is unchanged and the engine is
  untouched.

### Added

- `StatifierUI.EventLog.configuration_at/2` gained a fourth outcome,
  `{:final, configuration}` - macrostep `n` halted the run, and this is
  the configuration it exited in. It is kept distinct from
  `{:quiescent, configuration}` for the same reason `{:carried, ...}` is:
  a configuration the chart *exited* in is not one it *settled* in, and
  `StatifierUI.Inspector.selection_note/2` words the two differently
  ("at the final configuration the run halted in").
- `StatifierUI.EventLog.Macrostep` gained `final_configuration` and
  `stamped/1`, and `StatifierUI.Inspector.points/1` gained `final?`
  beside `quiescent?` - a halting macrostep is not quiescent, and a
  scrubber saying so is not the same as one saying it has nothing to
  show.
