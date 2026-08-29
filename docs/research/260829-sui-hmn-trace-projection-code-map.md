---
date: 2026-08-29T08:48:40-0600
researcher: Claude
git_commit: d566de026c73cca444f66cad935610c44e096e5d
branch: sui-hmn-trace-projection
repository: statifier-ui
beads_issue: sui-hmn
topic: "Where a trace projection/redaction mode (ADR-0012) lands in the code: the producer seam, the value positions, the consumer blast radius, and the test surface"
tags: [research, codebase, wire-format, trace, projection]
status: complete
last_updated: 2026-08-29
last_updated_by: Claude
---

# Research: the code map for ADR-0012's trace projection mode (sui-hmn)

**Date**: 2026-08-29T08:48:40-0600
**Git Commit**: d566de026c73cca444f66cad935610c44e096e5d
**Branch**: sui-hmn-trace-projection
**Bead**: sui-hmn (gated by the closed design bead sui-bur; ADR-0012 accepted 2026-08-26)

## Research Question

ADR-0012 is accepted and its Decision section is the contract. This document
is a code mapping, not a design pass. It answers: where exactly does the
producer-side transform attach, what is the exact payload key path for each
of the 15 rows in the ADR's closed position table, what shape does
`session.start` have and where would a `projection` object sit, what would
each shipped consumer do today if it met `{"$redacted": true}`, what has to
change in the value codec, how does the existing drift and golden test
machinery work, and where does `docs/wire-format.md` grow.

## Summary

The seam ADR-0012 names is real and it is a single function.
`StatifierUI.Trace.Subscriber.buffer_and_fanout/2` is the only place a
`%StatifierUI.Trace.Message{}` reaches a listener or the buffer, and it has
exactly three callers: the manifest emission, the normalized-effect path, and
the `session.terminated` path built on a monitor `:DOWN`. Every message in the
system passes through those three call sites and no others.

The 15 position rows land on 13 distinct payload key paths plus one recursive
wrapper (`session.unroutable`) and one list-of-entries case
(`effect.budget_exhausted`). Nine of the rows sit behind a conditional
`put_defined/3`, `put_value/3`, or `put_present/3`, so a projection that
writes a sentinel unconditionally would create keys that were absent, which
is the exact failure the ADR's absence discussion exists to prevent. The rule
is uniform: project only where the key already exists in the built payload.

The consumer blast radius is smaller than the ADR's prose implies, and it is
mostly a decode problem rather than a rendering problem.
`StatifierUI.Value.decode/1` rejects `{"$redacted": true}` with
`{:error, {:unknown_tag, "$redacted"}}`, and
`StatifierUI.DatamodelExplorer` turns that error into the value `:undefined`
plus a diagnostic - so today the datamodel pane would show a projected value
as unbound, which is precisely the lie ADR-0012's Context names. Two other
consumer sites are worse than "renders a literal map": `effect.log`'s `value`
is rendered with `inspect/1` into a markdown line, and `session.terminated`'s
`reason` is string-interpolated, which raises on a map. Two consumer
affordances the ADR asks to be disabled do not exist in the shipped code at
all: there is no in-place datamodel value editing, and event-injection
payloads are seeded from the fixtures bundle, never from observed trace
values. Both are recorded as open questions rather than resolved here.

## Detailed Findings

### 1. The producer seam

**`buffer_and_fanout/2` is the single choke point. Confirmed.**

- [`lib/statifier_ui/trace/subscriber.ex:486-491`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L486-L491) - the function. It sends
  `{:statifier_ui, session, message}` to every listener, pushes onto the
  bounded buffer, and increments `seq`. Both effects on the outside world -
  the listener send and the buffer push - happen here and only here.
- Its three callers, and there are no others in the module:
  - [`lib/statifier_ui/trace/subscriber.ex:435`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L435) - the `session.start` manifest
    emission inside `emit_manifest/1`.
  - [`lib/statifier_ui/trace/subscriber.ex:454`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L454) - the normalized-effect path
    inside `emit_normalized/2`, which is where every `trace.*`, `effect.*`,
    `session.halted`, `session.datamodel`, and `session.unroutable` message
    arrives.
  - [`lib/statifier_ui/trace/subscriber.ex:510`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L510) - the `session.terminated`
    path inside `handle_down/2`, which builds a `%Message{}` by hand rather
    than through the normalizer.
- Every inbound path funnels into those three. The live message path is
  `handle_info/2` at [`lib/statifier_ui/trace/subscriber.ex:307-321`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L307-L321) ->
  `handle_statifier_message/3` at `:404-421` -> `emit_normalized/2`. The
  catch-up replay path is `attach_catch_up/2` at `:361-377` ->
  `replay_prefix/2` at `:379-400`, which calls `emit_manifest/1` at `:385`
  and then folds the replayed prefix through the same
  `handle_statifier_message/3` at `:386`. So a projection at
  `buffer_and_fanout/2` covers the replayed prefix as well as the live
  suffix, with no second site.
- Nothing else in the module reaches a listener or the buffer. Reads
  (`handle_call(:messages, ...)` at `:293`, `handle_call(:stats, ...)` at
  `:295`) go through `Buffer.to_list/1` and `build_stats/1`; they never
  construct a message.

**Where the per-session profile is stored.** `State` is defined at
[`lib/statifier_ui/trace/subscriber.ex:114-158`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L114-L158) - a private nested module with
`@enforce_keys [:machine, :capacity, :buffer]` at `:140` and a `defstruct`
at `:141-157`, with a matching `@type t` at `:120-138`. The profile is a
per-session, set-once producer input, which is the same shape as `:source`,
`:fixtures`, `:parent_session`, and `:invokeid`: each is a struct field
populated once and never mutated.

**Where it enters.** `start_link/1` at
[`lib/statifier_ui/trace/subscriber.ex:180-185`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L180-L185) splits `:name` off and passes
the remaining keyword list to `init/1`. `init/1` at `:246-261` is the single
site that reads options onto the struct: `:capacity` at `:247`, then
`:source`, `:fixtures`, `:parent_session`, `:invokeid`, `:listeners` at
`:250-256`. A profile option would be read there, alongside them. The
docstring listing the accepted options is at `:162-179`.

Note that `Statifier.Session.start_link/2` takes the subscriber's pid in its
`:subscribers` list before the subscriber ever attaches (moduledoc at
`:10-28`), so a profile chosen at `start_link/1` time is in place before the
first message can arrive, including on the early-attach path that sees the
initialize burst.

### 2. The value positions in the produced payloads

