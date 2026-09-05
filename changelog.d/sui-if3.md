### Added

- `StatifierUI.Trace.Replay.recording/3`, which builds the
  `Statifier.Session.Recording` a host's stored inputs describe and returns
  it. It is the fold `from_events/4` already ran to reach its own recording,
  now reachable on its own - for `Statifier.Replay.run/1` directly, for
  `Statifier.Session.Recording.to_binary/1`, or to compare against a
  recording you already hold. An unrecognized entry shape is
  `{:error, {:unknown_entry, entry}}`, the same fail-closed answer
  `from_events/4` gives; `:trace` and `:session_id` are not checked here,
  because they are requirements of the message stream rather than of the
  recording.

  `docs/ops-embedding.md`'s "From a persisted event log" now carries the
  table saying which stored row becomes which of the six entry shapes, and
  states the rule a fired delayed send turns on: it is
  `{:timer, send_id, event, routes}`, never `{:event, event, routes}`,
  because only the timer shape draws the pending-timer credit the `send_id`
  matches. Naming a firing as an event costs the
  `{:unscheduled_timer_firing, send_id}` check and leaves the credit
  outstanding for a later cancel to move into the raced pool.
