### Added

- `StatifierUI.DatamodelExplorer.build_authoring/3` and `build_live/2` build
  a read-only datamodel tree - document `<data id>` declarations, spec
  5.10.1 system variables, predicator provider functions in scope, and
  either a fixture scenario or a live session's datamodel with entries
  marked `changed?` per macrostep - and
  `StatifierUI.DatamodelExplorer.Markdown.render/2` renders it as Markdown
  for `Kino.Markdown`.
