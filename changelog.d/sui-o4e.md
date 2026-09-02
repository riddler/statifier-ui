### Fixed

- `docs/wire-format.md` no longer says `session.start`'s `data.value_location`
  is present only when the compiler recorded a value span. A conformant
  producer always emits it, falling back to the element's own span, exactly as
  the surrounding prose already said - so a consumer need not handle its
  absence.
