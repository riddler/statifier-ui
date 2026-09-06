### Added

- `StatifierUI.Kino.inspect_trace/3` is a stepper rather than a snapshot: the
  reopened trace gets the **First / Prev / Next / Live** scrubber, a **Jump
  to** select listing every macrostep by number and event, and a pane saying
  what the selected macrostep changed in the datamodel.
- `StatifierUI.Inspector.datamodel_diff/2`: what one macrostep changed in the
  datamodel, as a Markdown table.
- `StatifierUI.DatamodelExplorer.Diff.between/2` and
  `StatifierUI.DatamodelExplorer.Diff.Markdown.render/2`: the pure comparison
  behind that pane, over two datamodel explorer panes. A slot missing on one
  side is `:absent`, so `nil` and `:undefined` stay values.

### Changed

- `StatifierUI.Inspector.datamodel/2` takes the `:selection` every other fold
  there takes, so the datamodel pane can show the values as they stood at a
  selected macrostep. `datamodel/1` is unchanged.
