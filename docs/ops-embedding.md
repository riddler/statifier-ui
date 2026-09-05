# Embedding the ops view in a host LiveView

This guide puts the read-only diagram and run-history event log on a page a
Phoenix host already has: an admin screen, a support tool, an incident view.
It covers both streams the components accept - a **live** session being
driven right now, and a **persisted** trace read back from storage.

These are dev/ops surfaces and they render everything the stream carries.
For a tenant-facing view, redact at the producer with an ADR-0012 projection
profile; the status pane then says so, and `sui-hmn` is the bead for a
component designed around redaction rather than one flagged into it.

The second half of the guide is not specific to the ops view. It covers how
this package's JavaScript reaches your bundler, what your stylesheet can
reach once it is there, and - when the shipped components are the wrong
shape for your host - how to render your own surfaces off the wire format
instead.

## What you need

`:phoenix_live_view` is an optional dependency of `statifier_ui` (ADR-0004),
so a host that wants these components declares it itself:

```elixir
{:statifier_ui, "~> 0.7"},
{:phoenix_live_view, "~> 1.0"}
```

Without it, `StatifierUI.Live` compiles to a stub whose components raise
with instructions. `StatifierUI.Live.State` - the read model - has no such
dependency and is always compiled.

## The two moving parts

`StatifierUI.Live.State` is a plain struct in your socket. It holds the
compiled `Statifier.Machine`, the wire-format v1 messages seen so far
(`docs/wire-format.md`), and which point in the run the panes are showing.
It is pure: every reading it answers is `StatifierUI.Inspector` reading the
engine's own `trace.macrostep_stable` stamps, so nothing here re-derives a
configuration or asks a running session for anything.

`StatifierUI.Live` is function components over that struct. There is no
LiveComponent and no process: your LiveView owns the socket, the
subscription, and the events.

## A live stream

```elixir
defmodule MyAppWeb.RunLive do
  use MyAppWeb, :live_view

  alias StatifierUI.Live.State
  alias StatifierUI.Trace.Subscriber

  def mount(%{"run_id" => run_id}, _session, socket) do
    {machine, session, source} = MyApp.Runs.fetch!(run_id)

    {:ok, subscriber} = Subscriber.start_link(machine: machine, source: source)
    :ok = Subscriber.attach(subscriber, session, catch_up: true)
    :ok = Subscriber.add_listener(subscriber, self())

    trace = State.new(machine) |> State.sync(subscriber)

    {:ok, assign(socket, subscriber: subscriber, trace: trace)}
  end

  # The subscriber's fan-out shape.
  def handle_info({:statifier_ui, _session_id, message}, socket) do
    {:noreply, update(socket, :trace, &State.push(&1, message))}
  end

  def handle_event("statifier_ui_scrub", %{"move" => move}, socket) do
    move = String.to_existing_atom(move)
    {:noreply, update(socket, :trace, &State.scrub(&1, move))}
  end

  def handle_event("statifier_ui_select", %{"macrostep" => n}, socket) do
    {:noreply, update(socket, :trace, &State.select(&1, String.to_integer(n)))}
  end

  def render(assigns) do
    ~H"""
    <StatifierUI.Live.ops_view id="run" state={@trace} />
    """
  end
end
```

Three details in `mount/3` earn their place:

- **`catch_up: true`** needs the session to have been started with
  `record: true`. Without it the subscriber falls back to live delivery and
  records a `:not_recorded` diagnostic, which the status pane surfaces as
  **Live-only** - a partial stream is never presented as whole
  (statifier ADR-0049).
- **`add_listener/2` before `sync/2`.** The other order loses every message
  emitted between the two calls. This order can deliver a message twice, and
  `State.push/2` drops any message whose `seq` is not newer than the newest
  one held, so the overlap costs nothing.
- **The subscriber is linked to the LiveView process**, so a disconnect
  takes it down and the session drops it from its subscriber set through its
  own monitor. That is the clean detach; there is nothing to unsubscribe by
  hand.

## A persisted stream

Drop the subscriber and the `handle_info/2` clause. Decode the stored
messages - `StatifierUI.Trace.Json.decode/1` for one message,
`decode_lines/1` for a JSON Lines document, or
`StatifierUI.Trace.Capture.load/1` when the run is a file on disk - and
hand them to `new/2`:

