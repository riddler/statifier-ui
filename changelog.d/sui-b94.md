### Changed

- The trace wire format reserves `otel` as an envelope key: an optional
  object carrying the W3C Trace Context `trace_id` and `span_id` of the
  OpenTelemetry span covering a message's macrostep, legal on `trace.*` and
  `effect.*` messages only (ADR-0013). No producer emits it yet, the format
  version stays `1`, and a stream with no correlation context attached is
  byte-unchanged - but a payload may no longer use `otel` as a key.
