### Added

- `StatifierUI.Diagram.render/2` renders a compiled machine and an active
  configuration as Mermaid `stateDiagram-v2` source for `Kino.Mermaid`, with
  composite nesting, parallel regions, active-state highlighting, and
  cross-hierarchy transitions lifted to the composite level with a
  `[lifted: ...]` marker.
