### Added

- `session.start`'s `states` and `transitions` identity tables now carry an
  `attribute_locations` object per row, mapping an attribute's name to that
  attribute's own value span. Key presence is the contract: an entry exists
  only for an attribute the author actually wrote, so
  `attribute_locations["type"]` being absent is how a consumer tells a
  transition that defaulted to external from one written `type="external"` -
  a question the lowered `type` value cannot answer. A consumer wanting
  hover precision on a transition's `event` or `target`, or a state's `id`
  or `initial`, now has it from `session.start` alone; reading the
  `%Statifier.Document{}` tree for it is no longer necessary. Requires a
  statifier that carries `attribute_locations` on the compiled Machine
  (statifier 9.0 and later).

### Changed

- Nothing existing moves. Every row keeps its element-level `location`
  unchanged, and `attribute_locations` is `{}` for an element that wrote no
  attributes, for the synthesized initial transition, and for a Machine
  compiled by an older engine - in each case a consumer falls back to
  `location`, the granularity this format offered before. The format
  version stays `1`; the addition is additive per ADR-0005.
- `cond_location` is retained rather than superseded. It falls back to the
  transition's own `location` when a guard was written without a recorded
  span, where `attribute_locations` simply omits the key, so the two answer
  different questions. Prefer `attribute_locations["cond"]` for new work.
- `contents` and `data` rows are unchanged and carry no
  `attribute_locations`.
