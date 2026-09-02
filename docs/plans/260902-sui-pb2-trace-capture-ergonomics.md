# Trace capture ergonomics Implementation Plan

## Overview

`sui-pb2`. Make "record a trace from a live `Statifier.Session`, save it,
reload it in the inspector" one documented call each, and state the wire
format v1 round-trip normatively in `docs/wire-format.md`.

The trace stack today is a **producer only**. `StatifierUI.Trace.Json`
encodes and never decodes; nothing under `lib/` reads or writes a file of
trace messages; `StatifierUI.Trace.Message` has `to_map/1` with no inverse.
The three legs the bead names are therefore one new decoder, one new file
module, and one new Kino entry point over the pure folds that already exist.

## Current State Analysis

What exists, and what each leg is missing:

- **Record.** `StatifierUI.Trace.Subscriber` already does the work:
  `start_link(machine: ...)`, `attach(sub, session, catch_up: true)`,
  `messages(sub)`. But the only assembled form of that sequence is
  `test/support/trace/session_case.ex`, which is `elixirc_paths(:test)` and
  ships to nobody. A caller wanting a message list from a live session
  writes four lines and has to know which of three attach modes to pick.
- **Save.** `Json.encode_lines/1` is the serializer, and
  `golden_trace_test.exs:34-49` is the de-facto recipe: encode, then the
  caller does its own `File.write!`. JSON Lines is what the worked example
  in `docs/wire-format.md` shows and what `test/support/trace/two_state.jsonl`
  holds, but the document never specifies framing normatively.
- **Reload.** Nothing decodes. `docs/ops-embedding.md:101-102` already tells
  a host to call `StatifierUI.Trace.Json.decode/1` - **a function that does
  not exist**, so that section is currently unfollowable. The LiveView half
  already declares the destination (`StatifierUI.Live.State.new/2` takes
  `:messages`, a persisted wire-format v1 list); the Kino half has no
  counterpart to `Kino.inspect/3`, which takes only a live session pid.
  Every `StatifierUI.Inspector` fold is already pure over `[Message.t()]`.

Two constraints inherited rather than chosen:

- `docs/plans/260817-sui-t36.3-...md:225-228` forbids file IO inside the
  subscriber GenServer ("must never block"). The file leg lives in its own
  module, called from the caller's process.
- `test/statifier_ui/trace/wire_format_payload_schema_test.exs` parses
  `docs/wire-format.md` between the exact headings ``## `session.start` ``
  and ``## The nine `trace.*` schemas ``, and asserts the tables in that
  slice are exactly `contents data location payload states transitions`.
  New prose must go outside that slice.

Decisions worth stating, because each closes an alternative:

1. **The decoder is the exact inverse of `to_map/1`, and decodes no
   values.** `Message.payload` is documented as already-in-wire-shape, and
   `StatifierUI.DatamodelExplorer` calls `StatifierUI.Value.decode/1` itself
   at read time (its moduledoc at `:112-115` warns that decoding twice
   re-reads a decoded `Date` as a `$`-tagged map). Keeping the decoder
   value-blind is what makes `encode(decode(bytes)) == bytes` hold
   byte-for-byte against the checked-in golden, which is the round-trip
   claim the bead asks the document to carry.
2. **`Json.decode/1` is the name**, because `docs/ops-embedding.md` already
   committed to it in prose. This plan fixes a doc bug by implementing the
   function the doc cites, rather than by editing the doc to a new name.
3. **`inspect_trace/3` renders a static snapshot, not a scrubber.**
   Step-through controls over a persisted trace are `sui-2uz` by name.
   Building them here would take that bead's decision (what a datamodel
   diff between adjacent steps means) inside this one.
4. **No engine change and no dependency bump.** Everything used is on the
   locked `statifier 2.0.0` surface (`Session.subscribe/3` catch-up,
   `Statifier.Replay`, `Statifier.compile/1`). No `st-` gap was found.

## FILE MAP

New:

| Path | What |
|---|---|
| `lib/statifier_ui/trace/capture.ex` | `record/3`, `save/2`, `load/1` - the three one-liners; the only file IO in `lib/` for traces |
| `test/statifier_ui/trace/capture_test.exs` | record from a live session, save/load round-trip through a tmp file, error arms |
| `test/statifier_ui/trace/round_trip_test.exs` | `decode` then `encode_lines` byte-identical against `test/support/trace/two_state.jsonl` |
| `changelog.d/sui-pb2.md` | Added fragment |

Modified:

| Path | What |
|---|---|
| `lib/statifier_ui/trace/message.ex` | `from_map/1`, the inverse of `to_map/1`, splitting on `@reserved_keys` |
| `lib/statifier_ui/trace/json.ex` | `decode/1`, `decode_lines/1` |
| `lib/statifier_ui/kino.ex` | `inspect_trace/3` in the Kino arm and in the no-Kino fallback arm |
| `test/statifier_ui/trace/message_test.exs` | `from_map/1` cases (new file if absent) |
| `test/statifier_ui/trace/json_test.exs` | decode cases |
| `test/statifier_ui/kino_test.exs` | `inspect_trace/3` cases |
| `docs/wire-format.md` | a new `## Persistence and the v1 round-trip` section, placed after `## Worked example` and before `## Type index` - outside the payload-schema parser's slice |
| `docs/ops-embedding.md` | the `Json.decode/1` citation becomes true; add the `Trace.Capture.load/1` one-liner |

Untouched, and declared so a sibling rebase is cheap: every ADR;
`docs/wire-format.md` lines 312-527 (the `session.start` slice the
payload-schema test parses); `lib/statifier_ui/trace/subscriber.ex`;
`lib/statifier_ui/inspector.ex`; `lib/statifier_ui/live/state.ex`;
`mix.exs`; `mix.lock`.

