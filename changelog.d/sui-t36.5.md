### Added

- `StatifierUI.EventLog.build/1` folds a trace message stream into a log
  grouped by `(macrostep, round)`, ordered by the producer's stamps rather
  than arrival, and `StatifierUI.EventLog.Markdown.render/2` renders it as
  collapsible Markdown for `Kino.Markdown`, with wire-format indexes
  resolved to state and transition names by
  `StatifierUI.EventLog.Labels`.
