# Telemetry and the OTel bridge half

What this package emits about its own work, and how the family-scoped
bridge consumes it. This is the `sui-b94` design note; the wire-format half
of the same bead - whether and how a trace message carries OTel correlation
ids - is ADR-0013, and this note does not restate it.

Read alongside statifier's `docs/opentelemetry.md` (the span topology the
bridge implements for the engine) and statifier ADR-0062 (the bridge is a
separate package, `opentelemetry_statifier`, scoped to the whole family
rather than to the engine alone).

**Status: accepted (2026-09-01, campaign-025; unqualified direction-agent verdict).** Nothing here is emitted today. The surface below is
the decision about what this package *will* emit and what it will never
emit; the emit sites and their tests are a follow-up bead.

## Constraints fixed before this note

- **No OTel API call from this repository, ever.** statifier
  `docs/opentelemetry.md` states it for the engine and the reasoning
  transfers unchanged: the bridge is the only component that knows what a
  span is. This package emits `:telemetry` events, which are data, and stops
  there.
- **Every integration stays optional (ADR-0004).** `:telemetry` is already
  the family's lowest-common-denominator dependency and adds nothing a host
  did not have; `opentelemetry_api` would be a dependency this package
  cannot make optional in any honest sense, and is not this package's call
  to add to a host.
- **This is not an adoption of statifier ADR-0040.** ADR-0002 considered the
  engine's session telemetry contract for its adopted list and declined it,
  and that stands. This package emits its own events under its own
  namespace; it subscribes to none of the engine's. The two surfaces meet in
  the bridge and nowhere else.
- **ADR-0012's projection discipline applies to metadata.** A telemetry
  metadata key is a value position that no projection profile can reach, so
  the rule here is stricter than the wire format's: chart values and
  datamodel values never appear in an event at all, not even redacted.

## What emits, and what deliberately does not

The rule that decides membership: **a pure module emits nothing.** Most of
`lib/` is pure by design - `StatifierUI.Inspector`, `StatifierUI.EventLog`,
`StatifierUI.DatamodelExplorer`, `StatifierUI.TruthTable`,
`StatifierUI.Value`, `StatifierUI.Shape` and the `Trace.*` pure modules are
folds over data a caller already holds. Instrumenting a fold reports the
caller's loop, not this package's work, and a host that wants that timing
has its own span around the call. Their absence from the list below is a
decision, not an oversight.

That leaves three places where this package does something a host cannot
see from outside: the one process it owns, the one place it reads a file,
and the one place it does non-trivial work over a whole chart.

### `[:statifier_ui, :subscriber, ...]` - the attach lifecycle

`StatifierUI.Trace.Subscriber` is the only `GenServer` here. It owns attach
and detach, `seq` stamping, and the bounded buffer, and it is where a host's
"why is my inspector missing the opening burst?" question is actually
answerable.

| Event | Measurements | Metadata |
|---|---|---|
| `[:statifier_ui, :subscriber, :attach]` | `buffered` | `session_id`, `path`, `projected`, `profile` |
| `[:statifier_ui, :subscriber, :detach]` | `buffered`, `dropped` | `session_id`, `reason` |
| `[:statifier_ui, :subscriber, :overflow]` | `dropped`, `capacity` | `session_id` |

`path` is `:early | :late | :catch_up` - the three attach sequences the
subscriber's own moduledoc distinguishes, and the distinction that decides
whether the initialize burst is in the stream at all (`st-uqo4`, statifier
ADR-0049 for the catch-up path). It is the single most useful field in this
whole surface: an inspector that looks wrong because it attached late looks
identical to one that looks wrong for a real reason.

`projected` and `profile` name the ADR-0012 projection in force, so a
capture filed by an operator can be told apart from a full one without
reading the stream.

**`:overflow` is not the drop notification `StatifierUI.Trace.Buffer`
refuses.** That moduledoc rejects a synthetic drop *message*, on the ground
that it would consume a `seq` and corrupt the counter a consumer detects
loss by. A telemetry event is out of band: it consumes no `seq`, it never
enters the buffer, and the wire stream is byte-identical whether or not
anyone is listening. It is emitted on the transition into a dropping state
and not once per dropped message, which is the difference between an alert
and a flood.

