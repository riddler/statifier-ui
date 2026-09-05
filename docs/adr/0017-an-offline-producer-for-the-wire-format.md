# ADR-0017: An offline producer for the wire format

Status: accepted (2026-09-05, campaign-030; proposed 2026-09-05, campaign-030)

Adds a **second producer** of the v1 trace wire format beside
`StatifierUI.Trace.Subscriber`: a pure function that turns a persisted
session event log into the same `%StatifierUI.Trace.Message{}` stream,
with no live `Statifier.Session`, no process, and no clock. No message
type is added, removed, or renamed; no field changes its type or its
meaning; the format version stays `1`. `docs/wire-format.md` gains no new
schema. Nothing in this record ships code - the module and its tests move
on `sui-97u`, filed already and blocked on this record; the
`docs/ops-embedding.md` section moves on `sui-dwr`.

## Context

### The need: a persisted log, and nothing live to subscribe to

Every producer this repository has today needs a running session. A
production host that persists its own session event log - because it
restarts, or because it stores runs for audit and wants to render them
later - has the inputs a run was driven by, the compiled chart, and the
options the session ran under, and no process. It cannot subscribe to
anything, because there is nothing left to subscribe to.

What it wants is the wire stream `docs/wire-format.md` specifies, over
that log, in a request handler or a background job. That is a producer
question, not a schema question: the format already has a normative home,
and the conformance rules at `docs/wire-format.md:17-27` are written for
"a conformant producer", plural by construction.

### The mechanism already exists, and it is trapped inside a GenServer

The catch-up attach path already replays a recording and emits the wire
stream from it. `StatifierUI.Trace.Subscriber` does exactly the four
steps this record is about:

- `lib/statifier_ui/trace/subscriber.ex:429-444` - `attach_catch_up/2`
  obtains a `Statifier.Session.Recording.t()` from the live session.
- `lib/statifier_ui/trace/subscriber.ex:447-467` - `replay_prefix/2` reads
  the session id out of `Recording.opts/1`, calls
  `Statifier.Replay.run/1`, emits the manifest, and folds the returned
  `stream` through `handle_statifier_message/3`.
- `lib/statifier_ui/trace/subscriber.ex:472-485` -
  `handle_statifier_message/3`'s three accepting clauses, one per
  `Statifier.Replay` message shape (a fourth clause at `:487-488` drops
  anything else).
- `lib/statifier_ui/trace/subscriber.ex:493-505` - `emit_manifest/1`, and
  `:517-528` - `emit_normalized/2`, and `:571-583` - `buffer_and_fanout/2`,
  the single chokepoint where OTel stamping, projection, buffering, and
  the `seq` increment happen.

Every one of those is `defp` on a `GenServer`, threaded through
`%State{}`, and reachable only from a `handle_call` that was handed a live
session pid. The logic an offline producer needs is written and tested;
what it is not is callable.

### What upstream actually offers, stated exactly

The bead's phrasing - "re-drives `Statifier.Replay` with `trace: true`" -
is right about the intent and imprecise about the mechanism, and the
imprecision is the kind that fails silently. Three facts govern the
implementation:

**`Statifier.Replay.run/1` is arity one, over a recording.** Its spec is
`run(recording :: Recording.t())`
(statifier `lib/statifier/replay.ex:216-220`). It takes no machine, no
options, and no event list as separate arguments. Everything it needs
arrives inside the recording.

**There is no `trace:` option on `Statifier.Replay`.** `:trace` is one of
the seven options `Statifier.Session.Recording.new/3` normalizes
(statifier `lib/statifier/session/recording.ex:231-247`), **defaulting to
`false`** at `:237`. `Replay.run/1` hands `Recording.opts/1` to
`Statifier.Interpreter.initialize/2`
(statifier `lib/statifier/replay.ex:265-269`, calling
`lib/statifier/interpreter.ex:261-264`), which passes them to
`Statifier.MachineState.new/2` - where the flag is actually read, at
`lib/statifier/machine_state.ex:536`, defaulting to `false` a second time.
A producer that omits it gets a run that completes successfully and emits
**no `trace.*` messages at all** - nine of the format's twenty-four types
missing, with nothing anywhere reporting a problem. `trace: true` belongs
in the initialize options, and the record says so because the failure mode
is silent.

