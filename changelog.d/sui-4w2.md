### Added

- `StatifierUI.Trace.DeepLink` builds a URL into a host's APM backend from
  the wire format's `otel` correlation key (ADR-0013), the consuming half of
  the producer shipped with `sui-6e4`. The URL template is host
  configuration - `"https://apm.example.com/trace/{trace_id}?span={span_id}"`,
  with `{trace_id}`, `{span_id}`, `{session}`, and `{macrostep}` available
  and substituted values percent-encoded - because only the host knows which
  backend its spans went to.
- `StatifierUI.EventLog.DeepLink`, the rendering seam over an
  `StatifierUI.EventLog.t()`: `from_opts/1` reads a renderer's `:deep_link`
  option, `for_macrostep/2` and `for_log/2` answer per macrostep, and
  `markdown/3` renders the inline Markdown link.
- `StatifierUI.EventLog.Markdown.render/2` and every `StatifierUI.Inspector`
  fold take the same `:deep_link` option. A macrostep whose messages carry
  `otel` gets a `[trace](...)` link at the end of its event-log summary
  line, and `Inspector.selection_note/2` gains an `[open trace](...)` link
  for the macrostep on screen.
- `docs/telemetry.md` gains a section on the consuming end of the `otel`
  key.

A malformed template raises where the option is read, so a typo cannot
quietly produce URLs that resolve nowhere. A step with no correlation - no
template configured, no `otel` key on the stream, or ids that are not W3C
Trace Context hex - renders no link and no error, which is the normal case
for every stream captured with no bridge attached, and every pane then
renders exactly what it rendered before. This package still calls
no OpenTelemetry API and gains no dependency.
