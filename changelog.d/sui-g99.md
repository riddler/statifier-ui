### Changed

- `session.start`'s `data` rows omit `value_location` when the `<data>`
  element wrote no value, instead of falling back to the element's own span.
  A consumer that compared the two spans before slicing `source` can now test
  for the key's presence instead; one that sliced without comparing stops
  getting the whole element's text presented as a value. The wire format
  version stays 1.
