### Fixed

- `StatifierUI.Diagram.render/3` escapes `:` in a transition label as
  Mermaid's `#58;` entity code, so a chart whose event descriptors carry a
  prefixed name (`myapp:authorize`), a lifted edge, or a deep initial marker
  now renders instead of failing to parse.
