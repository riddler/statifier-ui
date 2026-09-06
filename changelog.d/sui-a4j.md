### Added

- `StatifierUI.Diagram.render/3` takes `:active_style`, which decides how the
  active-configuration highlight is styled: `:default` (the shipped light
  palette, unchanged), `:none` (no `classDef` at all, so the host's own
  stylesheet or Mermaid theme reaches the `active` class the nodes still
  carry), or a `classDef` body as a binary. A host under a dark theme no
  longer has to post-process the Mermaid source to restyle the highlight.
- `StatifierUI.Inspector.diagram/3` accepts the same `:active_style` option,
  and `StatifierUI.Live.diagram/1` and `ops_view/1` the same `active_style`
  attribute.
