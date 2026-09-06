### Added

- `StatifierUI.Live.ExpressionInput.expression_input/1` takes a `:path_types`
  assign, `%{path => kind | {:list, kind} | {:one_of, values}}`, which decides a
  clause's operator list and value control from the kind the host declares
  rather than from the literal in the source.
- `StatifierUI.Expression.simple/2` takes a `:path_types` option, and each row
  it returns carries `:declared_kind`, `:control_kind` and `:advisories`.
- `StatifierUI.Expression.relative_date_candidates/0` returns the relative
  dates a date-declared path offers.
