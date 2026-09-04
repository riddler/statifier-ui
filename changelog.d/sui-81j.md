### Added

- `StatifierUI.Live.ExpressionInput` renders a **picklist mode**: a source
  string inside the picklist-renderable subset draws one row of dropdowns per
  clause - field, operator, value - with a connective toggle, an add-clause
  button and a remove-clause button per row. A valid expression outside the
  subset, and source that does not parse, render the text input as before.
  The component never refuses a source string and never rewrites one.
- Source that does not parse now renders the text input alongside the parse
  error's message and position, stamped as `data-error-position`, rather than
  falling back silently.
- A switch to text mode is always offered; the switch to picklists appears
  only while the current text is inside the subset. `:mode` (`:auto`, `:text`,
  `:picklist`) sets which mode renders first, and `:value_candidates` supplies
  the values a host offers per clause path.
- `StatifierUIExpressionPicklist`, a second hook, shipped as source alongside
  the completion popup and exported from `StatifierUIHooks`.
  `StatifierUI.Live.ExpressionInput.picklist_hook_name/0` names it, and
  `display_label/1` is the one place an operator label is cased for display.
  A host that registers no hook gets the text field alone.
- `StatifierUI.Expression.source/2` writes a source string back from the rows
  `simple/2` returned, `value_source/2` spells one clause value on its own,
  and `segments/1` reads a declared path into the structural form a clause
  carries. Together they are the write half of the same round trip through
  `Predicator.Simple`, which is what keeps the source text the single
  representation: every picklist option's value is a complete expression the
  writer produced, and no quoting, escaping, list punctuation or operator
  spelling is repeated in JavaScript.
