### Fixed

- `StatifierUI.Trace.Normalizer.normalize/2` no longer refuses statifier
  2.5's `Statifier.Effect.Trace.CondsEvaluated`, so a chart with a guarded
  transition can be replayed through `StatifierUI.Trace.Replay.from_events/4`
  instead of failing closed on its first branch.

### Changed

- Raises the `statifier` floor to `~> 2.5`.
- `StatifierUI.Trace.Normalizer.normalize/2` has a third return, `:skip`, for
  an engine trace effect the v1 wire format deliberately does not carry. A
  caller matching only `{:ok, _}` and `{:error, _}` needs a clause for it;
  neither a message nor a `seq` is produced.