The table below gives the exact key path in the map the producer builds, the
line that builds it, and the absence rule guarding it. "Payload" means the
`payload` field of the `%Message{}`; the envelope keys are merged over it
only at [`lib/statifier_ui/trace/message.ex:83-91`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/message.ex#L83-L91) and never carry values.

The three-way absence rule lives at
[`lib/statifier_ui/trace/normalizer.ex:550-589`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/normalizer.ex#L550-L589):

- `put_defined/3` (`:558-565`) - `:undefined` omits the key; `nil` is kept
  and encodes to JSON `null`. Used only where the engine genuinely
  distinguishes unbound from a stored null.
- `put_value/3` (`:573-581`) - both `nil` and `:undefined` omit the key.
- `put_present/3` (`:586-589`) - the same two omit, and no value encoding
  happens at all. Used for identifiers and flags, not values.

| # | Message | ADR position | Payload key path | Built at | Absence rule |
|---|---|---|---|---|---|
| 1 | `session.datamodel` | every value in `datamodel` | `payload["datamodel"][<var name>]` | `normalizer.ex:387-391` | `"datamodel"` always present; the whole map goes through `Value.encode/1` at `:388` |
| 2 | `effect.datamodel_change` | `new_value` | `payload["new_value"]` | `normalizer.ex:269` | `put_defined/3` - **conditionally absent** |
| 3 | `effect.datamodel_change` | `prior_value` | `payload["prior_value"]` | `normalizer.ex:270` | `put_defined/3` - **conditionally absent** (absent is the common case on a first write) |
| 4 | `trace.event_dequeued` | `event.data` | `payload["event"]["data"]` | `normalizer.ex:196-201`, via `event/1` at `:415-429`, key put at `:418` | `put_defined/3` - **conditionally absent**; `payload["event"]` itself is always present here |
| 5 | `trace.transitions_selected` | `event.data` | `payload["event"]["data"]` | `normalizer.ex:203-209`, via `put_event/2` at `:431-438` and `event/1` at `:418` | `put_defined/3` on `data`, and **`payload["event"]` is itself conditionally absent** (`put_event(map, nil)` at `:432`) - an absent `event` key is the eventless-round signal, documented at [`docs/wire-format.md:186-194`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/wire-format.md#L186-L194) |
| 6 | `trace.finalize_autoforward` | `event.data` | `payload["event"]["data"]` | `normalizer.ex:246-251`, `event/1` at `:418` | `put_defined/3` - **conditionally absent** |
| 7 | `trace.done` | `donedata` | `payload["donedata"]` | `normalizer.ex:236` | `put_value/3` - **conditionally absent** |
| 8 | `effect.done` | `donedata` | `payload["donedata"]` | `normalizer.ex:288` | `put_value/3` - **conditionally absent** |
| 9 | `effect.autoforward` | `event.data` | `payload["event"]["data"]` | `normalizer.ex:327-337`, `event/1` at `:418` | `put_defined/3` - **conditionally absent** |
| 10 | `effect.budget_exhausted` | `data` on each `pending_internal_events` entry | `payload["pending_internal_events"][i]["data"]` for every `i` | `normalizer.ex:293-303`, list built by `event_list/1` at `:397-410`, each entry by `event/1` at `:418` | the list key is always present; **each entry's `data` is independently conditionally absent** under `put_defined/3` |
| 11 | `effect.log` | `value` | `payload["value"]` | `normalizer.ex:279` | `put_value/3` - **conditionally absent** |
| 12 | `effect.invoke` | `params` | `payload["params"]` | `normalizer.ex:316` | `put_value/3` - **conditionally absent** |
| 12b | `effect.invoke` | `content` | `payload["content"]` | `normalizer.ex:317` | `put_value/3` - **conditionally absent** |
| 13 | `effect.send` | `data` | `payload["data"]` | `normalizer.ex:346` | `put_value/3` - **conditionally absent** |
| 13b | `effect.send_delayed` | `data` | `payload["data"]` | `normalizer.ex:364` | `put_value/3` - **conditionally absent** |
| 14 | `session.unroutable` | every value position of the nested effect, recursively | `payload["effect"][<the inner type's own key path>]` | `normalizer.ex:131-142` | `payload["effect"]` always present; the inner paths keep their own absence rules |
| 15 | `session.start` | `fixtures`, replaced whole | `payload["fixtures"]` | `manifest.ex:88` | `put_present/3` at `manifest.ex:233-235` - **conditionally absent** when the host supplied none |
| 16 | `session.terminated` | `reason`, replaced whole | `payload["reason"]` | `subscriber.ex:505` | always present; a plain string built by `inspect/1`, never encoded through `StatifierUI.Value` |

Additional position, not in the table but decided by the ADR's
`allow_source` clause: `session.start`'s `source` is
`payload["source"]`, built at `manifest.ex:87` under `put_present/3` -
**conditionally absent**.

**The absence discipline this implies.** Nine of the sixteen rows above are
conditionally absent. A projection must therefore be written as "replace the
value at a key that exists", not "put the sentinel at this key". The three
paths that need it most:

- Row 5: writing `payload["event"]` into a `trace.transitions_selected`
  message that had none would convert an eventless round into an evented one.
- Row 3: writing `payload["prior_value"]` where it was absent would assert
  that something stood at the location before a first write.
- Row 15: writing `payload["fixtures"]` where the host supplied none would
  assert that a bundle existed. ADR-0012 states this explicitly ("A host that
  supplied no fixtures still omits the key, as today").

**`session.unroutable` needs recursion, not outer pattern matching.**
`normalize({:unroutable, effect}, ctx)` at `normalizer.ex:131-142` calls the
same `decompose/1` every other effect goes through (`:132`), takes the inner
`type` string, and merges it into the inner payload under a `"kind"` key at
`:136`, then re-stamps `macrostep`/`microstep`/`round` into the same wrapped
map at `:137-139` before nesting the whole thing under `"effect"` at `:140`.
So the outer message type is always the string `"session.unroutable"` and the
inner type is only readable at `payload["effect"]["kind"]`. Because
`decompose/1` at `:177-191` also dispatches `{:datamodel_init, _}` to
`datamodel_message/1`, the wrapped kind can in principle be
`"session.datamodel"`, whose value path would then be
`payload["effect"]["datamodel"]`. A projection keyed on the outer `type`
alone would redact nothing here.

**`effect.budget_exhausted` needs a list walk.** The value is not at a fixed
key: it is `payload["pending_internal_events"][i]["data"]` for every entry
`i`. The list is built by `event_list/1` at `normalizer.ex:397-410`, which
maps `event/1` over `p.pending_internal_events`, so each entry is a full
event object with `name`, `type`, an optionally-present `data`, and the
optional `cause`/`invokeid`/`origin`/`origintype`/`sendid` fields from
`event/1` at `:420-426`. Only `data` is a value position; the rest is
identity.

**Nothing else in a payload is a value.** `location_path` on
`effect.datamodel_change` is emitted structurally, not through the codec, and
the comment at `normalizer.ex:259-262` says why: its segments are strings and
integers, and it is an identity like `c_index`. `cause` objects
(`normalizer.ex:449-460`), `origin` objects (`:462-496`), and `owner` objects
(`:498-526`) carry indexes only.

### 3. `session.start`'s shape

`StatifierUI.Trace.Manifest.build/3` is at
[`lib/statifier_ui/trace/manifest.ex:76-99`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/manifest.ex#L76-L99). It returns
`{:ok, %StatifierUI.Trace.Message{}}` or `{:error, term()}` - specifically
`Message.validate/1`'s result, called at `:92-97`, on a message with
`type: "session.start"`, `session: session`, `seq: 0`, and no envelope
counters (all three stay `nil`). The two error paths are
`{:error, {:invalid_source, other}}` from `validate_source/1` at `:101-104`
and `{:error, {:invalid_fixtures, other}}` from `validate_fixtures/1` at
`:106-109`.

The payload is built at `manifest.ex:79-90` in two stages:

```
%{
  "version" => @manifest_version,     # manifest.ex:81, the integer 1 (@manifest_version at :59)
  "states" => states(machine),        # :82  -> states/1 at :113-118
  "transitions" => transitions(...),  # :83  -> transitions/1 at :135-140
  "contents" => contents(machine),    # :84  -> contents/1 at :158-163
  "data" => data(machine)             # :85  -> data/1 at :196-201
}
|> put_present("source", source)                  # :87
|> put_present("fixtures", fixtures)              # :88
|> put_present("parent_session", ...)             # :89
|> put_present("invokeid", ...)                   # :90
```

So the four index tables are unconditional top-level payload keys, and the
four caller-supplied fields are conditional, all through the same
`put_present/3` at `:233-235`.

- `states` is a list of objects from `state_object/1` at `:120-131`:
  `index`, `kind`, `children`, `transitions`, `location`, plus optional `id`
  and `parent`. No value anywhere.
- `transitions` is from `transition_object/1` at `:142-154`: `t_index`,
  `source`, `targets`, `events`, `type`, `content`, `location`, plus optional
  `cond_location`. No value.
- `contents` is from `content_object/1` at `:165-172`: `c_index`, `kind`,
  `location`. No value.
- `data` is from `data_object/1` at `:203-211`: `d_index`, `id`, `location`,
  plus optional `value_location`. **No representation of the declared value**
  - which is why ADR-0012 says this table needs no rule. The
  `value_location` slicing residual the ADR records is real: it is a
  `location_object/1` (`:217-227`) with six integer offsets that index into
  `payload["source"]`.

**Where a `projection` object would sit.** Beside `source` and `fixtures`, as
a fifth conditional top-level payload key on the same `put_present/3` chain
at `manifest.ex:87-90`. It is a peer of `version` and the four tables, at the
same nesting level, and its absence means full fidelity (ADR-0012). The
producer input would have to reach `Manifest.build/3` through its `opts()`
type at `manifest.ex:52-57`, which is the same keyword list
`Subscriber.emit_manifest/1` assembles at `subscriber.ex:427-432`.

### 4. The consumer flow-through

#### 4a. `StatifierUI.DatamodelExplorer` - the big one

**The fold.** `build_live/2` at
[`lib/statifier_ui/datamodel_explorer.ex:170-201`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer.ex#L170-L201), whose reduce is at
`:177-180`. Its input is `live_writes/1` at `:423-428`, which filters
messages of type `"effect.datamodel_change"` and sorts them by
`{macrostep, microstep, seq}`. The fold body is `apply_datamodel_write/2` at
`:430-449`. The seed comes from the `session.datamodel` snapshot through
`seed_live_entry/3` at `:386-403`.

**How it reads values.** Two sites, both calling `StatifierUI.Value.decode/1`:

- `seed_live_entry/3` at `:387` decodes each raw value out of
  `payload["datamodel"]`.
- `decode_write_value/3` at `:451-474` does `Map.fetch(payload, key)` at
  `:453` for `"new_value"` / `"prior_value"` and decodes at `:458`.

**How it spells absence.** `Map.fetch/2`'s `:error` arm at `:453-455` yields
the bare atom `:undefined`. There is no dedicated `:__absent__` sentinel
anywhere in the module; `:undefined` is used uniformly for a key that was
absent, for a container never seeded (`as_map/1` and `as_list/1` at
`:570,575`), and for a root name never in the snapshot (`runtime_entry/1` at
`:416-419`).

**What it would do today with `{"$redacted": true}`.** This is the load-
bearing finding of this section:

1. `Value.decode(%{"$redacted" => true})` reaches
   [`lib/statifier_ui/value.ex:92`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/value.ex#L92) (a one-key map), takes the
   `["$" <> _rest = key]` branch at `:94`, and returns
   `{:error, {:unknown_tag, "$redacted"}}`.
2. `seed_live_entry/3`'s error arm at `:391-401` and
   `decode_write_value/3`'s error arm at `:462-471` both substitute the value
   `:undefined` and append an `:undecodable_datamodel_value` diagnostic.
3. The entry's `value` is therefore `:undefined`. `Shape.infer/1` at
   `:606` sees `:undefined`, and the markdown renderer at
   [`lib/statifier_ui/datamodel_explorer/markdown.ex:144`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer/markdown.ex#L144) prints
   `inspect(:undefined)`.

So a projected stream rendered through today's datamodel pane reports every
redacted slot as **unbound**, with only a diagnostic line (rendered at
`markdown.ex:158-164`) as the tell. That is exactly the failure ADR-0012's
Context describes for the omission alternative, arriving via the consumer
rather than the producer. It does not crash and it does not show a literal
map.

**Other value-touching sites in the explorer trio.**

- `apply_scenario_value/2` at `datamodel_explorer.ex:292-302` and
  `scenario_entry/1` at `:304-315` - authoring mode; reads already-decoded
  Elixir terms straight from a scenario map and never calls `Value.decode/1`.
  A `%{"$redacted" => true}` arriving on that path would flow through
  untouched and be rendered as a literal inspected map by `markdown.ex:144`.
- `apply_resolved_write/6` at `:476-519` and `apply_path/3` /
  `apply_list_index/4` / `as_map/1` / `as_list/1` at `:527-577` - materialize
  the location path into the decoded value tree.
- `finalize_live_entries/2` at `:604-619` - computes `shape` from
  `entry.value` at `:606`.
- `lib/statifier_ui/datamodel_explorer/entry.ex` - struct and types only,
  `:1-67`, with the `value` field documented at `:26-28`. No functions.
- [`lib/statifier_ui/datamodel_explorer/markdown.ex:139-147`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer/markdown.ex#L139-L147) - the render
  site; every value goes through `inspect/1` at `:144`, recursively for
  children at `:146`.
- [`lib/statifier_ui/datamodel_explorer/scope.ex:186-201`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer/scope.ex#L186-L201) reads system
  variable values from `SystemVariables.initial/2` and infers shapes at
  `:195`; `build_data_entry/2` at `:131-148` hardcodes `value: :undefined`
  at `:142`; `build_event_children/0` at `:203-218` builds placeholders with
  `value: :undefined` at `:214`. None of these read a trace payload.

**The authoring-mode in-place value editing affordance does not exist yet.**
The moduledoc states it directly at `datamodel_explorer.ex:12-17`: "This pane
is a **projection, not an editor**. There is no write path in either mode",
naming `sui-t36.8` as the bead that would bring "the widget and the write
affordance". `markdown.ex:1-26` repeats that the pane is display-only. No
function in the four files accepts a value to write back. See Open questions.

#### 4b. `StatifierUI.EventLog.Labels`

`lib/statifier_ui/event_log/labels.ex` renders **no** values. Every resolver
renders a structural identifier out of the `session.start` tables:
`state/2` at `:80-87`, `states/2` at `:90-93`, `transition/2` at `:104-110`
with `render_transition/2` at `:213-219`, `content/2` at `:116-122` with
`render_content/1` at `:235-238`, `data/2` at `:125-131` (which renders a
`<data>` element's `id`, never a value), `origin/2` at `:138-171`, and
`owner/2` at `:178-199`. There is no read of `"value"`, `"data"`,
`"new_value"`, `"prior_value"`, or `"donedata"` in the file. A sentinel never
reaches this module.

The value rendering the ADR attributes to "EventLog's labels" is in fact in
the sibling markdown renderer, next.

#### 4c. `StatifierUI.EventLog.Markdown` - two sites that are worse than a literal map

- `payload_suffix/2` at [`lib/statifier_ui/event_log/markdown.ex:305-311`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_log/markdown.ex#L305-L311)
  renders selected payload keys as `key=#{inspect(value)}` at `:309`, guarded
  by `Map.has_key?/2` at `:307`. Its callers name the keys:
  `effect_line/1` at `:285-287` passes `~w(label value)` for `effect.log` -
  so **`effect.log`'s `value` is rendered with `inspect/1`**, and under
  projection would print the literal `%{"$redacted" => true}`, which
  ADR-0012's flow-through clause forbids. The other callers at `:289-301`
  pass identity keys only (`event`, `target`, `invoke_id`, `send_id`).
- `footer_line/1` at `:115-117` pattern-matches
  `%Message{type: "session.terminated", payload: %{"reason" => reason}}` and
  **string-interpolates** `reason` at `:116`. Under projection `reason` is
  the sentinel map, and `"#{a_map}"` raises `Protocol.UndefinedError` because
  `String.Chars` is not implemented for `Map`. This is the one consumer site
  that would crash rather than mis-render.
- `footer_line/1` at `:119-121` renders `session.unroutable`'s whole `effect`
  object with `inspect/1` at `:120`, so any nested sentinel would print
  literally there too.
- `event_cell/1` at `:221-224` reads only `event["name"]`, and
  `budget_lines/1` at `:268-271` reads only the pending list's `length/1` and
  `payload["budget"]` - neither touches a value.

#### 4d. `StatifierUI.EventLog` (the fold)

`lib/statifier_ui/event_log.ex` carries values opaquely rather than
interpreting them. `put_message/2` for `trace.event_dequeued` at `:147-157`
stores the whole `payload["event"]` map (`:148`, stored at `:151`), which
includes its `data`; `cause_of/1` at `:198-199` reads `event["cause"]`. Every
other clause reads structure only: `payload["t_indexes"]` at `:162`,
`payload["indexes"]` at `:169` and `:173`, `payload["owner"]` and
`payload["c_indexes"]` at `:177`, `payload["configuration"]` at `:182`, and
the raw `trace.done` / `effect.budget_exhausted` payloads stored as-is at
`:186` and `:190`. The stream-completeness signal it produces is
`truncated?`, declared at `:48-55`, computed at `:75` and `:95-101`.

#### 4e. `StatifierUI.Kino`

Four `Kino.Frame`s are created at [`lib/statifier_ui/kino.ex:109-114`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/kino.ex#L109-L114)
(`status`, `diagram`, `datamodel`, `log`) and composed into the returned grid
at `:138-147`, with a fifth non-frame injection UI at `:151-170`. All four
are rebuilt in `Updater.render_panes/1` at `:273-296`:

- **status** at `:281` - `Inspector.status(stats)` over
  `Subscriber.stats(state.sub)` read at `:278`. Renders stream metadata, no
  values.
- **diagram** at `:283-286` - `Inspector.diagram/3`. No values.
- **datamodel** at `:288-291` - `Inspector.datamodel(messages)`, which is the
  `DatamodelExplorer` path in 4a. **This is the pane that renders datamodel
  values.**
- **log** at `:293` - `Inspector.event_log(messages)`, which is the
  `EventLog.Markdown` path in 4c. **This is the pane that renders
  `effect.log`'s value and `session.terminated`'s reason.**

The injection pane's `injection_ui/2` at `:151-170`, `palette_buttons/3` at
`:172-189`, and `deliver/4` at `:202-218` render confirmation text built from
`entry.payload_text` and operator-typed JSON, not from decoded trace values.

#### 4f. `StatifierUI.EventInjection` and friends - the seeding source is fixtures, not observations

Nothing in the trio consumes a `%StatifierUI.Trace.Message{}`.

- `Palette.build_entry/2` at
  [`lib/statifier_ui/event_injection/palette.ex:97-107`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection/palette.ex#L97-L107) seeds `Entry.payload`
  from `Fixtures.event(fixtures, name)` at `:98` - the fixtures bundle's
  static `events` map (ADR-0003), documented at `palette.ex:1-35`.
  `Palette.build/1` at `:61-73` walks `Fixtures.event_names/1`.
- `encode_payload_text/1` at `palette.ex:109-116` runs that payload through
  `Value.encode/1` at `:113` and `Trace.Json.encode_to_string/1` at `:114`.
  This is the one module in `lib/` that uses `Trace.Json`, which is the fact
  ADR-0012's Context rests its placement argument on.
- `Draft.build/2` at [`lib/statifier_ui/event_injection/draft.ex:84-93`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection/draft.ex#L84-L93) seeds
  `data` only from a form's free-typed `payload_text`, via
  `decode_payload/1` at `:108-121`, `json_decode/1` at `:124-129`, and
  `value_decode/1` at `:132-137`.
- [`lib/statifier_ui/event_injection.ex:64-69`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection.ex#L64-L69) wires `Palette.build/1`; the
  send path is at `:86-100`. No `Trace.Message` alias appears in the file.

So the affordance ADR-0012 names - "payload composition where it is seeded
from observed values" - has no code today. What does exist is a seeding path
from the fixtures bundle, and `session.start`'s `fixtures` is itself
position row 15. See Open questions.

#### 4g. `StatifierUI.Inspector` and `StatifierUI.Diagram` - no values

- `lib/statifier_ui/inspector.ex` reads `payload["configuration"]` in
  `active_configuration/2` at `:38-52` (matched at `:42`), passes only the
  machine and that configuration to `Diagram.render/2` in `diagram/3` at
  `:58-61`, and delegates wholesale in `event_log/1` at `:69-75` and
  `datamodel/1` at `:83-89`, catching `{:error, reason}` for a fallback
  string at `:73` and `:87`. `status/1` at `:98-112` reads only
  `stats.session` (`:100`), `stats.status`/`buffered`/`dropped`/`errors`
  (`:103-104`), and `stats.diagnostics` (`:107-108`). No values.
- `lib/statifier_ui/diagram.ex` never references `Message` or `payload` at
  all. `render/2` at `:84-96` takes a machine and a configuration;
  `highlight_lines/2` at `:217-237` filters integer indexes at `:224`.
  Everything else walks `Machine`/`State`/`Transition` structs (aliases at
  `:49-51`). No values.

#### 4h. Where the stream's mode is surfaced today

`Inspector.status/1` at [`lib/statifier_ui/inspector.ex:98-112`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/inspector.ex#L98-L112), rendered into
the Kino status frame at [`lib/statifier_ui/kino.ex:281`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/kino.ex#L281). Its `label/1` helper
at `:113-118` already turns diagnostic kinds into header labels:
`:not_recorded` and `:catch_up_failed` become `"Live-only"` at `:115-116`,
and `:late_attach` becomes `"Late attach"` at `:117`. The input is the
`stats()` map from `Subscriber.stats/1`, whose type is declared at
[`lib/statifier_ui/trace/subscriber.ex:100-110`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L100-L110) and whose construction is
`build_stats/1` at `:519-531`. This is the affordance the ADR's "surface the
profile name where the mode is surfaced" clause points at, and
`stats()` is the carrier that reaches it.

**The plumbing idiom the repo already uses for a mode-like flag** (three
instances, all the same shape - a boolean or atom field on a result struct,
computed once inside the module's own build function, read directly by
callers with no accessor):

- `free_form_only?` on `EventInjection.t()`, declared at
  [`lib/statifier_ui/event_injection.ex:47-53`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection.ex#L47-L53), computed at `:67`, described
  at `:28-35`.
- `truncated?` on `EventLog.t()`, declared at
  [`lib/statifier_ui/event_log.ex:48-55`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_log.ex#L48-L55), computed at `:75` and `:95-101`.
- the diagnostic-kind labels in `Inspector.status/1` above.

### 5. `StatifierUI.Value` and `StatifierUI.Shape`

**Where the reserved set is closed today.** [`lib/statifier_ui/value.ex:92-97`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/value.ex#L92-L97):

```
def decode(map) when is_map(map) and map_size(map) == 1 do
  case Map.keys(map) do
    ["$" <> _rest = key] -> {:error, {:unknown_tag, key}}
    _other -> decode_host_map(map)
  end
end
```

The four recognized tags are matched ahead of it: `$undefined` at `:72`,
`$date` at `:74-79`, `$datetime` at `:81-86`, `$duration` at `:88-90`. A
multi-key map containing a `$` key falls to `:99` and is an ordinary host
map. The moduledoc records the closure at `:52-58`.

**What must change in `decode/1`.** One clause, ahead of the catch-all at
`:92`, matching `%{"$redacted" => true}` with `map_size(map) == 1`, in the
same style as the `$undefined` clause at `:72`. The question the clause has
to answer is what Elixir term the sentinel decodes to, and the codebase
offers no existing term that means "withheld" - `:undefined` already means
unbound and is what `DatamodelExplorer` renders for it (section 4a), so
reusing it reintroduces the exact confusion the ADR forbids. See Open
questions.

**What must change in `encode/1`.** The encode side must be able to produce
`%{"$redacted" => true}` from whatever term `decode/1` yields, in the same
shape as `encode(:undefined)` at `:138`. Two independent constraints bear on
it:

- The catch-all at `:171` returns `{:error, {:unsupported_value, other}}` for
  any bare atom that is not `nil`, `:undefined`, `true`, or `false`, so a new
  atom term needs an explicit clause ahead of it.
- `encode_host_map/1` at `:220-228` recurses over a map's values, so a
  sentinel map already round-trips as a two-step host map today unless a
  clause claims it first: `encode(%{"$redacted" => true})` currently goes to
  `:144` (`is_map`), fails `Shape.duration?/1` at `:145`, and comes back out
  as the identical map from `encode_host_map/1`. Its `decode/1` is what
  errors, not its `encode/1`. So encode already produces the right bytes for
  a map-shaped term and the asymmetry is entirely on the decode side.

**The round-trip property.** The existing property is asserted in a table at
[`test/statifier_ui/value_test.exs:196-227`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/test/statifier_ui/value_test.exs#L196-L227): for each `{name, value}` pair,
`Value.decode(encoded) == {:ok, value}` where `encoded` came from
`Value.encode(value)`. For the sentinel the property is
`decode(encode(<withheld term>)) == {:ok, <withheld term>}` and
`encode(<withheld term>) == {:ok, %{"$redacted" => true}}`, which makes the
JSON form idempotent under a decode/encode round trip - the same property
`$undefined` has at `value_test.exs:29-31` and `:117-119`. Durations are the
one existing exception to identity round-tripping (moduledoc `:18-23`); the
sentinel carries no payload, so it has no analogous canonicalization step.

**`StatifierUI.Shape`.** `infer/1` at [`lib/statifier_ui/shape.ex:62-85`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/shape.ex#L62-L85) is
total over `term()`: a term outside the value domain infers as `:unknown`
(`:85`), and an unrecognized struct as `:unknown` at `:75`. A new atom term
would fall to `:85` and infer `:unknown`, and a bare
`%{"$redacted" => true}` map would fail `duration?/1` at `:78` and infer
`{:map, %{"$redacted" => :boolean}}` at `:77-83`. The `t()` type is declared
at `:28-41` and the label renderer at `:201-206` with one `render/4` clause
per shape at `:209-245`, including `:undefined -> "undefined"` at `:217`.
Whatever `decode/1` yields needs a matching `t()` variant, an `infer/1`
clause, and a `render/4` clause, or the explorer's shape column will read
`unknown` for every redacted slot.

### 6. The test surface

**The type-index drift test.** `test/statifier_ui/trace/wire_format_spec_test.exs`.
The assertion body is at `:9-27`: it builds `documented` from the doc and
`code` from `MapSet.new(Normalizer.types())`
([`lib/statifier_ui/trace/normalizer.ex:112-113`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/normalizer.ex#L112-L113), backed by `@types` at
`:75-100`), computes both set differences, and asserts equality at `:26`.

The parser is a private helper in the same test file at `:32-40` - there is
no support module:

```elixir
defp extract_type_index_types(document) do
  [_before, table_and_after] = String.split(document, "## Type index", parts: 2)

  ~r/^\|\s*`([a-z._]+)`\s*\|/m
  |> Regex.scan(table_and_after, capture: :all_but_first)
  |> List.flatten()
  |> MapSet.new()
end
```

How it works, precisely:

- **Table location is heading-text only.** `String.split/3` at `:34` cuts on
  the literal `"## Type index"` and keeps everything after it, to end of
  file. There is no anchor, no column-name detection, and no stop at the next
  `##`, so any later table row of the same shape would also be scanned.
- **Row identification is positional.** The regex at `:36` requires a line
  starting with `|`, then a backtick-quoted token, then `|`. It captures only
  the first column, and "first column" means "first cell", not a named
  header.
- **The character class `[a-z._]+` is the tuning.** It accepts dotted
  lowercase type strings and rejects uppercase, digits, hyphens, and spaces.

What is generic versus table-specific, for a second test parsing a new
Projection position table: the regex is generic and would match a
`| \`message.type\` | position |` row unchanged, provided the first cell is
backtick-quoted and lowercase-dotted. The heading literal at `:34` and the
"scan to EOF" behavior are the table-specific parts, and a Projection table
placed *before* `## Type index` in the document would be invisible to the
existing test while a table placed after it would leak its first column into
the existing test's `documented` set if those cells were backtick-quoted
lowercase dotted strings. That is a real interaction between where the new
section sits and whether the existing drift test still passes.

**Golden traces.** `test/statifier_ui/trace/golden_trace_test.exs`, fixture at
`/Users/johnnyt/Dev/github/statifier/statifier-ui-worktrees/sui-hmn-trace-projection/test/support/trace/two_state.jsonl`,
resolved at `golden_trace_test.exs:34`. It is JSON Lines, 15 messages
(`@full_seq 15` at `:35`).

- **Production**: there is no mix task and no regeneration flag or env var
  anywhere in the repo. The fixture is committed, and the chart that produced
  it is pinned in the test itself at `:25-32` with an explicit warning at
  `:22-24` that the byte offsets were captured from that exact indentation.
- **The run**: `run_trace/0` at `:37-46` compiles via `SessionCase.compile!/1`,
  starts through `SessionCase.start_early!/3` with `session_id: "sess_golden"`,
  sends `"go"`, waits with `SessionCase.wait_for_seq/2`, pulls
  `Subscriber.messages(sub)`, and encodes with
  `StatifierUI.Trace.Json.encode_lines/1` ([`lib/statifier_ui/trace/json.ex:66`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/json.ex#L66)).
- **The assertion** at `:48-57` is a byte comparison: `first_run == expected`,
  `second_run == expected`, and `first_run == second_run`. So determinism is
  asserted alongside the match. A per-profile golden would follow the same
  shape - one fixture file, one `run_trace`-alike differing only in the
  subscriber options.

**`test/support/trace/session_case.ex`** (module
`StatifierUI.Test.Support.Trace.SessionCase`, moduledoc at `:2-9`):

- `compile!/1` at `:16-19`.
- `start_early!/3` at `:29-37` - the path the golden test uses:

```elixir
def start_early!(machine, session_id, subscriber_opts \\ []) do
  {:ok, sub} = Subscriber.start_link(Keyword.put(subscriber_opts, :machine, machine))

  {:ok, session} =
    Session.start_link(machine, trace: true, subscribers: [sub], session_id: session_id)

  :ok = Subscriber.attach(sub, session, subscribe: false)
  {sub, session}
end
```

  The important detail for a projection test is that **every subscriber-
  starting helper takes a caller-supplied `subscriber_opts` keyword list and
  merges `:machine` into it** - `start_early!/3` at `:30`, `start_late!/3` at
  `:47-52`, and `attach_catch_up!/3` at `:72-77`. A projection profile option
  passed to `Subscriber.start_link/1` therefore needs no change to this
  support module at all.
- `start_recorded!/2` at `:63-69` starts a `record: true` session for the
  catch-up path.
- `wait_for_macrostep/3` at `:85-95`, `wait_for_seq/3` at `:104-106`, and
  `wait_until/3` at `:109-124` poll rather than `assert_receive`, because the
  test process is never the subscriber.

**Existing reserved-shape tests.** `test/statifier_ui/value_test.exs`:
decode of `$undefined` at `:29-31`, `$date` at `:33-35`, `$datetime` at
`:37-40`, `$duration` at `:42-55`, nested inside a list at `:57-59`; the
encode mirrors at `:117-119`, `:121-123`, `:125-128`, `:130-156`; the
round-trip table at `:196-227`. The closure test is the one that must move:

```elixir
describe "decode/1 - reserved shape enforcement" do
  test "rejects an unrecognized $-prefixed one-key object" do
    assert {:error, {:unknown_tag, "$bogus"}} = Value.decode(%{"$bogus" => true})
  end

  test "treats a multi-key object containing $date as an ordinary host map" do
    assert Value.decode(%{"$date" => "2026-08-16", "other" => 1}) ==
             {:ok, %{"$date" => "2026-08-16", "other" => 1}}
  end
end
```

at `value_test.exs:62-71`. The `$bogus` case stays valid; the set it guards
grows by one. Duration-specific rejections at `:105-113` are unrelated - they
fire after `$duration` is already recognized.

### 7. Where `docs/wire-format.md` must grow

The three edits ADR-0012's Consequences names, with exact coordinates in the
document at commit `d566de0`:

1. **The value-encoding section and the sentence closing the reserved set.**
   `## JSON discipline` opens at [`docs/wire-format.md:132`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/wire-format.md#L132);
   `### Value encoding` is at `:138`. The five encoding bullets run
   `:145-161` (the `$undefined` bullet at `:156-161`). **The closing
   sentence is [`docs/wire-format.md:163-167`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/wire-format.md#L163-L167)**:

   > The one-key `$`-prefixed object shape is reserved by this document for
   > exactly these four forms. A host value that happens to be a one-key map
   > whose only key starts with `$` and is not one of `$undefined`, `$date`,
   > `$datetime`, or `$duration` is a spec violation on the producer's side,
   > not a value this format can carry unambiguously - accepted as
   > vanishingly rare.

   Both the count word ("four forms") and the enumerated list at `:165-166`
   have to admit `$redacted`. A second, secondary reference to "the value
   codec's four forms" sits at `:210-211`, inside `### Structural tagging`.

2. **`session.start`'s field table.** The section heading is
   [`docs/wire-format.md:240`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/wire-format.md#L240); the top-level field table is `:248-258`, with
   the header row at `:248-249` and the nine data rows at `:250-258`
   (`version`, `states`, `transitions`, `contents`, `data`, `source`,
   `fixtures`, `parent_session`, `invokeid`). A `projection` row joins that
   table. The prose immediately after, at `:260-265`, explains `version` and
   `data`'s always-present rule. The nested tables that follow - `states` at
   `:270-278`, `transitions` at `:283-292`, `contents` at `:297-300` onward,
   and `data` further down - are untouched by projection. There is a second,
   short `### session.start` stub at `:738-741` that points back at this
   table.

3. **Where a new `## Projection` section should sit.** The document's
   top-level sections in order are: `## Status and scope` (`:5`),
   `## The envelope` (`:37`), `## Ordering` (`:85`), `## JSON discipline`
   (`:132`), `## `session.start`` (`:240`), `## The nine `trace.*` schemas`
   (`:400`), `## The ten `effect.*` schemas` (`:512`), `## Origins` (`:689`),
   `## Owners` (`:710`), `## The `session.*` types` (`:727`),
   `## Worked example` (`:809`), `## Type index` (`:875`), `## References`
   (`:912`).

   Two placements are consistent with the document's own order, and the
   choice has a mechanical consequence rather than an aesthetic one, because
   of the drift parser's scan-to-EOF behavior documented in section 6:

   - **After `## The `session.*` types` and before `## Worked example`** -
     i.e. a new `## Projection` at line 809's position. This is after every
     schema the position table references, so every row's target is already
     defined, and it is *before* `## Type index` at `:875`, which means the
     existing drift parser's split at `"## Type index"` never sees the new
     table and cannot pick its cells up.
   - **After `## Type index`** - which puts the new table inside the region
     the existing parser scans, so its first-column cells would have to avoid
     matching `^\|\s*`[a-z._]+`\s*\|` or the type-index drift test would fail
     for a reason that has nothing to do with type drift.

   The section also has to carry, per ADR-0012's Consequences: the closed
   position table, the two allowlist shapes (`allow_paths` as prefix arrays
   in `location_path`'s own encoding, and the closed `allow_positions` atom
   set), `allow_source`, and the `projection` header object.

   Two further prose spots restate claims projection qualifies and would read
   as stale without a cross-reference: `### session.datamodel` at `:743-768`,
   whose `:752-760` paragraph says a consumer folds writes over the snapshot
   "to hold the current datamodel at any point in the run"; and
   `### session.terminated` at `:785-796`, whose table row at `:792` types
   `reason` as `string | always`, which projection changes to the sentinel
   object - the one type change ADR-0012 accepts.

## Code References

- [`lib/statifier_ui/trace/subscriber.ex:486-491`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L486-L491) - `buffer_and_fanout/2`, the
  single choke point; callers at `:435`, `:454`, `:510`
- [`lib/statifier_ui/trace/subscriber.ex:114-158`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L114-L158) - `State`, where a profile
  field goes; `init/1` at `:246-261`, `start_link/1` at `:180-185`
- [`lib/statifier_ui/trace/subscriber.ex:501-506`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/subscriber.ex#L501-L506) - the hand-built
  `session.terminated` message and its `inspect/1` reason
- [`lib/statifier_ui/trace/normalizer.ex:550-589`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/normalizer.ex#L550-L589) - the three-way absence rule
  (`put_defined/3`, `put_value/3`, `put_present/3`)
- [`lib/statifier_ui/trace/normalizer.ex:131-142`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/normalizer.ex#L131-L142) - `session.unroutable`'s
  wrapping under `payload["effect"]` with a `"kind"` key
- [`lib/statifier_ui/trace/normalizer.ex:397-410`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/normalizer.ex#L397-L410) - `event_list/1`, the
  `effect.budget_exhausted` list whose entries each carry a `data`
- [`lib/statifier_ui/trace/manifest.ex:76-99`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/manifest.ex#L76-L99) - `build/3` and the payload the
  `projection` object joins
- [`lib/statifier_ui/value.ex:92-97`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/value.ex#L92-L97) - the closure clause that rejects
  `$redacted` today; `encode/1` at `:137-171`
- [`lib/statifier_ui/shape.ex:62-85`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/shape.ex#L62-L85) - `infer/1`; `render/4` at `:209-245`
- [`lib/statifier_ui/datamodel_explorer.ex:170-201`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer.ex#L170-L201) - the fold;
  `decode_write_value/3` at `:451-474`; `seed_live_entry/3` at `:386-403`
- [`lib/statifier_ui/datamodel_explorer/markdown.ex:144`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer/markdown.ex#L144) - `inspect/1` on
  every value
- [`lib/statifier_ui/event_log/markdown.ex:305-311`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_log/markdown.ex#L305-L311) - `payload_suffix/2`,
  which `inspect/1`s `effect.log`'s value via `:285-287`
- [`lib/statifier_ui/event_log/markdown.ex:115-117`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_log/markdown.ex#L115-L117) - the
  `session.terminated` interpolation that would raise on a map
- [`lib/statifier_ui/event_injection/palette.ex:97-116`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection/palette.ex#L97-L116) - seeding from the
  fixtures bundle, and the one `Trace.Json` use in `lib/`
- [`lib/statifier_ui/inspector.ex:98-118`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/inspector.ex#L98-L118) - `status/1` and `label/1`, where
  the mode is surfaced today
- [`lib/statifier_ui/kino.ex:273-296`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/kino.ex#L273-L296) - `render_panes/1` and the four frames
- [`test/statifier_ui/trace/wire_format_spec_test.exs:32-40`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/test/statifier_ui/trace/wire_format_spec_test.exs#L32-L40) - the drift
  parser
- [`test/statifier_ui/trace/golden_trace_test.exs:37-57`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/test/statifier_ui/trace/golden_trace_test.exs#L37-L57) - golden production
  and byte assertion
- [`test/support/trace/session_case.ex:29-37`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/test/support/trace/session_case.ex#L29-L37) - `start_early!/3` and the
  `subscriber_opts` pass-through
- [`test/statifier_ui/value_test.exs:62-71`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/test/statifier_ui/value_test.exs#L62-L71) - the reserved-shape closure test
- [`docs/wire-format.md:163-167`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/wire-format.md#L163-L167), `:248-258`, `:875-883` - the three edit
  sites

## Architecture Documentation

- **ADR-0012** (accepted 2026-08-26) is the contract this document maps. Its
  placement claim - "every shipped consumer reads `%Message{}` structs and
  never passes through that encoder" - checks out with one qualification:
  `Trace.Json` is used in `lib/` by exactly one module,
  [`lib/statifier_ui/event_injection/palette.ex:113-114`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection/palette.ex#L113-L114), and that use is on
  the fixtures-to-form path, not on the trace-consumption path. So the claim
  holds for consumption.
- **ADR-0012's amendment (proposed 2026-08-27, sui-0of)** substitutes the
  canonical example domains into the allowlist illustration. It is proposed,
  not accepted; the accepted text stands. This document uses no example
  values, so it is unaffected either way.
- **ADR-0005** already annotates itself as extended by ADR-0012 at
  [`docs/adr/0005-language-neutral-trace-wire-format.md:5`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/adr/0005-language-neutral-trace-wire-format.md#L5).
- **ADR-0011** (exit and entry sets are sequences) governs the ordering
  fields projection must leave alone; it is why `indexes/1` at
  [`lib/statifier_ui/trace/normalizer.ex:547-548`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/trace/normalizer.ex#L547-L548) is the identity function
  with a comment rather than a sort.
- **ADR-0003** is why `session.start`'s `fixtures` is a datamodel bundle by
  construction and is replaced whole.
- The repo's `CLAUDE.md` agent-authority table applies: this research pass
  writes one document and commits nothing.

## Historical Context

- `docs/research/260822-sui-t36.7-datamodel-explorer-pane.md` - the research
  behind the datamodel pane whose fold section 4a maps.
- `docs/research/260816-sui-kua-gui-research-and-direction.md` - why the
  repo exists; the ADRs cite it.
- `docs/research/260816-sui-t36.1-trace-coverage-spike.md` and
  `docs/research/260819-sui-bpb-statifier-and-predicator-9-refresh-surface.md`
  - trace-surface background.
- sui-bur's closing notes (2026-08-26) record two items the design surfaced
  and did not decide: wire format v1 carries no wall-clock timestamp, and
  `docs/architecture.md`'s "What exists today" is stale about the Kino
  widget. ADR-0012 closes the first ("The requirement is met as the format
  stands"); the second is untouched by this work.

## Open questions

Recorded, not decided. Each is a place where the implementation needs an
answer that ADR-0012's accepted text does not give, or where the code has
moved out from under the ADR's assumption.

1. **What Elixir term does `{"$redacted": true}` decode to?** ADR-0012 fixes
   the JSON encoding and forbids the consumer from rendering it as unbound,
   null, empty, or a literal map, but names no in-process term.
   `:undefined` is taken (it is what `DatamodelExplorer` already substitutes
   on a decode error, `datamodel_explorer.ex:462-471`), and reusing it would
   reintroduce exactly the confusion the ADR forbids. A new atom such as
   `:redacted`, or a tagged tuple, or leaving the sentinel map undecoded, are
   all consistent with the accepted text. This decision also determines the
   `StatifierUI.Shape.t()` variant, the `infer/1` clause, and the `render/4`
   label, none of which the ADR mentions.

2. **What does an `allow_paths` prefix mean when the write is shallower than
   the prefix?** The ADR says "A prefix matches a write when it matches the
   write's leading segments", which is unambiguous when the allowed prefix is
   shorter than or equal to the write's path. It does not say what happens
   when a profile allows a two-segment leaf and the write's `location_path`
   is the one-segment parent, whose `new_value` contains both the allowed
   leaf and its withheld siblings. Allowing the whole write leaks the
   sibling; denying it withholds an allowed leaf; descending into the value
   to redact selectively is a third behavior the ADR does not describe.

3. **Do `allow_paths` prefixes descend into `session.datamodel`'s values?**
   The ADR says the same prefixes apply and that "keys are the first segment
   of every path", which settles a one-segment prefix. A two-segment prefix
   would have to descend into the snapshot's value for that key to allow one
   sub-key. The ADR notes this row "changes nothing observable today" because
   the snapshot's values are all `{"$undefined": true}` before the binding
   fold ([`docs/wire-format.md:752-760`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/docs/wire-format.md#L752-L760)), so the ambiguity is currently
   unobservable - but the implementation still has to pick a behavior.

4. **The datamodel explorer's in-place value editing does not exist.** The
   ADR requires it be disabled under projection
   (`architecture.md`, "the datamodel explorer's two modes"), but
   [`lib/statifier_ui/datamodel_explorer.ex:12-17`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/datamodel_explorer.ex#L12-L17) states there is no write
   path in either mode and names `sui-t36.8` as the bead that would add one.
   Whether sui-hmn should ship a disabling mechanism for an affordance that
   does not exist, or record the requirement as a constraint on sui-t36.8, is
   not something the ADR decides.

5. **`EventInjection` is not seeded from observed values.** The ADR requires
   disabling "`EventInjection`'s payload composition where it is seeded from
   observed values", but the palette is seeded from the fixtures bundle
   ([`lib/statifier_ui/event_injection/palette.ex:98`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_injection/palette.ex#L98)) and the draft from
   operator-typed text (`draft.ex:86-93`). No message-observed leg exists.
   Two readings are open: the clause is vacuous today and the requirement is
   satisfied by construction, or it applies transitively because a host may
   pass the same bundle it puts in `session.start`'s `fixtures`, which is
   position row 15 - in which case whether the palette should be suppressed
   when the stream is projected is a decision the ADR does not make.

6. **`session.terminated`'s sentinel `reason` would raise, not mis-render.**
   [`lib/statifier_ui/event_log/markdown.ex:116`](https://github.com/riddler/statifier-ui/blob/d566de026c73cca444f66cad935610c44e096e5d/lib/statifier_ui/event_log/markdown.ex#L116) string-interpolates the
   reason; a map raises `Protocol.UndefinedError`. The ADR's flow-through
   list names the datamodel explorer, the event-log labels, and the Kino
   panes, and it does not name this site. Whether fixing it is in sui-hmn's
   scope or is a separate bead is unrecorded.

7. **Where the new Projection section sits interacts with the existing drift
   test.** Section 7 records the mechanism: the existing parser splits on
   `"## Type index"` and scans to end of file
   (`wire_format_spec_test.exs:34`), so a Projection position table placed
   after it would leak matching first-column cells into the type-index
   assertion. The ADR says the new drift-style test "belongs with the
   type-index drift test" but does not say where the doc section goes.

8. **Is `Trace.Json.encode_lines/1` in scope for a projected golden?**
   ADR-0012 places the transform before the encoder and says a profile's
   output "is tested against its own golden, produced under that profile".
   The existing golden test drives production through
   `Json.encode_lines/1` (`golden_trace_test.exs:44-45`) with no
   regeneration tooling of any kind - no mix task, no `UPDATE_GOLDEN` flag -
   so a second golden is a hand-produced committed file under the same
   constraint. Whether that is acceptable or whether regeneration tooling
   should land with it is not decided anywhere.
