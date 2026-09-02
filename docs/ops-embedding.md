# Embedding the ops view in a host LiveView

This guide puts the read-only diagram and run-history event log on a page a
Phoenix host already has: an admin screen, a support tool, an incident view.
It covers both streams the components accept - a **live** session being
driven right now, and a **persisted** trace read back from storage.

These are dev/ops surfaces and they render everything the stream carries.
For a tenant-facing view, redact at the producer with an ADR-0012 projection
profile; the status pane then says so, and `sui-hmn` is the bead for a
component designed around redaction rather than one flagged into it.

## What you need

`:phoenix_live_view` is an optional dependency of `statifier_ui` (ADR-0004),
so a host that wants these components declares it itself:

```elixir
{:statifier_ui, "~> 0.2"},
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
in place. This package ships no JavaScript, so attaching that client is
yours:

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

ADR-0008's client-side elkjs SVG renderer is the eventual full-fidelity
diagram and is not built yet. When it is, it replaces this pane's body and
not its contract.

## Styling

No CSS ships. Every element carries a `statifier-ui-*` class and the
engine's own document-order identities as `data-*` attributes, per
ADR-0007's sync contract, so a host styles them with its own design system:

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