**`Recording.t()` is `@opaque`**
(statifier `lib/statifier/session/recording.ex:177-182`). The producer
cannot build one from a struct literal; it builds one through the public
constructors - `new/3` at `:231-232`, then the six appenders: `put_event/3`
(`:254`), `put_invoked_event/4` (`:271`), `put_cancel/2` (`:288`),
`put_timer/4` (`:304`), `put_interpret/3` (`:316`), and `put_internal/6`
(`:341`). Those six are exactly the six shapes of
`Statifier.Session.Recording.entry/0`
(statifier `lib/statifier/session/recording.ex:167-176`), which is what
this record means by *events*.

### The parity surface is already an exact fit

`Statifier.Replay`'s stream element type is

    {:effect, Effect.t()} | {:unroutable, Effect.t()} | {:halted, halt_reason()}

(statifier `lib/statifier/replay.ex:174-176`), and
`StatifierUI.Trace.Normalizer.input/0`
(`lib/statifier_ui/trace/normalizer.ex:94-99`) is those three shapes plus
a bare effect. The replayed stream is already in the normalizer's
alphabet, with no adapter and no conversion, which is the fact this whole
decision rests on. `replay_prefix/2` relies on it today.

Position by position, what a second producer has to match:

| Position | Subscriber does it at | The offline producer's obligation |
|---|---|---|
| `session.start` opens the stream at `seq: 0` | `subscriber.ex:493-505`, calling `Manifest.build/3` (`manifest.ex:103-127`), which hardcodes `seq: 0` at `:123` - and then restamping it from the running counter at `subscriber.ex:502` rather than trusting it | same call, same `opts()` (`manifest.ex:80-85`), the manifest stamped with the fold's own starting counter, which is `0` |
| every subsequent message stamped `seq: n` | `subscriber.ex:571-583`, `seq + 1` per message reaching the chokepoint | a fold carrying the same counter, incremented at the same point |
| effects become messages | `subscriber.ex:517-528`, `Normalizer.normalize/2` (`normalizer.ex:149-150`) with a four-key `ctx` (`normalizer.ex:80-85`) carrying `machine` and `source` | identical `ctx`, so `error.location` resolves the same way |
| OTel stamp, then projection | `subscriber.ex:571-583` - `Otel.stamp/2` (`otel.ex:86`) *before* `Projection.project/2` (`projection.ex:306`) | the same order, for ADR-0013's reason: `otel` is in the never-projected set |
| `Message.validate/1` guards reserved keys | `message.ex:66-67`, reached through `Manifest.build/3` and the normalizer | unchanged - both are reached through the same calls |

### Three positions where parity cannot hold, and why

- **`session.terminated`.** `subscriber.ex:588-608` builds it by hand from
  the monitor `:DOWN` and nothing else. There is no process offline and no
  exit to observe, so the offline stream never carries it. This is not a
  gap to close: `docs/wire-format.md:891-901` describes the four lifecycle
  types as describing *the stream*, and an offline stream's end is the end
  of the entry list.
- **Capacity.** `StatifierUI.Trace.Buffer.push/2`
  (`lib/statifier_ui/trace/buffer.ex:52-61`) silently drops the oldest
  message past capacity, default `1000` (`subscriber.ex:146`).
  A function returning a list has no capacity and drops nothing; a long
  run costs memory instead of fidelity.
- **Diagnostics.** A normalize failure is counted, deduplicated, and
  logged by `subscriber.ex:545-556`, and the stream continues one message
  short. A pure function has no `stats/1` to carry that, which forces
  Decision 5 below.

### What would prove parity

`test/statifier_ui/trace/golden_trace_test.exs` compares a live run's
`Json.encode_lines/1` output (`lib/statifier_ui/trace/json.ex:66`) against
`test/support/trace/two_state.jsonl`, byte for byte. The golden was
captured through the early-attach path
(`test/support/trace/session_case.ex:29-36`), which starts the session
with `trace: true` and **no** `record: true` - so the fixture as it stands
is not directly replayable.

