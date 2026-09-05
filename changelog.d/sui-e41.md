### Added

- `trace.conds_evaluated`, a new trace message carrying a selection round's
  guard outcomes: one entry per evaluation, with the guarded transition's
  `t_index`, an `outcome` of `"enabled"`, `"disabled"` or `"error"`, and, on
  `"error"`, the same `reason` error object an `error.execution` event
  carries. Entries are in the engine's walk order, so the *n*th `"error"`
  entry pairs with the *n*th `error.execution` the round raised. A guarded
  chart's stream can now say why a branch fired or failed instead of showing
  two identical timelines (ADR-0018).

  Under a projected stream the entry's `reason.reason` is redacted
  unconditionally and its `reason.expression` follows `allow_source`, exactly
  as on an event's error object; `t_index` and `outcome` are never projected.

  Before this, the producer skipped the engine's guard-evaluation effect
  rather than mapping it, so the outcomes reached no consumer at all.

### Changed

- The wire vocabulary is 25 types, up from 24. The format **version stays
  `1`**: a new `type` is additive, and ADR-0005's must-ignore-unknown rule
  means a consumer that has never heard of `trace.conds_evaluated` skips it.
  The conformance clause's MUST list is unchanged - it names the nine
  Appendix D phase-boundary `trace.*` types, and this one is a seam inside
  selection, so it joins the MAY half beside the `effect.*` families.

  Nothing breaks at runtime, but a consumer that *asserts* the vocabulary
  size rather than reading it fails until it is re-pinned: an embedder
  pinning 24 types today moves to 25 when it takes `~> 0.7`.
