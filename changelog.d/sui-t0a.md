### Added

- `StatifierUI.TruthTable` evaluates a bundle's expressions across its
  datasets and returns the ADR-0006 result matrix, one cell per
  `(expression, dataset)` pair. A cell's verdict is `:satisfied`,
  `:unsatisfied`, `:undefined`, `:value`, `:error`, or `:missing_dataset` -
  deliberately not `true` / `false`, so predicator's three-valued
  `undefined` cannot be collapsed into false by Elixir truthiness.
- `StatifierUI.TruthTable.Markdown` renders that matrix as Markdown, with
  datasets down the rows and expressions across the columns by default, or
  transposed with `orientation: :expressions_as_rows`. Every cell spells its
  value out as a word and adds emphasis on top, so the three truth values
  stay distinct in plain text.
- `StatifierUI.Kino.truth_table/2` wraps the rendered matrix in a
  `Kino.Markdown` widget for a Livebook cell. It needs no session and no
  Phoenix; without the optional `:kino` dependency the stub points at the
  pure renderer instead.