## Phase 1 - the decoder

`StatifierUI.Trace.Message.from_map/1`:

```elixir
@spec from_map(map()) :: {:ok, t()} | {:error, term()}
```

Splits a decoded JSON object on `@reserved_keys`: the seven envelope keys
become struct fields, everything else becomes `payload`. Rejects a map
missing any of `type`, `session`, `seq` with
`{:error, {:missing_envelope_key, key}}`, and a `seq` that is not a
non-negative integer with `{:error, {:invalid_envelope_value, "seq", value}}`.
It does not touch payload values.

`StatifierUI.Trace.Json.decode/1` takes one JSON object as a string,
`JSON.decode/1`s it, and hands the result to `from_map/1`.
`decode_lines/1` splits on newlines, ignores blank lines (the trailing
newline `encode_lines/1` writes), decodes each, and returns
`{:ok, [Message.t()]}` or the first `{:error, {:line, n, reason}}`.

- Automated: `mix quality --profile loop` green. New `round_trip_test.exs`
  reads `test/support/trace/two_state.jsonl`, decodes it, re-encodes with
  `encode_lines/1`, and asserts the result is **byte-identical** to the file
  - the round-trip claim, proved against the same fixture the ADR-0005
  golden test byte-compares. Envelope/payload split asserted per message
  type (a `session.start` with no counters, a `trace.*` with all three).

## Phase 2 - record, save, load

`StatifierUI.Trace.Capture`:

```elixir
@spec record(session :: pid(), machine :: Machine.t(), opts :: keyword()) ::
        {:ok, [Message.t()]} | {:error, :not_recorded | term()}
@spec save([Message.t()], path :: Path.t()) :: :ok | {:error, term()}
@spec load(path :: Path.t()) :: {:ok, [Message.t()]} | {:error, term()}
```

`record/3` starts a subscriber over `machine` (forwarding `:source`,
`:fixtures`, `:capacity`, `:projection`, `:parent_session`, `:invokeid`),
attaches with `catch_up: true`, reads `Subscriber.messages/1`, stops the
subscriber, and returns the list. It returns `{:error, :not_recorded}` when
the subscriber's stats carry the `:not_recorded` diagnostic - the session
was not started `record: true`, so what came back would be a live-only
fragment silently missing the initialize burst. Passing `:source` is what
makes the capture self-describing and is what `load` + `inspect_trace`
need; the moduledoc says so at the option.

`save/2` writes `Json.encode_lines/1`'s output with `File.write/2`.
`load/1` is `File.read/1` then `Json.decode_lines/1`. Both are ordinary
functions in the caller's process - no GenServer, per plan 260817's rule.

- Automated: a recorded two-state session captured through `record/3`,
  saved to a `System.tmp_dir!` path, loaded back, and asserted equal to the
  captured list; `record/3` against a session started without `record: true`
  returns `{:error, :not_recorded}`; `load/1` on a missing path and on a
  malformed line return tagged errors.

## Phase 3 - reload into the inspector

`StatifierUI.Kino.inspect_trace(messages_or_path, fixtures \\ nil, opts \\ [])`
returns a static `Kino.Layout.t()`: a status line reading `persisted` with
the message count, the configuration diagram at the trace's live tip, the
datamodel explorer, and the event log. No injection pane (there is no
session to inject into) and no scrubber controls (`sui-2uz`).

The `Machine` comes from `opts[:machine]` when given, else from
recompiling the `source` the trace's own `session.start` message carries -
which is the round trip the wire format makes possible and the reason
`record/3` forwards `:source`. With neither, it returns an error rather
than rendering a diagram it cannot draw. A binary first argument is taken
as a path and run through `Capture.load/1`.

The no-Kino fallback arm gains the matching raising clause, so the module
still compiles with Kino absent.

- Automated: full `mix quality` green. `inspect_trace/3` over a message
  list with an explicit machine; over a saved file path; recompiling from
  the embedded source; the no-machine-no-source error; the no-Kino clause.

## Phase 4 - the document and the record

`docs/wire-format.md` gains `## Persistence and the v1 round-trip`,
inserted **after** `## Worked example` and **before** `## Type index`. It
states: JSON Lines is the file framing (one message object per line, UTF-8,
newline-terminated, no enclosing array); a stream is self-describing when
its `session.start` carries `source`; and the round-trip law -
for any conformant v1 stream, decoding to messages and re-encoding
reproduces the bytes, because encoding is canonical (lexicographic object
keys, producer array order) and decoding is envelope/payload structural
only. It names the golden fixture as the executable form of that claim.
No table is added, and nothing between lines 312 and 527 is touched.

`docs/ops-embedding.md`'s persisted-stream section stops citing a function
that does not exist and gains the `Capture.load/1` one-liner beside it.

Changelog fragment `changelog.d/sui-pb2.md` under `### Added`: the decoder,
the capture module, and the Kino entry point - public API additions a
released consumer can see.

- Automated: full `mix quality` green (the payload-schema and spec drift
  tests both still pass, proving the new section landed outside the parsed
  slice); `git diff origin/main -- docs/adr/` shows zero changed lines.

## Deferred Manual Verification

- That `inspect_trace/3`'s rendered panes **look** right in a real Livebook
  (the epic's own acceptance is a human's walk of
  `notebooks/inspector.livemd`; this adds a pane assembly to that surface).
  Machine-checkable here is the produced structure, not its appearance.
- Whether the `persisted` status wording reads well next to the live
  inspector's `attached`.