The round-trip proof therefore runs the same chart a second way: start it
with `trace: true, record: true` (the shape
`session_case.ex:63-69`'s `start_recorded!/2` already uses), take the
recording, feed `Recording.entries/1` and `Recording.opts/1` to the new
producer, encode, and compare against the same fixture. The two-state
chart carries no `<invoke>` and no `<send target="#_internal">`
(`golden_trace_test.exs:3-14`), which is what keeps the comparison a plain
byte comparison rather than a sorted or multiset one - and therefore what
makes it a parity proof rather than a weaker equivalence.

## Options considered

A second, log-shaped format is not among them. `docs/wire-format.md:5-15`
is the format's normative home and ADR-0005 settled that there is one; a
producer whose output a consumer had to branch on would make the wire
format's single-vocabulary claim false to buy nothing, since the log
already carries everything the existing vocabulary needs. It is named here
only so the record shows it was rejected rather than overlooked.

### Option A - a producer in statifier-ex

`Statifier.Replay` already owns the replay half. Statifier-ex could grow a
wire-format producer beside it and hand back messages.

For: one round-trip fewer at the boundary, and the module would sit next
to the recording types it consumes.

Against, and decisive on two independent limbs. **The wire format is this
repository's contract.** ADR-0005 places it here, `docs/wire-format.md` is
its normative home, and `docs/wire-format.md:874-901` fixes vocabulary
this repository owns; a producer upstream would put half the format's
implementations outside the repository that defines it, and every future
schema change would become a two-repo change. **And statifier-ex is
explicitly out of this campaign's scope** - no `st-` write is authorized -
so this option is not available even if it were preferable, which it is
not. ADR-0010's rule points the same way: the repository whose files
change owns the decision, and the files that change are the producer's,
which are here.

### Option B - a pure function in this repository (recommended)

`StatifierUI.Trace.Replay.from_events/4` builds a
`Statifier.Session.Recording` from the caller's machine, options, and
entries, calls `Statifier.Replay.run/1`, and walks the resulting stream
through the same `Manifest`/`Normalizer`/`Otel`/`Projection` chain the
subscriber walks.

For: the format's two producers live beside each other and move together;
the pure modules the subscriber already delegates to are reused verbatim,
so parity is structural rather than promised; a pure function is callable
from a request handler, a job, a test, and a Livebook cell with no
supervision tree; and the round-trip against the existing golden is a real
proof rather than a smoke test.

Against: it duplicates the fold `replay_prefix/2` performs - two call
sites of the same four-step chain, which can drift. Decision 3 is what
holds them together, and Open question **O-1** asks whether the subscriber
should later be refactored onto the new function.

### Option C - a headless `Subscriber`, or make its private chain public

Start the existing `GenServer` with no session, hand it the stream, and
read `messages/1`; or promote `emit_manifest/1`, `emit_normalized/2`, and
`buffer_and_fanout/2` to public functions and let a caller drive them.

For: zero duplication - literally the same code path, so parity is not
even a claim to make.

Against: it makes the wrong thing the reusable thing. The headless variant
buys a supervision tree, a mailbox, a `GenServer.call` per read, and the
bounded buffer's silent drop, for a computation that is a fold over a
list; it also drags in `status`, `session_pid`, `monitor_ref`, and the
attach modes, every one of which is meaningless offline. Promoting the
private chain is worse: it publishes three functions whose contract is
"thread this through `%State{}`", pinning the subscriber's internal
representation as public API to serve a caller that does not want a
process at all. The duplication Option B accepts is a fold; what Option C
avoids paying, it pays in surface.

## Decision

Recommended, pending the operator's flip. The Status line above stays
`proposed`.

### 1. Option B: `StatifierUI.Trace.Replay.from_events/4`

    @spec from_events(
            machine :: Statifier.Machine.t(),
            initialize_opts :: keyword(),
            events :: [Statifier.Session.Recording.entry()],
            opts :: keyword()
          ) :: {:ok, [StatifierUI.Trace.Message.t()]} | {:error, term()}

- `machine` - the compiled chart the log was produced over. The same
  argument `Manifest.build/3` takes, and the same one
  `Recording.new/3` takes.
- `initialize_opts` - the session options the recorded run was made under,
  in `Recording.new/3`'s normalized vocabulary: `:session_id`, `:trace`,
  `:datamodel`, `:max_macrostep_rounds`, `:routes`, `:invoke_types`,
  `:invoke_handlers`. `:session_id` is required, because every message's
  envelope carries it and `replay_prefix/2` already reads it from exactly
  here (`subscriber.ex:448`).
- `events` - the persisted log, in the session's serialized input order,
  as `Recording.entry/0` values.
- `opts` - the producer's own options, and they are the subscriber's
  emission options and no others: `:source`, `:fixtures`,
  `:parent_session`, `:invokeid` (forwarded verbatim to
  `Manifest.build/3`'s `opts()`, `manifest.ex:80-85`), `:projection`, and
  `:otel_context`. Deliberately absent are `:capacity`, `:listeners`, and
  `:name` - a buffer, a fan-out, and a process name are process concerns.

The module is `StatifierUI.Trace.Replay`, in
`lib/statifier_ui/trace/replay.ex`, beside `subscriber.ex`. The name
collides with `Statifier.Replay` under `alias`, which is intentional and
manageable: the implementing bead aliases the upstream one as
`alias Statifier.Replay, as: EngineReplay` at its single call site rather
than renaming the sui module to something that hides what it is.

### 2. The recording is built through the public constructors

`from_events/4` calls `Recording.new(machine, initialize_opts)` and then
folds `events` through the six `put_*` appenders, one clause per
`entry/0` shape, before calling `Statifier.Replay.run/1`. It never
constructs `%Recording{}` - the type is `@opaque`
(statifier `lib/statifier/session/recording.ex:177-182`) and building it
by hand would couple this repository to a struct upstream deliberately
closed.

Two consequences of that, both load-bearing:

- **`trace: true` is the caller's to supply, in `initialize_opts`,** and
  `Recording.new/3` defaults it to `false` (`:237`). Because a missing
  flag produces a silently `trace.*`-free stream, `from_events/4`
  **returns `{:error, {:initialize_opts, :trace_disabled}}` rather than
  defaulting the flag on**. Defaulting it would produce a stream the
  recorded run never produced, which is the opposite of parity; erroring
  says so at the call site.
- **An unrecognized entry shape is an error, not a skip.**
  `{:error, {:unknown_entry, entry}}`. `entry/0` has six shapes today and
  a seventh appearing upstream must not be dropped silently - the same
  reasoning `Normalizer.normalize/2` gives for `{:unknown_effect, tag}`
  (`normalizer.ex:144-147`).

### 3. Parity with the `Subscriber` is the contract

The contract this record fixes is not "produces valid wire messages". It
is: **for a run the subscriber could have observed live, `from_events/4`
produces the identical message sequence.** Identical types, identical
order, identical `seq` values, identical payload bytes under
`Json.encode_lines/1`, with `session.terminated` as the one documented
exception (Decision 4).

That is enforced structurally, not by promise: every message is built by
the same four calls the subscriber makes - `Manifest.build/3`,
`Normalizer.normalize/2`, `Otel.stamp/2`, `Projection.project/2` - in the
same order, with the same `ctx`. No message shape is constructed inside
the new module.

It is enforced mechanically by the round-trip test described in Context:
the same two-state chart, run live with `record: true`, replayed offline,
both encoded, both compared to `test/support/trace/two_state.jsonl`. A
divergence in either producer fails the same fixture, which is what makes
this a parity test rather than two independent goldens that can drift
apart.

### 4. What it does not do

Stated as a closed list, because "offline" is otherwise an invitation to
scope creep:

- **No live session.** It starts no `Statifier.Session`, holds no pid,
  monitors nothing, and subscribes to nothing.
- **No process of its own.** It is a plain function; there is no
  `GenServer`, no supervision requirement, and no mailbox.
- **No timers and no clock.** `Statifier.Replay` already converts
  `{:schedule, ...}` into a pending-timer credit rather than a real
  `Process.send_after/3` (statifier `lib/statifier/replay.ex:36-50`); a
  recorded firing is delivered at its recorded position and nowhere else.
  Wall-clock time never enters, which is what makes the function
  deterministic.
- **No `session.terminated`.** Per Context: it has no exit to observe.
  `session.halted` is unaffected - it comes from a `{:halted, reason}`
  stream element and is produced normally.
- **No capacity, no fan-out, no diagnostics counter.** No dropped
  messages, no listener sends, no `stats/1`.
- **No write to statifier-ex.** Nothing upstream changes; `Replay`,
  `Recording`, and `Interpreter` are consumed exactly as published.
- **No schema change, and no `docs/wire-format.md` edit at all.** The
  conformance rules at `docs/wire-format.md:17-27` are already written for
  "a conformant producer" generically, so a second one needs no sentence
  added to make it conformant. That file is `sui-u6r`'s this campaign
  (ADR-0014's error-object table), and `sui-97u`'s own acceptance criteria
  require it unchanged. A courtesy mention naming the second producer is a
  separate bead if anyone wants one; it is not this decision's, and not
  `sui-97u`'s.

### 5. Errors are values, and the call fails closed

The subscriber continues past a `Manifest.build/3` or
`Normalizer.normalize/2` failure and records a diagnostic
(`subscriber.ex:501-504`, `:545-556`). `from_events/4` does the opposite:
the first failure returns `{:error, reason}` and no partial list.

The reasoning is that the two callers can do different things about it. A
subscriber that gave up on one bad effect would lose a live stream it can
never recover; a diagnostic plus a shorter stream is the better trade when
the alternative is nothing. An offline caller has the log still in hand
and can retry, report, or investigate - and a partial list returned as
`{:ok, messages}` would be indistinguishable from a whole one, which is
precisely the silent-incompleteness failure the subscriber avoids by
carrying `stats/1` alongside its buffer. Fidelity a `{:ok, _}` cannot
qualify has to be complete.

This is a deliberate, named divergence from Decision 3's parity, and the
only one on the error path. Open question **O-3** asks whether a
diagnostics-carrying variant is wanted later; nothing here forecloses one.

### 6. The format version stays `1`

`docs/wire-format.md:32-36` reserves a bump for a change that would make a
consumer of the previous version misread the stream. This record adds no
type, removes no type, adds no field, and changes no field's meaning; it
adds a *producer*. A consumer cannot distinguish the two producers'
output, which is the whole point of Decision 3. There is nothing for the
bump test to bite on.

### 7. `sui-97u` implements it, `sui-dwr` documents it

The split follows ADR-0014's precedent: the record decides, a separate
bead ships. `sui-97u` (already filed, blocked on this record) writes the
module, the round-trip test, and the `changelog.d/` fragment; `sui-dwr`
adds the host-facing section to `docs/ops-embedding.md`. This pull request
merges at `proposed`; a separate pull request flips the status to
`accepted` once the implementation has landed and the claims above have
been checked against the code that landed rather than the code this record
read.

## Implementation

Not in this pull request. On acceptance, `sui-97u` moves these together:

1. `lib/statifier_ui/trace/replay.ex` - the new module: the six-clause
   entry fold, the `trace: true` guard, the `Statifier.Replay.run/1` call,
   and the manifest-then-stream fold with the `seq` counter and the
   stamp/project chokepoint in the subscriber's order.
2. `test/statifier_ui/trace/replay_test.exs` - the unit tests: each entry
   shape, the `:trace_disabled` and `:unknown_entry` errors, an
   `{:error, {:unscheduled_timer_firing, _}}` passed through from
   upstream, and the `opts` pass-through for `:source`/`:fixtures`/
   `:parent_session`/`:invokeid`.
3. `test/statifier_ui/trace/replay_test.exs`, same file - the round-trip
   case: the same chart recorded, replayed offline, encoded, compared to
   `test/support/trace/two_state.jsonl`. It lives beside the unit tests
   rather than in `golden_trace_test.exs` because `sui-97u`'s acceptance
   criteria put it there, and because the existing golden test is a
   single-producer conformance test this one must not perturb.
4. `test/support/trace/session_case.ex` - a helper returning the recording
   from a `start_recorded!/2` session, if the round-trip case needs one
   the existing helpers do not give it.
5. A `changelog.d/` fragment, since a public function is added.

`docs/wire-format.md` and `docs/ops-embedding.md` are both deliberately
absent from that list: the first is `sui-u6r`'s and needs no edit (Decision
4), the second is `sui-dwr`'s.

## Consequences

- A host with a persisted event log can render, diff, or re-inspect a run
  it is no longer running, with no session to start and no supervision
  tree to stand up.
- The wire format acquires a second producer, and with it the obligation
  to keep two in step. The round-trip test against the shared golden is
  what discharges it; adding a third producer later would inherit the same
  fixture and the same obligation.
- `docs/wire-format.md:17-27`'s conformance language stops being
  hypothetical. It has been written for multiple producers since ADR-0005
  and has had one; the paragraph now describes something real.
- The subscriber's catch-up path becomes visibly duplicative. It is left
  alone deliberately (**O-1**): refactoring a live, tested path onto a new
  module in the same bead that introduces the module trades a real risk
  for a tidiness gain.
- The offline producer holds the whole message list in memory, where the
  subscriber holds at most `capacity`. A long recording costs proportional
  memory - acceptable for a function whose caller chose to materialize a
  list, and worth naming because the subscriber's bound does not apply.
- A recorded run must have been recorded with `trace: true` to produce a
  full stream, and Decision 2 makes that a loud error rather than a quiet
  nine-types-short one. Hosts that record without tracing get a clear
  message about a decision made at record time, not at replay time.
- This repository takes on no dependency it did not have.
  `Statifier.Replay`, `Statifier.Session.Recording`, and
  `Statifier.Interpreter` are all consumed today through the same pinned
  release.

## Open questions

- **O-1.** Should `StatifierUI.Trace.Subscriber`'s `replay_prefix/2`
  (`subscriber.ex:447-467`) later be refactored to call
  `from_events/4`? The two folds would then be one, and drift between the
  producers would become impossible rather than merely tested for. The
  obstacle is that the subscriber threads its fold through `%State{}` and
  needs the intermediate `seq` and diagnostics, so the shared function
  would have to return more than a list. Not decided here, and not
  `sui-97u`'s scope.
- **O-2.** Should `from_events/4` gain a sibling that takes a
  `Recording.to_binary/1` blob directly
  (statifier `lib/statifier/session/recording.ex:396-397`,
  `from_binary/1` at `:440-446`)? A host that persisted the blob rather
  than its own entry list would then not have to decode it first. It is
  strictly additive and can be added whenever a caller wants it; naming it
  now is what keeps `from_events/4`'s argument list from being widened
  speculatively.
- **O-3.** Should there be a variant that returns diagnostics alongside a
  partial stream, matching the subscriber's continue-and-record behaviour
  rather than Decision 5's fail-closed one? No caller wants it today. If
  one appears, it is a new function with its own return shape, not a flag
  on this one.
- **O-4.** Does the round-trip test need a second, richer chart? The
  two-state golden exercises ten message types out of twenty-four - eight
  of the nine `trace.*` types, plus `session.start` and
  `session.datamodel` - and no `<invoke>` or internal-send path. A parity proof over the narrow chart
  proves the mechanism, not the whole vocabulary. Widening it means either
  a second golden or a `(macrostep, round)`-sorted comparison
  (`golden_trace_test.exs:3-14`), and that is a decision for whoever needs
  the coverage.

## Notes

- The implementing bead is `sui-97u`; `sui-dwr` carries the host-facing
  documentation. The record-then-implement split follows **ADR-0014**'s
  precedent.
- Related decisions in this repository: **ADR-0005** (the format and its
  versioning rule), **ADR-0010** (the repository whose files change owns
  the decision - the ground Option A is rejected on), **ADR-0012**
  (projection, whose profile this producer forwards unchanged), and
  **ADR-0013** (the `otel` key, whose stamp-before-project order this
  producer copies).
- Cites resolve against statifier 2.0.0 as pinned in `mix.lock:29` and
  vendored at `deps/statifier/` (`deps/statifier/mix.exs:4`); sui cites
  resolve against this branch's `main`.
