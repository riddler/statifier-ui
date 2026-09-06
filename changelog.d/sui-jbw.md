### Changed

- `StatifierUI.EventLog.Markdown.render/2` marks the selected macrostep
  `- selected` instead of `- shown in the diagram`, the same mark
  `StatifierUI.Live.event_log/1` uses, so both renderers read alike.
  `StatifierUI.Inspector.event_log/2` and the Kino inspector render the new
  mark; a host asserting on the old text updates the string.