### `[:statifier_ui, :fixtures, :load, ...]` - a span, because it is IO

`StatifierUI.Fixtures.Sidecar` reads a `<chart>.fixtures.json` file
(ADR-0003, extended by ADR-0006) and decodes it; `StatifierUI.Fixtures.Lint`
walks the result. It can fail, it touches a filesystem, and it is the step
a host blames when a notebook opens with no fixtures.

Emitted as a `:telemetry.span/3` triple - `:start`, `:stop`, `:exception` -
with the standard `duration` on the stop half.

Metadata: `path` (the sidecar's own path, which is developer-supplied
configuration and not run data), `version` (the bundle's), the four counts
`scenarios` / `events` / `datasets` / `expressions`, `diagnostics` (how
many, not which), and `lint_findings` (likewise). On the `:stop` half,
`outcome` is `:ok` or `:error` with `reason` naming the error tag only -
`:duration_in_scenario`, `:unknown_key`, and so on.

The counts and not the contents: a fixture bundle is a datamodel bundle by
construction (ADR-0012 replaces it whole rather than descending into it),
so nothing under `scenarios`, `events`, `datasets`, or an expression's
`expect` may appear in an attribute. An expression's `source` is chart-
adjacent text and is likewise out - the count is the signal a host needs,
and the source is a thing they can read from the file they already have.

### `[:statifier_ui, :diagram, :render, ...]` - a span, server half only

`StatifierUI.Diagram.render/2` is pure, which by the rule above would
exclude it, and it is included anyway for one reason: it is O(chart) on
every configuration change, so it is the only pure function here whose cost
a host can actually notice. Emitted as a span, with `states`,
`transitions`, and `lifted_edges` as measurements and `backend` as
metadata.

`lifted_edges` counts the cross-hierarchy transitions Mermaid cannot draw
and `render/2` lifts to the endpoints' least common ancestor. It is a
diagram-quality signal rather than a performance one: a chart with many
lifted edges is being drawn misleadingly, and today nothing says so.

`backend` is `:mermaid` today and will be `:elk` when ADR-0008's destination
renderer arrives, which is exactly the kind of change a metadata key
absorbs and a hard-coded event name does not.

**The browser half is deliberately absent.** ADR-0008 puts layout in
client-side elkjs and ADR-0009 ships the JavaScript as source, so the
expensive part of rendering happens somewhere the BEAM cannot emit from.
Instrumenting it would mean a browser tracing SDK inside a package whose
JavaScript a host compiles with its own esbuild - a dependency decision
belonging to the host, not to a component library. A host that wants
browser spans instruments its own page around the hook. Server-side, this
event covers graph construction and nothing else, and should be read that
way rather than as the render's total cost.

## Naming and shape rules

- **Namespace `[:statifier_ui, <component>, <operation>]`**, matching the
  engine's `[:statifier, :session, ...]` shape so a bridge handler list
  reads uniformly across the family.
- **Spans use `:telemetry.span/3`'s `:start`/`:stop`/`:exception` triple**,
  never a hand-rolled pair. The bridge gets `duration` and the
  `telemetry_span_context` convention for free, which is what lets it pair
  halves the way statifier `docs/opentelemetry.md` pairs macrostep halves -
  on `span_ref`, never on reconstructed identity.
- **Point events carry no span**, and there are three of them (attach,
  detach, overflow). They become span events on whatever span the host has
  open, or standalone zero-duration spans if it has none - the bridge's
  call, not this note's.
- **Measurements are numbers; metadata is identity.** No struct, no
  configuration map, and no decoded fixture bundle rides in either.
- **Nothing unbounded.** Every metadata value above is a fixed atom, an
  integer, a session id, or a developer-supplied path. There is no key whose
  cardinality grows with the run.

## The bridge half

`opentelemetry_statifier` is family-scoped by statifier ADR-0062 - siblings'
telemetry surfaces land there as optional per-library setup calls rather
than each package growing its own bridge. This surface is one of those
siblings, and the bridge-side handler, its module name, and its setup
function are that package's to name in that package's repository, under the
cross-repo rule this repo records in ADR-0010 and its `CLAUDE.md`. This note
supplies the contract to bridge against and stops there.

Two things the bridge should know about this surface specifically:

- **It is not on the engine's critical path.** These events fire when a host
  attaches an inspector, loads fixtures, or draws a diagram - not per
  macrostep and not per microstep. Whatever sampling the macrostep spans
  need, this surface does not need it.
- **The correlation between the two surfaces runs through ADR-0013, not
  through here.** A `[:statifier_ui, :subscriber, :attach]` span and a
  `statifier.macrostep` span are related by session id and by nothing else;
  the per-macrostep join is the `otel` key in the wire format, and it is
  fed from the host rather than from this event surface.

## Deep links: the consuming end of the `otel` key

ADR-0013's key exists so an operator can move between this package's
rendering of a run and the APM backend's rendering of the same run. The
producer half stamps it (`StatifierUI.Trace.Otel`); the consuming half turns
it into a URL, and lives in two modules:

- `StatifierUI.Trace.DeepLink` compiles a **host-configured URL template**
  and renders it against a message's `otel` object.
- `StatifierUI.EventLog.DeepLink` is the seam a renderer calls: it asks the
  macrostep-shaped question ("what is this step's trace?"), because a
  macrostep is the unit upstream opens one span for and the unit an operator
  sees in the log. `StatifierUI.EventLog.Markdown` and
  `StatifierUI.Inspector` both call it.

Both renderers read the same option, so a host configures it once per
render call rather than assembling links itself:

```elixir
template = "https://apm.example.com/trace/{trace_id}?span={span_id}"

StatifierUI.Inspector.event_log(messages, deep_link: template)
StatifierUI.Inspector.selection_note(messages,
  selection: {:macrostep, 2},
  deep_link: template
)
```

The event log appends `- [trace](...)` to the summary line of every
macrostep that carries correlation, after the `- selected` marker when both
apply; `selection_note/2` appends `[open trace](...)` for the macrostep on
screen, leaving the quiescent and carried-forward wording exactly as it was.
Building the links directly, without a renderer, is `for_log/2`:

```elixir
links = StatifierUI.EventLog.DeepLink.for_log(log, StatifierUI.EventLog.DeepLink.from_opts(deep_link: template))
```

**The template is host configuration and has nothing else it could be.**
This package does not know which backend the host's spans went to, and a
default would be a guess that sends an operator to a URL that does not
exist. The variables are `{trace_id}`, `{span_id}`, `{session}`, and
`{macrostep}`; substituted values are percent-encoded to the unreserved set,
so a variable is safe in a path segment or a query value.

Two failure modes are separated deliberately, and the split is the whole
design:

- **A bad template is loud, at configuration time.** An unknown variable, a
  stray brace, or a template naming neither id (which would render one URL
  for every step) raises from `from_opts/1` where the option is read. A typo
  that silently produced plausible URLs resolving nowhere is the outcome
  this refuses.
- **A step with no trace is silent, at render time.** No configured
  template, no `otel` key on the stream, or ids that are not W3C Trace
  Context hex all return `nil` - no link, no error, no log line. Absence is
  the documented normal case: the key is omitted whenever no bridge is
  attached, so most streams carry none, and a renderer asks for a link
  unconditionally rather than first working out the stream's provenance.

Malformed ids fold into "no link" rather than into an error because the wire
format is language-neutral (ADR-0005): an `otel` object may come from a
producer this repository never saw, and ids that cannot be looked up in any
backend are worse to link to than nothing.

## Degradation

`:telemetry.execute/3` with no attached handlers is a lookup and a return.
There is no configuration knob, no `enabled:` option, and no compile-time
switch: a host that attaches no handler pays effectively nothing, and one
that attaches the bridge gets everything above. Adding a knob would create a
second thing to get wrong and a support question ("is telemetry on?") that
currently has no way to exist.

## What this note does not do

- It does not add a dependency or a line of emitting code. The emit sites
  are a follow-up bead in this repository. (The deep-link section above
  describes modules that exist; the telemetry surface itself still does
  not.)
- It does not decide the OTel span shape these events map to. That is the
  bridge's, in its own repository.
- It does not touch the wire format. Correlation ids are ADR-0013;
  this surface is about this package's own work and is invisible in the
  stream.
- It does not instrument the pure fold modules, and a later bead that wants
  to should argue with the "a pure module emits nothing" rule above rather
  than quietly adding one.
