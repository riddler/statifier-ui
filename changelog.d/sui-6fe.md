### Fixed

- `StatifierUI.Live.ExpressionInput.expression_input/1` reads a `:debounce`
  assign from the statifier_blocks `expression_component` seam and writes it as
  `phx-debounce` onto every control it draws, so a host's debounce reaches the
  expression field instead of stopping at it.
