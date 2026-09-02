### Added

- `StatifierUI.Trace.Capture` makes recording, saving, and reloading a trace
  one call each: `record/3` off a live `Statifier.Session`, `save/2` to a
  JSON Lines file, `load/1` back into a message list.
- `StatifierUI.Trace.Json.decode/1` and `decode_lines/1` read the wire format
  back into `StatifierUI.Trace.Message` structs, over the new
  `StatifierUI.Trace.Message.from_map/1`. `docs/ops-embedding.md` has cited
  `decode/1` since it was written; it now exists.
- `StatifierUI.Kino.inspect_trace/3` reopens a saved trace in the Livebook
  inspector, recompiling the chart from the SCXML the trace carries when the
  caller does not supply a machine.
- `StatifierUI.Inspector.persisted_status/1` renders the status header for a
  stream read from storage, which has no subscriber counts to report.
- `docs/wire-format.md` specifies JSON Lines as the file framing and states
  the v1 round-trip law: decoding and re-encoding a conformant stream
  reproduces its bytes.
