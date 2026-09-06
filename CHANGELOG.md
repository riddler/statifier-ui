# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries for unreleased work are not written here directly. Each issue drops a
fragment in [`changelog.d/`](changelog.d/README.md); the fragments are assembled
into a version section at release. See that README for the format and for when a
change warrants an entry at all.

## [0.9.1] 2026-09-06

A patch. `StatifierUI.Diagram.render/3` now escapes the `:` in a transition
label, so a chart whose event descriptors carry a prefixed name renders
through any Mermaid client instead of failing to parse. The expression
picklist offers every value of a `{:one_of, _}` path whose values are floats.
And the event log marks the selected macrostep in wording that stays correct
in a host composing the log with no diagram mounted. No surface changes and
no dependency changes - the trace wire format is untouched, so a consumer
taking `~> 0.9` re-pins nothing.

### Changed

- `StatifierUI.Live.event_log/1` marks the selected macrostep `- selected`
  instead of `- shown in the diagram`, so the mark reads correctly in a host
  that composes the log with no diagram mounted.

### Fixed

- `StatifierUI.Live`'s scrubber renders the note for a `{:final, n}`
  resolution, so scrubbing back from the live tip of a run that has halted
  names the configuration the run exited in instead of raising
  `FunctionClauseError` and remounting the host LiveView.
- `StatifierUI.Diagram.render/3` escapes `:` in a transition label as
  Mermaid's `#58;` entity code, so a chart whose event descriptors carry a
  prefixed name (`myapp:authorize`), a lifted edge, or a deep initial marker
  now renders instead of failing to parse.
