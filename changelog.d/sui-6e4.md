### Added

- `StatifierUI.Trace.Subscriber` accepts an `:otel_context` resolver -
  `(session_id, macrostep -> {:ok, %{trace_id: binary, span_id: binary}} |
  :none)` - and stamps the wire format's `otel` envelope key from it on
  `trace.*` and `effect.*` messages, the producer half of ADR-0013. The ids
  come from the host; this package still calls no OpenTelemetry API and
  gains no dependency. A resolver answering `:none`, returning a malformed
  or half pair, or raising leaves the key absent rather than failing the
  trace, and a projected stream carries the key unchanged.
- `StatifierUI.Trace.Otel`, the pure module deciding which messages may
  carry `otel` and whether an answer is well-formed W3C Trace Context hex.
- `docs/telemetry.md` is published with the other guides on hexdocs.

Without an `:otel_context` resolver nothing changes: the key is absent
everywhere and golden traces stay byte-comparable.
