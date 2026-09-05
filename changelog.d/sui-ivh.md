### Fixed

- A picklist control now shows the choice that was just made. LiveView skips
  patching a `<select>` that has focus when the option list is unchanged, so
  after an operator, field or connective edit the control kept displaying the
  previous selection until the field was re-rendered from scratch; the hook now
  restores it from the source string the server rendered.