- The expression picklist's value select offers every value of a `{:one_of,
  _}` path whose values are floats, instead of rendering only the value the
  author's own expression already carries.

## [0.9.0] 2026-09-06

A minor, and the release that gives this package a required runtime
dependency: `statifier_datamodel ~> 0.1`, which a host adding
`statifier_ui 0.9.0` pulls in. The expression editor takes a decoded datamodel
`:document` and projects its declared path types instead of needing the host to
assemble `:path_types` by hand. `StatifierUI.Live.State.configuration_ids/1`
answers the selected configuration as the chart's own state ids rather than
wire-format indexes. `StatifierUI.Kino.inspect_trace/3` is a stepper over a
persisted trace, with a pane saying what each macrostep changed in the
datamodel. And the diagram's active-configuration highlight takes an
`:active_style`, so a host under a dark theme can restyle it. The trace wire
format is untouched - version `1`, 25 types - so a consumer taking `~> 0.9`
re-pins nothing.

### Added

- `StatifierUI.Kino.inspect_trace/3` is a stepper rather than a snapshot: the
  reopened trace gets the **First / Prev / Next / Live** scrubber, a **Jump
  to** select listing every macrostep by number and event, and a pane saying
  what the selected macrostep changed in the datamodel.
- `StatifierUI.Inspector.datamodel_diff/2`: what one macrostep changed in the
  datamodel, as a Markdown table.
- `StatifierUI.DatamodelExplorer.Diff.between/2` and
  `StatifierUI.DatamodelExplorer.Diff.Markdown.render/2`: the pure comparison
  behind that pane, over two datamodel explorer panes. A slot missing on one
  side is `:absent`, so `nil` and `:undefined` stay values.
- `StatifierUI.Diagram.render/3` takes `:active_style`, which decides how the
  active-configuration highlight is styled: `:default` (the shipped light
  palette, unchanged), `:none` (no `classDef` at all, so the host's own
  stylesheet or Mermaid theme reaches the `active` class the nodes still
  carry), or a `classDef` body as a binary. A host under a dark theme no
  longer has to post-process the Mermaid source to restyle the highlight.
- `StatifierUI.Inspector.diagram/3` accepts the same `:active_style` option,
  and `StatifierUI.Live.diagram/1` and `ops_view/1` the same `active_style`
  attribute.
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
- `StatifierUI.Live.ExpressionInput.expression_input/1` takes a `:document`
  assign: a decoded datamodel document, projected through
  `StatifierDatamodel.Index.path_types/1` for the kinds `:path_types` would
  otherwise carry. A non-empty `:path_types` wins over it.
- `t:StatifierUI.Expression.declared_kind/0` admits `:number`, the tag that
  projection answers for a document's `integer` and `decimal` alike.

### Changed

- `StatifierUI.Inspector.datamodel/2` takes the `:selection` every other fold
  there takes, so the datamodel pane can show the values as they stood at a
  selected macrostep. `datamodel/1` is unchanged.
- Adds a required dependency on `statifier_datamodel ~> 0.1` (see ADR-0004's
  2026-09-06 note).
- "Add clause" seeds the new row's literal from the path's declared kind - `0`
  for a number, `true` for a boolean, today for a date, the first value of a
  `{:one_of, _}`, a `CONTAINS` clause for a list - instead of always seeding an
  empty string.

### Fixed

- Adding a clause on a path declared `:number` no longer produces a row that
  immediately carries a value-kind advisory about its own seed.

## [0.8.0] 2026-09-05

A minor. The expression editor's clause builder takes a `path_types`
assign: a clause's operator list and value control come from the kind the
host declares for the path rather than from the literal in the source, and
a date-declared path offers relative-date candidates. The expression
field's two mode switches also stop rendering run-together on a host page
that ships no stylesheet. The trace wire format is untouched - version `1`,
25 types - so a consumer taking `~> 0.8` re-pins nothing.

### Added

- `StatifierUI.Live.ExpressionInput.expression_input/1` takes a `:path_types`
  assign, `%{path => kind | {:list, kind} | {:one_of, values}}`, which decides a
  clause's operator list and value control from the kind the host declares
  rather than from the literal in the source.
- `StatifierUI.Expression.simple/2` takes a `:path_types` option, and each row
  it returns carries `:declared_kind`, `:control_kind` and `:advisories`.
- `StatifierUI.Expression.relative_date_candidates/0` returns the relative
  dates a date-declared path offers.

### Fixed

- The expression field's two mode switches no longer render run-together on a
  host page with no stylesheet: their container carries an inline
  `display: inline-flex; gap: 0.5rem`, the one layout default this package
  ships.

## [0.7.0] 2026-09-05

A minor. The wire vocabulary grows to 25 types with
`trace.conds_evaluated`, which carries a selection round's guard outcomes
so a guarded chart's stream can say why a branch fired; `session.start`'s
`data` rows stop falling back to the element's own span for
`value_location`; `StatifierUI.Trace.Replay.recording/3` becomes public
surface; and the `predicator` floor rises to `~> 9.4`. The wire format
version stays `1`. A consumer that asserts the vocabulary size rather
than reading it re-pins 24 to 25 when it takes `~> 0.7`.

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

- `StatifierUI.Trace.Replay.recording/3`, which builds the
  `Statifier.Session.Recording` a host's stored inputs describe and returns
  it. It is the fold `from_events/4` already ran to reach its own recording,
  now reachable on its own - for `Statifier.Replay.run/1` directly, for
  `Statifier.Session.Recording.to_binary/1`, or to compare against a
  recording you already hold. An unrecognized entry shape is
  `{:error, {:unknown_entry, entry}}`, the same fail-closed answer
  `from_events/4` gives; `:trace` and `:session_id` are not checked here,
  because they are requirements of the message stream rather than of the
  recording.

  `docs/ops-embedding.md`'s "From a persisted event log" now carries the
  table saying which stored row becomes which of the six entry shapes, and
  states the rule a fired delayed send turns on: it is
  `{:timer, send_id, event, routes}`, never `{:event, event, routes}`,
  because only the timer shape draws the pending-timer credit the `send_id`
  matches. Naming a firing as an event costs the
  `{:unscheduled_timer_firing, send_id}` check and leaves the credit
  outstanding for a later cancel to move into the raced pool.

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

- `session.start`'s `data` rows omit `value_location` when the `<data>`
  element wrote no value, instead of falling back to the element's own span.
  A consumer that compared the two spans before slicing `source` can now test
  for the key's presence instead; one that sliced without comparing stops
  getting the whole element's text presented as a value. The wire format
  version stays 1.

- The predicator requirement is `~> 9.4`, up from `~> 9.2`: a host on 9.2 or
  9.3 has to move up, and gets `Predicator.Simple.value_kind/1`, which
  `StatifierUI.Expression` now asks what kind a clause value is instead of
  keeping its own table.
- `StatifierUI.Expression.simple_available?/0` also requires the resolved
  `:predicator_simple` module to export `value_kind/1`. A host that points that
  key at its own module has a fourth function to provide; every published
  predicator at the new floor already carries it.

## [0.6.1] 2026-09-05

A hotfix. `StatifierUI.Trace.Normalizer.normalize/2` refused statifier 2.5's
`Statifier.Effect.Trace.CondsEvaluated`, which meant no chart with a guarded
transition could be inspected from a persisted trace; the normalizer now
skips it, and the `statifier` floor rises to `~> 2.5`. A caller matching only
`{:ok, _}` and `{:error, _}` on `normalize/2` needs a `:skip` clause.

### Changed

- Raises the `statifier` floor to `~> 2.5`.
- `StatifierUI.Trace.Normalizer.normalize/2` has a third return, `:skip`, for
  an engine trace effect the v1 wire format deliberately does not carry. A
  caller matching only `{:ok, _}` and `{:error, _}` needs a clause for it;
  neither a message nor a `seq` is produced.

### Fixed

- `StatifierUI.Trace.Normalizer.normalize/2` no longer refuses statifier
  2.5's `Statifier.Effect.Trace.CondsEvaluated`, so a chart with a guarded
  transition can be replayed through `StatifierUI.Trace.Replay.from_events/4`
  instead of failing closed on its first branch.

## [0.6.0] 2026-09-05

A failure becomes something the wire format can carry, and a trace can be
produced without a live run. `StatifierUI.Trace.Replay.from_events/4` builds
the v1 wire format from a persisted event log, so a finished session can be
inspected offline. The wire `error` object gains a discriminated reason arm,
which is what lets an `error.execution` or `error.communication` event reach
a consumer at all instead of being dropped in normalization.
`StatifierUI.Live.ExpressionInput.display_label/1` is removed; the grammar's
display phrases replaced the only work it did.

### Added

- `StatifierUI.Trace.Replay.from_events/4` produces the v1 trace wire format
  from a persisted session event log, with no live `Statifier.Session`, no
  process, and no clock - the same message stream
  `StatifierUI.Trace.Subscriber` produces from a live run, `session.terminated`
  excepted. A recording made without `trace: true` is refused rather than
  replayed into a silently `trace.*`-free stream. See ADR-0017.
- The wire `error` object gains a `class` discriminator (`"expression"` or
  `"reason"`), and on the reason arm a `kind` token derived from the term's
  tag, a human-readable `reason` string, and a `content_path` naming the
  enclosing `<if>` or `<foreach>` when the failure was raised inside one.
  Adding fields is not a format version bump, so the format version stays
  `1`. See ADR-0014 and `docs/wire-format.md`.

### Changed

- `error.reason` is redacted under every projection profile, beside
  `session.terminated`'s `reason`: it is `inspect/1` of a whole engine term
  and can embed a datamodel value verbatim. `class`, `kind`, and
  `content_path` are never projected.

### Removed

- `StatifierUI.Live.ExpressionInput.display_label/1`. It lowercased a
  word-shaped lexeme so a dropdown could read `in` where the decompiler wrote
  `IN`. Since operator labels became the grammar's own display phrases,
  delivered by `StatifierUI.Expression.operators/1`, every label it could be
  handed was already display-cased and it returned its argument unchanged.
  Operator options now carry the grammar's phrase verbatim, which leaves one
  spelling of a display phrase in the system and it is the vocabulary's.

### Fixed

- A `trace.event_dequeued` for an `error.execution` or `error.communication`
  event now reaches a consumer. The engine puts an unconstrained reason term
  in those events' data, which is not a value, so the whole message used to
  fail to normalize and be dropped - the inspector showed a run in which the
  failure simply was not there.

## [0.5.0] 2026-09-05

Operator eligibility moves to the grammar. `StatifierUI.Expression` asks
`Predicator.Simple.operators/1` which operators a value kind admits instead of
answering from a table of its own, so a picklist offers what the grammar
offers and lists it in the grammar's order. An operator entry now carries the
source spelling and the display phrase separately, which is the one migration
in this release.

### Added

- `StatifierUI.Expression`'s `t:value_kind/0` gains `:float`, so a float-valued
  clause is offered the operators a number is offered once the resolved
  predicator admits float literals to the subset.

### Changed

- `StatifierUI.Expression.operators/1` reads per-value-kind eligibility from
  `Predicator.Simple.operators/1` instead of a table kept here, so the
  operators offered beside a value are the ones the grammar admits for that
  kind. Every scalar kind but `:string` now also offers `===`, `!==` and
  `CONTAINS`, which `:string` already offered, and a string gains the ordered
  comparisons.
- Each entry `StatifierUI.Expression.operators/1` returns gains `:lexeme`, the
  source spelling the expression will carry, and its `:label` is now the
  grammar's display phrase (`"is at least"` for `">="`) rather than the
  spelling. Read `:lexeme` where you were reading `:label` to build source
  text; nothing stored changes, since a row is still written back through
  `Predicator.Simple.to_source/1`.
- `StatifierUI.Live.ExpressionInput`'s operator dropdown shows those phrases.
  The `value` attribute on every option is unchanged: it is still the writer's
  own untouched output.

### Fixed

- A picklist control now shows the choice that was just made. LiveView skips
  patching a `<select>` that has focus when the option list is unchanged, so
  after an operator, field or connective edit the control kept displaying the
  previous selection until the field was re-rendered from scratch; the hook now
  restores it from the source string the server rendered.

## [0.4.0] 2026-09-04

Structured authoring reaches the expression field. `StatifierUI.Expression`
gains a read and write pass over the picklist-renderable subset of
predicator's grammar, and `StatifierUI.Live.ExpressionInput` renders that
subset as one row of dropdowns per clause - field, operator, value - keeping
the text field for anything outside it. The source string stays the single
representation: picklists are a rendering of it and never a second form of it
(ADR-0007), and every value a dropdown offers is a complete expression the
writer produced.

### Added

- `StatifierUI.Expression.simple/2` classifies a source string against the
  picklist-renderable subset, returning `{:ok, rows, connective}` for source a
  row of dropdowns can draw, `:outside` for a valid expression it cannot, and
  `{:error, error}` for source that does not parse. Each row carries the field
  path, the operator, the value, and the value's kind in both structural and
  source form.
- `StatifierUI.Expression.operators/1` returns the operators a picklist offers
  beside a value of a given kind, and
  `StatifierUI.Expression.value_candidates/2` normalizes the values a host
  declares for a path.
- `StatifierUI.Expression.simple_available?/0` reports whether the resolved
  predicator exposes `Predicator.Simple`. A host on an older predicator gets
  `:outside` for every source string rather than an error.
- `StatifierUI.Live.ExpressionInput` renders a **picklist mode**: a source
  string inside the picklist-renderable subset draws one row of dropdowns per
  clause - field, operator, value - with a connective toggle, an add-clause
  button and a remove-clause button per row. A valid expression outside the
  subset, and source that does not parse, render the text input as before.
  The component never refuses a source string and never rewrites one.
- Source that does not parse now renders the text input alongside the parse
  error's message and position, stamped as `data-error-position`, rather than
  falling back silently.
- A switch to text mode is always offered; the switch to picklists appears
  only while the current text is inside the subset. `:mode` (`:auto`, `:text`,
  `:picklist`) sets which mode renders first, and `:value_candidates` supplies
  the values a host offers per clause path.
- `StatifierUIExpressionPicklist`, a second hook, shipped as source alongside
  the completion popup and exported from `StatifierUIHooks`.
  `StatifierUI.Live.ExpressionInput.picklist_hook_name/0` names it, and
  `display_label/1` is the one place an operator label is cased for display.
  A host that registers no hook gets the text field alone.
- `StatifierUI.Expression.source/2` writes a source string back from the rows
  `simple/2` returned, `value_source/2` spells one clause value on its own,
  and `segments/1` reads a declared path into the structural form a clause
  carries. Together they are the write half of the same round trip through
  `Predicator.Simple`, which is what keeps the source text the single
  representation: every picklist option's value is a complete expression the
  writer produced, and no quoting, escaping, list punctuation or operator
  spelling is repeated in JavaScript.

## [0.3.0] 2026-09-02

The ops surface arrives. `StatifierUI.Live` ships read-only LiveView
components a host mounts over one trace stream, live or persisted; the
Livebook inspector gains a scrubber that moves the diagram to any macrostep
in the run; and `StatifierUI.Live.ExpressionInput` offers predicator's own
grammar as completion, dropping into statifier_blocks' editor seam - which
makes this the first release to ship JavaScript. Around them the trace wire
format reserves `otel` for W3C Trace Context correlation, with a producer
and an APM deep-link consumer on either side of it, gains per-attribute
source spans on the identity tables, and `StatifierUI.Trace.Projection`
redacts values out of a stream so a capture can travel without carrying
any.

### Added

- The Livebook inspector's diagram can be moved to any macrostep in the
  event log and back, pairing the two panes into a comprehension surface
  for one point in a run rather than only the live tip (sui-3gg). Four
  buttons above the diagram - **|< First**, **< Prev**, **Next >**,
  **Live** - drive it; the selected macrostep's entry in the log is
  opened and marked `- shown in the diagram`, and a note above the
  diagram names the point on screen.
- `StatifierUI.EventLog.configuration_at/2` returns the configuration in
  force at a macrostep, distinguishing `{:quiescent, configuration}` from
  `{:carried, from, configuration}` (the macrostep never settled, so an
  earlier one's configuration is shown) and `:before_first`. A carried
  configuration is never presented as a measured one - which is what
  surfaces `sui-dc7`'s halting macrostep out loud instead of silently.
- `StatifierUI.Inspector` gained the `:selection` option (`:live` or
  `{:macrostep, n}`), plus `points/1`, `step/3`, `resolution/2`, and
  `selection_note/2`. Every decision the scrubber makes lives here, so a
  LiveView or other host gets the same behaviour without Kino.
- `StatifierUI.EventLog.Markdown.render/2` gained `:selected`, which
  suffixes one macrostep's summary with `- shown in the diagram`.

Nothing here re-derives a configuration: every one it can show was
stamped by the engine on a `trace.macrostep_stable`, and a caught-up
stream got there through statifier ADR-0034 replay. Time travel is a read
of replay output as data (ADR-0002's inherited clause), so selecting a
macrostep neither touches the session nor needs anything new from the
engine.

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

- `StatifierUI.DatamodelExplorer` carries `session.start`'s `projection`
  header on the pane struct and exposes it as `projected?/1` and
  `projection_profile/1`, so a host can surface the profile name alongside
  the mode (ADR-0012).
- `StatifierUI.DatamodelExplorer.edit_disabled_reason/1` and `/2`, with the
  boolean forms `editable?/1` and `editable?/2`: ADR-0012's rule that no
  value-editing affordance may be offered over a projected stream, or over a
  redacted slot, as a function a write path can consult. The reason is a
  sentence written to be shown, naming the profile or the slot. The pane
  still has no write path of its own; this is the guard whatever builds one
  asks first.
- `StatifierUI.DatamodelExplorer.Markdown` renders that reason under a live
  pane's header when the stream is projected, instead of leaving the reader
  to guess why every value reads `(redacted)`.

`StatifierUI.EventInjection` is explicitly **excluded** from the same rule
and its moduledoc records why: its palette is composed from a fixtures
bundle the operator already holds in full, never from observed values, so
projection cannot reach it.

- Such an event now carries an `error` object naming the failure kind, the
  expression, the span within it, and the absolute, pre-resolved document
  location of the failing subexpression - so a consumer underlines it
  directly with no span composition of its own. `docs/wire-format.md` now
  states the end-exclusive convention for spans and locations explicitly.
- `StatifierUI.EventLog.configuration_at/2` gained a fourth outcome,
  `{:final, configuration}` - macrostep `n` halted the run, and this is
  the configuration it exited in. It is kept distinct from
  `{:quiescent, configuration}` for the same reason `{:carried, ...}` is:
  a configuration the chart *exited* in is not one it *settled* in, and
  `StatifierUI.Inspector.selection_note/2` words the two differently
  ("at the final configuration the run halted in").
- `StatifierUI.EventLog.Macrostep` gained `final_configuration` and
  `stamped/1`, and `StatifierUI.Inspector.points/1` gained `final?`
  beside `quiescent?` - a halting macrostep is not quiescent, and a
  scrubber saying so is not the same as one saying it has nothing to
  show.
- `StatifierUI.Trace.Projection` projects a trace stream down to structure,
  transitions, outcomes and ordering, replacing datamodel and payload values
  with the reserved `{"$redacted": true}` sentinel (ADR-0012). Build a
  profile with `profile/2` and pass it to
  `StatifierUI.Trace.Subscriber.start_link/1` as `:projection`; every message
  is projected before it is buffered or fanned out, so a projected stream can
  be rendered, encoded or persisted without any of those having held a value.
- A profile allows values back by path prefix (`allow_paths`, matching
  `effect.datamodel_change`'s `location_path` encoding) or by naming an
  unlocated position (`allow_positions`). A prefix longer than a write's own
  path descends into the written value, so an allowed leaf passes while its
  withheld siblings are redacted. `allow_source: false` additionally redacts
  `session.start`'s chart source.
- `session.start` carries a `projection` header naming the mode and profile
  whenever the stream is projected, so a projected capture is always
  distinguishable from a full one.
- `StatifierUI.Value` decodes `{"$redacted": true}` to the new `:redacted`
  atom and encodes it back; `StatifierUI.Shape` gains a matching `:redacted`
  shape that renders as `redacted`.
- `StatifierUI.Live` - read-only LiveView function components for a host
  application's ops views: `ops_view/1` composing `status/1`, `scrubber/1`,
  `diagram/1`, and `event_log/1` over one trace stream in wire format v1,
  live or persisted. Compiled only when the optional `:phoenix_live_view`
  dependency is present (ADR-0004); without it every component raises with
  instructions. `docs/ops-embedding.md` is the embedding guide.
- `StatifierUI.Live.State` - the pure read model a host keeps in its socket:
  `new/2` over a persisted message list, `push/2` for a live subscriber's
  fan-out (dropping any message whose `seq` is not newer than the newest one
  held, so the `add_listener` then `sync/2` overlap costs nothing),
  `sync/2` to pull a subscriber's buffer and stats in one call, and
  `scrub/2` / `select/2` over `StatifierUI.Inspector`'s selection.
- The event log renders as HTML rather than Markdown in a LiveView host, so
  clicking a macrostep entry moves the diagram to it - the link the Livebook
  pane cannot have, because a Markdown document has no click target.
- `docs/ops-embedding.md` - embedding the ops view in a host LiveView, live
  and persisted, with the styling hooks and the Mermaid client the diagram
  pane expects a host to supply.
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
  (statifier 2.0.0 and later).
- `StatifierUI.Live.ExpressionInput` - an expression field with completion,
  offering predicator's own grammar (operators, keywords, literal words,
  duration units, and every function the host's providers resolve) alongside
  the datamodel paths the host declares. It is the affordance
  statifier_blocks ADR-0005 defers to this package, and it drops into that
  editor's `expression_component` seam as
  `&StatifierUI.Live.ExpressionInput.expression_input/1` (sui-wqr). The field
  carries no event of its own: it renders an `<input>` with the `name` it was
  given, so edits - typed or completed - arrive through the host form's
  existing `phx-change`.
- `StatifierUI.Expression` - the completion source behind it, pure and
  without LiveView: `completions/2` returns `{label, insert, kind, detail}`
  entries read from `Predicator.Vocabulary` and the supplied paths, so a host
  can render its own control over the same list.
- **This package now ships JavaScript**, as source under `assets/`, per
  ADR-0009. A host adds `"statifier_ui": "file:../deps/statifier_ui/assets"`
  to its `assets/package.json` and spreads `StatifierUIHooks` from
  `js/index.js` into its `LiveSocket` hooks. The one hook,
  `StatifierUIExpressionInput`, upgrades the field from a native `<datalist>`
  to a caret-aware completion list; it imports nothing, and a host that
  registers no hook keeps a working field. Hook names and export names are
  public API. See the ADR-0009 note of 2026-09-02 for the layout.

### Changed

- `StatifierUI.Inspector.event_log/1` is now `event_log/2`, taking the
  same options as the other fold functions. The one-argument call is
  unchanged in behaviour.
- A transition written `type="internal"` now carries an `[internal]`
  marker in the diagram. SCXML's `external` default stays unmarked, so the
  two no longer render identically.
- `StatifierUI.Diagram`'s moduledoc gained a "Known limits of this
  projection" section: lifted-edge geometry (including edges between two
  regions of one parallel state), self-edge notation for internal
  transitions, pseudo-states drawn as ordinary nodes, shallow-versus-deep
  history distinguishable only by label, executable content not drawn, and
  layout left entirely to Mermaid. These are the accepted limits of the
  Mermaid backend rather than defects; ADR-0008's elkjs renderer is where
  they are addressed.
- The trace wire format reserves `otel` as an envelope key: an optional
  object carrying the W3C Trace Context `trace_id` and `span_id` of the
  OpenTelemetry span covering a message's macrostep, legal on `trace.*` and
  `effect.*` messages only (ADR-0013). No producer emits it yet, the format
  version stays `1`, and a stream with no correlation context attached is
  byte-unchanged - but a payload may no longer use `otel` as a key.
- The wire format's reserved one-key `$`-prefixed shape admits `$redacted`,
  making five reserved forms rather than four. The format version stays `1`:
  no existing stream changes, and full fidelity remains the default and is
  byte-unchanged.
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
- `predicator` is now a direct dependency at `~> 9.1`, the release that
  carries `Predicator.Vocabulary`. It arrived only through `statifier`
  before; the completion source reads the vocabulary itself, and a host on a
  predicator without it gets its declared paths and no grammar entries
  rather than an error (sui-vsx).

### Fixed

- `StatifierUI.Diagram.render/2` no longer drops transitions the Mermaid
  projection has no obvious notation for. A targetless transition - the
  spec-legal way to run executable content without changing configuration -
  was rendered as nothing at all, so a state that handles an event read as
  one that ignores it; it is now drawn as a self-edge marked `[internal]`.
  A history state's default transition, which lives in `history_default`
  rather than in the selectable `transitions` list, was dropped the same
  way, leaving the `(H)` / `(H*)` label naming a pseudo-state whose
  fallback target was invisible; it is now drawn with a `[default]` marker.
- An event whose data is an expression-evaluation failure no longer fails to
  normalize. Previously `StatifierUI.Value.encode/1` rejected the failure
  payload and the whole trace message was dropped, so the diagnostic a
  consumer most needs never reached the wire.
- The configuration pane now shows a halted chart's final configuration
  (sui-dc7). A run that ends by entering a top-level `<final>` never
  reaches quiescence in its last macrostep, so it emits no
  `trace.macrostep_stable` for it; `StatifierUI.Inspector` read only that
  message type and therefore kept highlighting the state the chart had
  *left*, while the datamodel pane showed the assignment that moved it
  out. Both stamping messages are read now, newest wins.

  The wire format is what settles that `trace.done` may be read this way:
  its `configuration` field is defined as "the full configuration as it
  stood at exit, a genuine set, sorted ascending" - the same shape and the
  same authority as a `trace.macrostep_stable` payload. Nothing here
  re-derives an exit configuration from the exit sets that precede
  `trace.done`; the format version is unchanged and the engine is
  untouched.
- `StatifierUI.EventLog.Markdown` no longer raises `Protocol.UndefinedError`
  when a `session.terminated` message carries a non-string `reason`. It and
  the datamodel explorer now render a withheld value as `(redacted)` rather
  than as unbound or as a literal one-key map.
- `docs/wire-format.md` no longer says `session.start`'s `data.value_location`
  is present only when the compiler recorded a value span. A conformant
  producer always emits it, falling back to the element's own span, exactly as
  the surrounding prose already said - so a consumer need not handle its
  absence.

## [0.2.0] 2026-08-27

Fixtures become executable. ADR-0006 adds named datasets and free-standing
expressions to a fixture bundle, `StatifierUI.TruthTable` evaluates the two
against each other into a result matrix, and a bundle can now travel with a
single reusable chart fragment rather than with a whole chart - so a palette
entry carries its own worked examples and a host can run them in its own
suite.

### Added

- `StatifierUI.Fixtures` gains `datasets` and `expressions` fields (ADR-0006):
  named example datamodels for evaluating expressions against, and named
  free-standing predicator expressions carrying an `expect` map keyed by
  dataset name.
- `StatifierUI.Fixtures.Source` gains optional `datasets/0` and
  `expressions/0` callbacks so a host can supply the two new maps from
  Elixir alongside `scenarios/0` and `example_events/0`.
- `StatifierUI.Fixtures.Lint` reports an expression matching no compiled
  guard and an `expect` key naming no dataset, both as warnings.
- `StatifierUI.Fixtures.Expectations` runs every `expect` entry against its
  named dataset and reports whether the stated value held, for wiring into a
  host's own test suite.
- Depends directly on `predicator` (`~> 9.0`) rather than only transitively
  through `statifier`.
- `StatifierUI.TruthTable` evaluates a bundle's expressions across its
  datasets and returns the ADR-0006 result matrix, one cell per
  `(expression, dataset)` pair. A cell's verdict is `:satisfied`,
  `:unsatisfied`, `:undefined`, `:value`, `:error`, or `:missing_dataset` -
  deliberately not `true` / `false`, so predicator's three-valued
  `undefined` cannot be collapsed into false by Elixir truthiness.
- `StatifierUI.TruthTable.Markdown` renders that matrix as Markdown, with
  datasets down the rows and expressions across the columns by default, or
  transposed with `orientation: :expressions_as_rows`. Every cell spells its
  value out as a word and adds emphasis on top, so the three truth values
  stay distinct in plain text.
- `StatifierUI.Kino.truth_table/2` wraps the rendered matrix in a
  `Kino.Markdown` widget for a Livebook cell. It needs no session and no
  Phoenix; without the optional `:kino` dependency the stub points at the
  pure renderer instead.
- `StatifierUI.Fixtures.Bundle` lets an ADR-0003/ADR-0006 fixture bundle
  travel with one reusable chart fragment instead of with a whole chart, so
  a palette entry can carry its own executable examples. A fragment supplies
  its bundle as a `StatifierUI.Fixtures` struct, an atom-keyed Elixir map, a
  string-keyed sidecar map, or a path to a `.fixtures.json` file; all four
  route through the existing validation and converge on one struct.
- `StatifierUI.Fixtures.Bundle.discover/2` loads every entry's bundle across
  a palette of modules, and `discover_dir/2` does the same for a directory
  of `<fragment>.fixtures.json` files. Neither is all-or-nothing: a fragment
  that ships no examples is reported as an absence, and one malformed bundle
  is reported against its own name while the rest still load.
- `StatifierUI.Fixtures.Bundle.Markdown` renders a fragment's "test this
  step" panel - its truth table and its expectation results together - and
  `render_discovery/2` renders a whole palette's worth. The expectations
  summary reports four counts rather than a pass or a fail, because
  `Expectations.check/2` and `Fixtures.Lint` deliberately disagree about
  whether an `expect` key naming no dataset is a failure or a warning.
- `StatifierUI.Kino.test_panel/2` and `StatifierUI.Kino.palette_panel/2`
  wrap those renderings as `Kino.Markdown` widgets. Like `truth_table/2`
  they need no session and no chart; without the optional `:kino`
  dependency the stubs point at the pure renderers instead.
- `docs/fixture-bundles.md` documents the convention and walks an embedder
  through wiring a palette entry's bundle, discovering a whole palette, and
  running every fragment's expectations in a host suite.

## [0.1.1] 2026-08-24

Documentation-only release: brings the hexdocs to the shared fleet standard.
No code changes.

### Changed

- Unpublishes the ADRs from hexdocs; they remain in the repository under
  `docs/adr/`.
- Fixes the five broken links in the published docs - repo-relative
  references (research doc, ADRs, inspector notebook, architecture's
  research link, LICENSE) now resolve as absolute GitHub URLs or badges.
- Adds a badge row (CI, Hex version, downloads, hexdocs, license) and a
  Documentation index to the README, and corrects the stale claim that the
  project has no CI.
- `mix docs` now builds with zero warnings.

## [0.1.0] 2026-08-22

First release: authoring, observing, and debugging components for the
[statifier](https://hex.pm/packages/statifier) statechart engine, consuming
its effect stream through the language-neutral trace wire format (format
version 1). The Livebook inspector is the first assembled frontend; the
panes underneath it are pure folds any other frontend can render.

### Added

- `StatifierUI.Diagram.render/2` renders a compiled machine and an active
  configuration as Mermaid `stateDiagram-v2` source for `Kino.Mermaid`, with
  composite nesting, parallel regions, active-state highlighting, and
  cross-hierarchy transitions lifted to the composite level with a
  `[lifted: ...]` marker.
- `StatifierUI.EventLog.build/1` folds a trace message stream into a log
  grouped by `(macrostep, round)`, ordered by the producer's stamps rather
  than arrival, and `StatifierUI.EventLog.Markdown.render/2` renders it as
  collapsible Markdown for `Kino.Markdown`, with wire-format indexes
  resolved to state and transition names by `StatifierUI.EventLog.Labels`.
- `StatifierUI.EventInjection.build/1` turns an ADR-0003 fixture bundle
  (or `nil`) into the event-injection pane model: a sorted palette of
  editable event buttons via `StatifierUI.EventInjection.Palette`, a
  `free_form_only?` flag for the fixture-less degraded mode, and
  `send/2`/`send_draft/3` to deliver a `StatifierUI.EventInjection.Draft`
  through `Statifier.Session.send_event/2` - the ordinary recordable input
  path, per statifier ADR-0029.
- `StatifierUI.DatamodelExplorer.build_authoring/3` and `build_live/2` build
  a read-only datamodel tree - document `<data id>` declarations, spec
  5.10.1 system variables, predicator provider functions in scope, and
  either a fixture scenario or a live session's datamodel with entries
  marked `changed?` per macrostep - and
  `StatifierUI.DatamodelExplorer.Markdown.render/2` renders it as Markdown
  for `Kino.Markdown`.
- `StatifierUI.Kino.inspect/3` assembles the Livebook inspector: the
  configuration diagram, datamodel explorer, event injection, and event
  log panes composed over one shared subscriber, live-updating, detaching
  cleanly on cell re-evaluation. Compiled only when the optional `:kino`
  dependency is present.
- `StatifierUI.Trace.Subscriber.attach/3` accepts `catch_up: true`: on a
  session started with `record: true` the missed prefix is replayed into
  the buffer atomically with the subscription (statifier ADR-0049); an
  unrecorded session falls back to live delivery with a `:not_recorded`
  diagnostic the inspector surfaces as "Live-only".
- `StatifierUI.Inspector` - the pure pane-assembly fold the Kino shell
  renders, usable by any other frontend.
- `notebooks/inspector.livemd` - the demo notebook, doubling as the
  milestone's manual acceptance test.
- Serializes statifier's `DatamodelChange` effect as the
  `effect.datamodel_change` wire type, so consumers can observe datamodel
  values as they are written instead of only the variable names
  `session.datamodel` carries. New types are additive under the wire
  format's must-ignore rule.
- Every `effect.*` wire message carries the engine's `round` stamp in
  its envelope, alongside `macrostep` and `microstep`; consumers reading
  older recorded streams must still tolerate `effect.*` messages without
  the key.
