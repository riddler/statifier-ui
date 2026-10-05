# Why the viewer speaks a wire format and not the engine

Every pane in this package - the diagram with its active states, the event log
by macrostep and round, the datamodel with what the last macrostep changed -
learns what happened from one thing: a list of trace messages in a documented
JSON shape. The diagram also draws the chart's shape from the compiled chart,
which can be rebuilt from the SCXML source the stream itself carries, but what
is active, what fired and what changed come only from the messages. No pane
reads the engine's effect structs. This page is about why the boundary sits there, what it costs, and what was
considered instead.

The examples follow one library loan through its life: a copy of a book lent
to a patron, renewed once, then due, and finally returned or lost.

## What the engine already offers

Statifier was built to be observed. At every phase boundary of its algorithm
it emits a trace effect - an event taken off the queue, the transitions
selected, the states exited and entered, the configuration stable at the end
of a macrostep - and it stamps each one with its macrostep, microstep and
round. Wherever an effect names a state or a transition it names it by index,
and the compiled chart keeps the tables that map each index back to a line
and column in the SCXML source.

When the loan's patron renews, then, the engine has already said everything a
viewer needs: `loan.renew` was dequeued and given its macrostep, the
self-transition on `on_loan` was selected, `on_loan` was exited and re-entered, `renewals`
went from 0 to 1, and the configuration settled on `on_loan` again. A viewer
is one more interpreter of those effects, the way a debugger client is one
more interpreter of a running program's events. That is why nothing in the
engine changes to support this package: when a viewer needs something the
engine does not yet say, the need is engine work, done in statifier and
not worked around from here.

The question this page answers is narrower than "should a viewer read the
trace". It is: in what form does the viewer read it?

## The tempting answer, and why it was refused

The cheapest viewer reads the engine's effect structs directly. They are
already in memory, already in the right order, and already typed. A first
inspector built that way works on day one.

The trouble arrives later, and quietly. Once a shipped viewer consumes the
structs, the contract between engine and viewer becomes "whatever the structs
happen to serialize to": Elixir atoms, sets, module names and tuples, shapes
that change whenever the engine's internals do. Nobody decides that contract;
it accretes. And it is a contract nothing outside the BEAM can meet. A viewer
written in another language, or an interpreter of SCXML written in another
language that wants to drive the same viewer, has no way to produce an
Elixir struct.

So the boundary was put in writing before the first pane shipped. The trace
is a language-neutral wire format, specified in its own document,
[the trace wire format](../wire-format.md), and that document is the
definition: Elixir structs, LiveView assigns, the Livebook frame and a file
of JSON lines are all carriers or producers of the format, never its
definition. When the document and the code disagree, the document is what
conformance means. Retrofitting a boundary like that under a viewer that has
already shipped is the expensive path; putting it in place while there was
one consumer was the cheap one.

## What the format carries, and why in that shape

A stream opens with one definition message, `session.start`, which carries
the chart's SCXML source and the identity tables: every state index with its
id and its location, every transition and content index with its location.
Everything after it is small. When the loan moves to `due`, the entry-set
message names the state by index, and a consumer resolves that index to
`due` and to the line it was written on through the tables it already
received. This is what lets a consumer with no SCXML compiler of its own
draw the chart and highlight where the execution stands.

The format is deltas at named boundaries, with the full configuration
restated only when the macrostep is stable. That mirrors what the engine
actually knows: it publishes the steps between stable points, not a fresh
snapshot after every event. A snapshot-per-event format would throw away the
phase structure the engine went to the trouble of emitting, and leave every
consumer to diff snapshots to recover it.