```elixir
def mount(%{"run_id" => run_id}, _session, socket) do
  {machine, messages} = MyApp.Runs.load_trace!(run_id)

  {:ok, assign(socket, :trace, State.new(machine, messages: messages))}
end
```

The two `handle_event/3` clauses and `render/1` are unchanged: the scrubber
works the same over a finished run as over a live one, because both are the
same message list. With no subscriber there are no stats, and the status
pane says `persisted` rather than inventing a status.

A run captured with `StatifierUI.Trace.Capture` needs no unpacking of its
own, because the list it saved is the list `new/2` wants back:

```elixir
{:ok, messages} = StatifierUI.Trace.Capture.load("runs/#{run_id}.jsonl")
State.new(machine, messages: messages)
```

The bytes are stable across runs and the decode is exact
(`docs/wire-format.md`, "Persistence and the v1 round-trip"), so a stored
run diffs against another one as behavior rather than as formatting.

If the stream starts before any macrostep has stabilized - a very early
attach, or a run captured at its first instant - pass the session's own
opening configuration so the diagram has something to draw:

```elixir
State.new(machine, messages: messages, initial_configuration: [0, 1])
```

## From a persisted event log

A host that stored the session's own event log rather than the trace stream
has no messages to decode - it has the inputs the run was driven by.
`StatifierUI.Trace.Replay.from_events/4` produces the message list from
those, offline, with no session process and no clock (ADR-0017):

```elixir
def mount(%{"run_id" => run_id}, _session, socket) do
  {machine, initialize_opts, events} = MyApp.Runs.load_log!(run_id)

  {:ok, messages} =
    StatifierUI.Trace.Replay.from_events(machine, initialize_opts, events)

  {:ok, assign(socket, :trace, State.new(machine, messages: messages))}
end
```

It takes the compiled chart; the session options the recorded run was made
under, in `Statifier.Session.Recording.new/3`'s vocabulary (`:session_id`,
`:trace`, `:datamodel`, `:max_macrostep_rounds`, `:routes`, `:invoke_types`,
`:invoke_handlers`); the persisted log, as
`t:Statifier.Session.Recording.entry/0` values in the session's serialized
input order; and its own emission options: `:source`, `:fixtures`,
`:parent_session`, `:invokeid`, `:projection` and `:otel_context`, which are
the subscriber's emission options and no others. There is no `:capacity`, no
`:listeners` and no `:name` - a buffer, a fan-out and a process name are
process concerns, and this is a function.

Two things about the contract decide what a host has to store:

- **`:trace` has to be true in the recorded options.** A recording defaults
  the flag to `false`, and a run made without it completes normally while
  emitting no `trace.*` messages at all, so the producer refuses rather than
  hand back a stream the recorded run never produced:
  `{:error, {:initialize_opts, :trace_disabled}}`.
- **It fails closed.** The first failure returns `{:error, reason}` and no
  partial list, because a partial list returned as `{:ok, messages}` cannot
  be told apart from a whole one. `:session_id` has to be a binary
  (`{:initialize_opts, :missing_session_id}`), an entry shape it does not
  know is `{:unknown_entry, entry}`, and whatever the engine's replay, the
  manifest builder or the normalizer returns comes back unwrapped.

### Which stored row becomes which entry

`t:Statifier.Session.Recording.entry/0` has six shapes, one per kind of input
a session can be driven by. A host that stores its log as rows rather than as
a `Statifier.Session.Recording.to_binary/1` blob has to map each row back to
one of them, and this table is that mapping:

| What the row recorded | Entry shape | What the row has to carry |
|---|---|---|
| An external event delivered to the session | `{:event, event, routes}` | the `Statifier.Event` |
| An external event one of this session's own `<invoke>`s delivered | `{:invoked_event, invoke_id, event, routes}` | the id of the **invocation that delivered it**, which is not `event.invokeid` |
| The session being cancelled | `{:cancel, routes}` | nothing but the marker; `<onexit>` runs from it |
| A delayed `<send>` firing | `{:timer, send_id, event, routes}` | the `send_id` (`nil` for an unnamed send) and the delivered event |
| One `interpret/2` batch | `{:interpret, effects, routes}` | the `[Statifier.Effect.t()]` of that batch, whose boundary is the entry |
| An internal or platform event raised into the session | `{:internal, kind, name, origin, opts, routes}` | `kind` is `:internal` or `:platform`; `origin` is the raising element |

