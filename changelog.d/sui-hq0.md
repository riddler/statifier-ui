### Added

- `StatifierUI.Live.State.configuration_ids/1` and
  `StatifierUI.Inspector.active_configuration_ids/2`: the configuration the
  current selection implies, as the chart's own state ids rather than the wire
  format's document-order indexes, resolved through the stream's own
  `session.start` manifest. A host drawing its own diagram no longer has to
  parse that manifest. A stream carrying none - the late-attach case - answers
  `{:error, :no_manifest}`; the index reads are unchanged there.
- `StatifierUI.Inspector.active_invokes/2`: the invocations live at that same
  point, as `{state_id, invoke_type | nil}`, folded from the `effect.invoke`
  and `effect.cancel_invoke` the engine already stamps.