Ordering is explicit rather than inferred. Each message carries a per-session
`seq`, stamped where the stream is produced, and the counters order the
timeline. Nothing is promised about the order of two sessions' messages on a
shared channel, because nothing orders them: each session is its own process.
A loan that invokes a child session for an overdue notice produces two
streams, and the link between them lives in the data (the invoke id and the
parent named on the child's `session.start`), never in arrival order.

Values keep their meaning across the boundary. The datamodel's values are not
all native JSON - a due date is a `Date`, and "no event data" is different
from "event data that is null" - so the format spells the non-native ones as
small tagged objects and keeps absence distinct from null. Keys are written in
a fixed order, so two traces of the same execution are byte-for-byte
comparable. That last property is what makes a recorded trace usable as a
test: a chart, its example data and a script of events determine a trace, and
comparing the bytes is the conformance check.

Adding a field or a message type is not a version bump, because a consumer
must ignore what it does not recognize. A version bump is kept for changes a
consumer of the old version would misread.

## What the boundary buys

**Every pane is a function of the message list.** (The diagram adds the
compiled chart for its shape, and nothing else.) The Livebook inspector and
the LiveView components are two consumers of one format, so the same view of
the loan renders in a notebook, on a page in a host's admin screens, or as a
string in a test. A pane never has to know which of those it is in.

**A live session is not the only source.** Because the panes read messages
rather than a session, anything that can produce the messages can feed them.
The subscriber produces the stream from a live session. A pure function
produces the same stream from a persisted event log, with no process at all,
so a host that keeps its loans' event logs can render last month's lost copy
the same way it renders today's renewal. A saved file of JSON lines loads back
into the same panes.

**What leaves the host is decided in one place.** A support screen may show a
loan's status and due date but not the patron's name. Because every datamodel
value crosses the boundary at a known position in a known message, a
projection applied where the stream is produced can replace the withheld
values with a reserved redacted marker, while every identity, counter and
ordering field stays intact. The panes downstream never see the name and do
not need to be trusted with it.

**A second engine has a written cost of entry.** An interpreter in another
language that emits the definition message and the phase-boundary messages,
with their counters and identities, drives the same viewer without a line of
Elixir. It proves it does so by golden trace, not by reading this package's
code. This is also why the repository carries no language suffix: the format
is meant to outlive any one language binding, in the way a debug adapter
protocol serves many language back ends.

## What it costs

The boundary is not free, and the costs were accepted knowingly.

Every pane pays a serialization toll, even when the viewer runs in the same
process as the execution it watches. The definition message repeats things a
co-located consumer already holds - the source, the identity tables - and a
carrier may agree not to resend them, but the format's meaning may never
depend on that shortcut.

The vocabulary now lives in two places, the engine's effects and the
specification, and the two can drift. Golden traces are the alarm: an upstream
change to the engine's vocabulary fails them, and the change is taken up here
in the open rather than patched over.

The must-ignore rule makes forward compatibility cheap and debugging a little
harder: a consumer silently skips a message type it has never heard of,
including one whose name was mistyped. The vocabulary this package defines is
available as a list a host can hold and compare on upgrade, so an added type
is visible to a host that looks for it, but skipping the unknown is still the
rule.

The tagged encodings buy type fidelity at the price of a reserved shape: a
host map whose only key really is `"$date"` reads as a date. That collision
is rare enough to accept, and the reservation makes it the host's
specification violation rather than the viewer's silent misreading.

## The alternatives considered

**The engine's structs as the protocol.** Cheapest to start, and the failure
described above: a contract nobody chose, that no other language can meet.
Refused.

**An existing inspector protocol from the JavaScript statechart ecosystem.**
It is open and engine-agnostic, and its split into an actor announcement, an
event and a snapshot shaped the definition message and the stable-configuration
message here. But no engine outside JavaScript has ever spoken it, it has no
macrostep or round counters, no source locations and no SCXML vocabulary, and
its snapshot-per-event model discards exactly the phase structure statifier
emits. It survives as inspiration only.

**A binary or schema-compiled format.** A tighter wire, at the price of a
toolchain imported into every would-be interpreter, of traces nobody can read
by eye, and of golden-trace diffs. It would optimize a channel nobody has
measured as slow. JSON is also what the fixture files and the conformance
corpus already speak. Refused.

**The specification kept in the engine's repository.** The engine declares a
wire format outside its scope, and a format specified next to one engine reads
as that engine's serialization. Keeping it here keeps the language-neutral
claim honest; moving it to a shared specification home once a second
interpreter exists remains the expected path.

## Where to go next

- [The trace wire format](../wire-format.md) is the specification itself:
  every message type, every field, and the conformance rules.
- [Architecture](../architecture.md) places the boundary among the package's
  other layers.
- [How to observe an execution from a LiveView host](../guides/observe-an-execution.md)
  and [How to embed the ops view in a host LiveView](../ops-embedding.md) show
  the format at work on a host's own page.
- The reasoning in full is in the decision records, chiefly
  [ADR-0005](https://github.com/riddler/statifier-ui/blob/main/docs/adr/0005-language-neutral-trace-wire-format.md)
  (the format), [ADR-0012](https://github.com/riddler/statifier-ui/blob/main/docs/adr/0012-trace-projection-and-redaction.md)
  (projection) and [ADR-0017](https://github.com/riddler/statifier-ui/blob/main/docs/adr/0017-an-offline-producer-for-the-wire-format.md)
  (the offline producer).