`routes` is the last element of every shape: the `Statifier.Send.Routes`
snapshot in force for the drive that row triggered, or `nil`. Store the
snapshot if the run had one worth distinguishing - sends aimed at other
sessions, a parent, or an invocation. `nil` means the session-start
snapshot, which is what a single-session run has for its whole life.

Rows go into a `Statifier.Session.Recording` through
`StatifierUI.Trace.Replay.recording/3`, which is the same fold
`from_events/4` runs and returns the recording itself - for
`Statifier.Replay.run/1`, for `to_binary/1`, or to compare against one you
already hold:

```elixir
entries = Enum.map(rows, &MyApp.Runs.to_entry/1)

{:ok, recording} =
  StatifierUI.Trace.Replay.recording(machine, initialize_opts, entries)
```

An unrecognized shape is `{:error, {:unknown_entry, entry}}` from either
function, never a skipped row.

### A fired timer is `{:timer, ...}`, not `{:event, ...}`

The engine delivered an ordinary external event when the delayed send fired,
so a stored row can look like either one. It has to be named `{:timer,
send_id, event, routes}`, because the `send_id` is what the replay matches
on: each recorded `<send>` with a delay becomes a pending-timer **credit**
under its `send_id`, and only a `{:timer, ...}` entry draws one.

Naming the firing as an event skips that matching entirely, and two things
follow. The replay stops checking: a firing the chart never scheduled is
accepted instead of returning
`{:error, {:unscheduled_timer_firing, send_id}}`. And the credit the firing
should have spent stays outstanding, where a later cancel of the same
`send_id` moves it to the raced pool and a subsequent firing can still draw
it - so a run with a cancel replays differently from the one that was
recorded.

A single firing with nothing after it produces the same message stream under
either name, which is why this is worth stating rather than leaving to be
discovered by the run where it matters.

What comes out is the same list `StatifierUI.Trace.Subscriber` produces from
a live session: the same message types in the same order, with the same
`seq` values and the same payload bytes under
`StatifierUI.Trace.Json.encode_lines/1`. The one absence is
`session.terminated` - there is no process offline and no exit to observe,
so an offline stream ends where the entry list ends. Everything downstream
of `new/2` is unchanged, because it is the same message list the sections
above hand it.

## Laying it out yourself

`ops_view/1` is an arrangement, nothing more. A host that wants its own
composes the panes directly:

```heex
<div class="my-grid">
  <StatifierUI.Live.status id="run-status" state={@trace} />
  <StatifierUI.Live.scrubber id="run-scrubber" state={@trace} />
  <StatifierUI.Live.diagram id="run-diagram" state={@trace} />
  <StatifierUI.Live.event_log id="run-log" state={@trace} />
</div>
```

Inside a LiveComponent, pass `target={@myself}` to `scrubber/1` and
`event_log/1` so the events reach the component rather than the parent
LiveView. To namespace the events, pass `scrub_event=` and `select_event=`
and match your own names in `handle_event/3`.

## Rendering the diagram

`diagram/1` emits `StatifierUI.Diagram`'s Mermaid `stateDiagram-v2` source
into a `<pre class="mermaid">`, which is the shape a Mermaid client renders
in place. No Mermaid client ships here - the JavaScript this package does
ship is the hooks below, and nothing else - so attaching one is yours:

```heex
<StatifierUI.Live.diagram id="run-diagram" state={@trace} hook="Mermaid" />
```

```javascript
export const Mermaid = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    mermaid.render(`${this.el.id}-svg`, this.el.textContent)
      .then(({ svg }) => { this.el.innerHTML = svg })
  }
}
```

