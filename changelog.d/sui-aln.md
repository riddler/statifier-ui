### Fixed

- The expression field's two mode switches no longer render run-together on a
  host page with no stylesheet: their container carries an inline
  `display: inline-flex; gap: 0.5rem`, the one layout default this package
  ships.