The element also carries the drawn configuration as `data-configuration` (a
space-separated list of the engine's document-order state indexes), so your
own code - or a test - can read what is highlighted without parsing Mermaid.

The same value is readable server-side: `StatifierUI.Live.State.configuration/1`
is the configuration the current selection implies, so a host that draws its
own diagram reads it in `render/1` and follows the scrubber without touching
the pane. It is the read behind `data-configuration`, not a second answer to
it.

ADR-0008's client-side elkjs SVG renderer is the eventual full-fidelity
diagram and is not built yet. When it is, it replaces this pane's body and
not its contract.

## The JavaScript, and the host pipeline that compiles it

This package's JavaScript ships as source and the host's own bundler
compiles it (ADR-0009). Nothing is precompiled and there is no
`priv/static` blob to serve.

The hex tarball carries `assets/package.json`, `assets/js/index.js`, and one
file per hook. The `file:` target is `assets/`, not the package root, because
that is the directory holding `package.json`. In your `assets/package.json`:

```json
"dependencies": {
  "statifier_ui": "file:../deps/statifier_ui/assets"
}
```

and in your `app.js`:

```javascript
import { StatifierUIHooks } from "statifier_ui"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { ...StatifierUIHooks }
})
```

`StatifierUIHooks` is every hook this package ships, keyed by the name its
component renders as `phx-hook`. Those names, and the export names beside
them, are public API with the same versioning obligations as an exported
Elixir function.

Three consequences worth knowing before you wire it up:

- **Your pipeline needs Node.** A host with no npm step at all cannot
  consume the hooks today. The components still render - every one of them
  degrades to a no-JavaScript affordance, and the expression field's is a
  native `<datalist>` - so a Node-free host gets working, unenhanced markup
  rather than a broken page.
- **`npm install` links, it does not copy.** `node_modules/statifier_ui` is
  a symlink into `deps/`, so a `mix deps.get` that moves the package version
  is picked up by the next bundle without a reinstall.
- **This repository never bundles.** Its toolchain is Node-free on purpose,
  so a compile error in the shipped JavaScript surfaces in your build, not
  in this package's gate. The Elixir side holds the boundary instead: the
  hook name and the `data-*` payload each hook reads are asserted in tests,
  and `test/packaging_test.exs` fails if a file under `assets/` is not in the
  published `files:` list.

## Styling and theming

No CSS ships, and no component reads a CSS custom property, a `data-theme`,
or a `prefers-color-scheme` of its own. That is the theming contract rather
than a gap in it: every element carries a `statifier-ui-*` class and the
engine's own document-order identities as `data-*` attributes, per ADR-0007's
sync contract, and your stylesheet is the only thing that gives any of them a
colour. A package that shipped its own tokens would have a palette to
reconcile with yours; this one has none to reconcile.

So a theme switch is yours end to end. Define your tokens wherever you
already define them, redefine them under whatever your app scopes a theme
with, and reference them from these selectors:

```css
:root { --app-fg: #1a1c1f; --app-line: #d6d9de; --app-accent: #2563eb; }
:root[data-theme="dark"] { --app-fg: #e7e9ee; --app-line: #2c3138; --app-accent: #7aa2f7; }

.statifier-ui-ops-view { color: var(--app-fg); border: 1px solid var(--app-line); }
.statifier-ui-scrub-button[data-move="live"] { color: var(--app-accent); }
```

The selectors that carry a state worth branching on:

| Selector | What it is |
| --- | --- |
| `.statifier-ui-ops-view` | the composed view |
| `.statifier-ui-panes` | the diagram/log pair |
| `.statifier-ui-status[data-status]` | `persisted`, or the subscriber's status |
| `.statifier-ui-projection` | the ADR-0012 redaction banner |
| `.statifier-ui-scrub-button[data-move]` | `first`, `prev`, `next`, `live` |
| `.statifier-ui-selection-note[data-resolution]` | `live`, `quiescent`, `carried`, `before_first` |
| `.statifier-ui-diagram-source[data-configuration]` | the Mermaid source |
| `.statifier-ui-macrostep details[data-macrostep][data-selected]` | one run-history entry |
| `.statifier-ui-round[data-round]` | one round inside a macrostep |
| `.statifier-ui-field[data-field]` | `selected`, `exited`, `entered`, `cause`, `content`, `configuration`, `budget` |
| `.statifier-ui-expression` | the expression field's wrapper |
| `.statifier-ui-expression-input[data-hook]` | `attached` once the hook has upgraded the field; absent means the `<datalist>` fallback is what the reader has |
| `.statifier-ui-expression-input[data-vocabulary]` | `true` when the grammar half of the completion list resolved |

Two of the surfaces a host styles are built by the hook at runtime rather
than rendered by a component, so they appear in no HEEx template and are
easy to miss until the popup opens over an unstyled `<ul>`:

| Selector | What it is |
| --- | --- |
| `.statifier-ui-expression-popup` | the completion popup, appended to `<body>` rather than to the field |
| `.statifier-ui-expression-option[data-kind]` | one entry; `data-kind` is its completion kind |
| `.statifier-ui-expression-option.is-selected` | the entry the caret is on |
| `.statifier-ui-expression-option-label` | the completion text |
| `.statifier-ui-expression-option-kind` | its kind, as a word |
| `.statifier-ui-expression-option-detail` | the trailing detail, when the entry has one |

The remaining classes are structural and carry no state of their own:

`.statifier-ui-counts`, `.statifier-ui-diagnostic`, `.statifier-ui-diagram`,
`.statifier-ui-effect`, `.statifier-ui-effects`, `.statifier-ui-event-log`,
`.statifier-ui-log-error`, `.statifier-ui-log-footer`,
`.statifier-ui-log-session`, `.statifier-ui-log-truncated`,
`.statifier-ui-macrostep`, `.statifier-ui-macrostep-summary`,
`.statifier-ui-macrosteps`, `.statifier-ui-not-quiescent`,
`.statifier-ui-round-fields`, `.statifier-ui-round-header`,
`.statifier-ui-rounds`, `.statifier-ui-scrubber`, `.statifier-ui-session`,
`.statifier-ui-shown`, `.statifier-ui-status-kind`,
`.statifier-ui-status-line`.

With the tables above that is every class this package renders or builds.
Class names are as public as the hook names: a rename breaks a host's
stylesheet exactly the way it breaks its `app.js`.

**One thing here is not yours to theme.** `diagram/1`'s Mermaid source
carries a `classDef active` with literal fill, stroke, and text colours
(`StatifierUI.Diagram`), so the active-configuration highlight keeps its
light-mode palette under a dark host theme. It is inside the diagram source,
not in an attribute or a class, so no stylesheet reaches it. Overriding it
today means post-processing the source before handing it to your Mermaid
client, or theming the pane around it and accepting the highlight as-is.

## Rendering your own surfaces instead

**No host is locked into the shipped components.** Everything the panes above
draw, they draw from trace wire format v1 (`docs/wire-format.md`), which is a
published, language-neutral contract with a version on it. A host that reads
that stream and renders its own surfaces is a first-class consumer of this
package, not a host working around it.

This matters most where skinning runs out. A design system with its own
timeline component, a dashboard that wants one dense row per macrostep, a
native or non-Elixir client, a surface that has to match a chrome these
components cannot be argued into: in each case the answer is to render your
own, and the wire format is what makes that a supported path rather than a
fork.

The seam has three levels, and you can stop at whichever one you reach:

1. **Compose the panes yourself.** `ops_view/1` is one arrangement of
   `status/1`, `scrubber/1`, `diagram/1`, and `event_log/1`; see *Laying it
   out yourself* above.
2. **Keep the read model, drop the markup.** `StatifierUI.Live.State` and
   `StatifierUI.Inspector` are plain functions over the messages -
   `active_configuration/2`, `points/1`, `step/3`, `selection_note/2` - and
   they have no opinion about what renders their answers. Neither depends on
   LiveView.
3. **Take the messages and render from those.** `StatifierUI.Trace.Message`
   structs, or the JSON `StatifierUI.Trace.Json` decodes, are wire format v1.
   Nothing above them is required, and a client in another language reads the
   same stream.

Two obligations come with the third level, and they are the reasons the panes
behave the way *What the panes will not do* describes. A surface you render
yourself must not present a partial stream as whole - a truncated buffer, a
late attach, a failed catch-up, and an active ADR-0012 projection profile each
need to be visible - and it must not present a carried configuration as a
measured one. Both are properties of the data, not of these components: the
stream carries the diagnostics and the stamps that say which case you are in,
and a renderer that drops them is making a claim the engine never made.

## What the panes will not do

- **They never write.** No component sends an event to a session, and the
  scrubber never rewinds one. Selecting a past macrostep is a read of
  stamps the engine already wrote (statifier ADR-0034 replay via
  ADR-0002's inherited clause).
- **They never invent a configuration.** A macrostep still in flight has
  none of its own; the newest one at or below it is drawn and the note says
  which macrostep it was carried from. A carried configuration is never
  presented as a measured one.
- **They never present a partial stream as whole.** Buffer truncation, a
  late attach, a failed catch-up, and an active projection profile each get
  a visible line rather than a silent gap.
