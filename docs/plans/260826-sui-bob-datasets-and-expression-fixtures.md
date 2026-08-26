# Datasets and expression fixtures Implementation Plan

## Overview

Implement ADR-0006's two additive fixture keys - `datasets` (named, reusable
example datamodels) and `expressions` (a free-standing predicator source plus
an `expect` map keyed by dataset name) - on both ADR-0003 delivery paths, add
the lint that ADR-0006 specifies (byte-equality guard matching, dangling
`expect` keys), and ship an executable-expectations runner so fixture
documentation fails a test suite when it drifts. Bead: `sui-bob`.

ADR-0006 is accepted and this plan implements it as written. No decision in
that record is reopened, and neither of its two carried open questions
(dataset-overlays-a-base-scenario; whether expression fixtures are normative
in the language-neutral spec) is resolved here.

## Current State Analysis

The fixtures contract is built and shipping. What exists:

- `lib/statifier_ui/fixtures.ex:62` - `defstruct scenarios: %{}, events: %{},
  diagnostics: []`, with `@type t` at `:56`. `new/1` (`:83`) is the single
  validation implementation; `from_source/1` (`:103`) routes the behaviour
  path through it, and `StatifierUI.Fixtures.Sidecar.from_json/2`
  (`lib/statifier_ui/fixtures/sidecar.ex:100`) routes the JSON path through
  the same call. That shared call is what makes ADR-0003 convergence
  structural rather than aspirational, and it is the seam this bead extends.
- `lib/statifier_ui/fixtures.ex:191-232` - `check_keys/2`, the recursive
  string-keys-at-every-depth walk, shaped after
  `Statifier.MachineState.check_keys!/2` but deliberately stricter (integer
  and boolean keys rejected too), because a JSON object key is always a
  string and a scenario a behaviour source could express but a sidecar could
  not would break the one-struct guarantee. It reports `{:invalid_key, key,
  path}` and, for a predicator duration, `{:duration_in_scenario, path}`.
- `lib/statifier_ui/fixtures/source.ex:33-47` - `__using__` injects empty
  defaults for `scenarios/0` and `example_events/0` with `@impl`, `@spec`,
  and `defoverridable`, so a host implements only what it has.
- `lib/statifier_ui/fixtures/sidecar.ex:28` - `@known_top_level_keys ~w(version
  scenarios events)`, and `unknown_key_diagnostics/2` (`:184`) emits an
  `:unknown_key` diagnostic per unrecognized top-level key. This is ADR-0006's
  load-bearing ignore-unknown-keys rule already in force.
- `lib/statifier_ui/value.ex` - the ADR-0005 `$`-tag codec (`$undefined`,
  `$date`, `$datetime`, `$duration`). `decode/1` is applied per value by
  `decode_map_of_values/2` (`sidecar.ex:172`). `encode/1` is the inverse and
  canonicalizes a duration to all eight units.
- `test/support/fixtures/extended.fixtures.json` **already contains ADR-0006's
  exact example** - `minor` / `adult-us` datasets and an `is-adult-us`
  expression with `source` and `expect` - plus a `"nonsense"` key. It exists
  today only to prove unknown keys are tolerated
  (`test/statifier_ui/fixtures/sidecar_test.exs:97-108` asserts
  `["datasets", "expressions", "nonsense"]`). This bead inverts that
  assertion; the `"nonsense"` key must stay so the diagnostic-logging test
  at `:116-128` keeps a subject.
- `test/statifier_ui/fixtures/convergence_test.exs` - two hand-written pairs
  (`PaymentSource` / `payment.fixtures.json`, `TaggedSource` /
  `tagged.fixtures.json`) compared field by field with an **explicit field
  list**, not `source == sidecar`. New struct fields are therefore invisible
  to it until the assertions are added.

What is missing: the two keys in the struct, in the behaviour, and in the
loader; any lint; any runner; and any doc mention of either key outside
`docs/adr/`.

Two constraints discovered that shape the work:

1. **`predicator` is a transitive dep only.** `mix.exs:74-93` lists
   `statifier_dep()`, `kino`, `phoenix_live_view`, and dev/test tools;
   `predicator` 9.0.0 arrives through `statifier` (`mix.lock:29`). No module
   under `lib/` calls `Predicator.*` today - only tests do
   (`test/statifier_ui/value_test.exs:89,98`,
   `test/statifier_ui/shape_test.exs:92,98`). With
   `warnings_as_errors: true` (`.quality.exs:36-38`), the first `Predicator.`
   call from `lib/` produces a cross-application warning and fails the gate
   until `mix.exs` declares the dependency directly.
2. **The compiled Machine retains guard source text.**
   `deps/statifier/lib/statifier/machine.ex:161` -
   `@type expr :: {:static, term()} | {:compiled, Predicator.Compiled.t(),
   source :: String.t()}`, and `Statifier.Machine.Transition`'s `:cond` field
   (`deps/statifier/lib/statifier/machine/transition.ex:79,92`) holds one.
   Byte-equality matching therefore needs no new engine seam and no SCXML
   re-parse - the source string is already there, which is what makes
   ADR-0006's chosen identity implementable without an `st-` bead.

## Desired End State

A fixture bundle carries four maps. Both delivery paths produce them
identically, one validation implementation governs both, and a host can point
a single call at its bundle and have its test suite go red when an `expect`
map stops telling the truth.

Verifiable when all of the following hold:

- `%StatifierUI.Fixtures{}` has `datasets` and `expressions` fields, both
  defaulting to `%{}`, both string-keyed at every depth.
- `StatifierUI.Fixtures.Sidecar` treats `"datasets"` and `"expressions"` as
  known top-level keys; `extended.fixtures.json` loads with exactly one
  `:unknown_key` diagnostic (`"nonsense"`), a populated `datasets` map, and a
  populated `expressions` map.
- `use StatifierUI.Fixtures.Source` still compiles a module that implements
  neither new callback, and a module that declares `@behaviour` by hand
  without `use` still compiles warning-free.
- `test/statifier_ui/fixtures/convergence_test.exs` asserts equality on all
  four maps, over a third pair whose datasets and expressions are non-empty.
- `StatifierUI.Fixtures.Lint` reports an unmatched expression and a dangling
  `expect` key as **warnings**, never errors, and matches guards by source-text
  byte equality only.
- `StatifierUI.Fixtures.Expectations.check!/2` raises on a drifted `expect`
  map, and the repo's own suite runs it over `extended.fixtures.json`.
- `mix quality` is green; `docs/architecture.md` and `docs/wire-format.md`
  reflect the two keys; a `changelog.d/sui-bob.md` fragment exists.

### Key Discoveries:

- ADR-0006 is the spec; ADR-0003 supplies the two-delivery-paths-one-struct
  rule, ADR-0005 supplies the `$`-prefixed value encoding and the
  additive-change-is-not-a-version-bump rule, ADR-0002 supplies "the engine is
  not modified from here".
- `lib/statifier_ui/fixtures.ex:87-90` - `new/1`'s `with` chain is the one
  place both paths meet. Every new validation goes here, not in the loader.
- `lib/statifier_ui/fixtures/sidecar.ex:164-181` - `decode_section/2` and
  `decode_map_of_values/2` fit `datasets` directly (a map of names to free
  values). They do **not** fit `expressions`, whose entry values are objects
  with a fixed inner shape rather than free values; expressions need their own
  decoder.
- `deps/predicator/lib/predicator.ex:178-183` - `@spec evaluate(binary() |
  Types.instruction_list() | Compiled.t(), Types.context() | Context.t(),
  keyword()) :: {:ok, Types.value()} | {:error, struct()}`. A source string
  evaluates in one call; no separate compile step is required. Errors are
  values (five error structs, all carrying `:message`), which is exactly what
  CLAUDE.md's errors-as-values convention wants.
- `deps/predicator/lib/predicator/types.ex:66-76` - `value/0` is the closed
  domain `StatifierUI.Value` already encodes, so `expect` values need no new
  spelling. `deps/predicator/lib/predicator/types.ex:89` - `context/0` accepts
  string or atom keys, and a bare map is normalized to string keys by
  `Predicator.Context.new/2`, so a string-keyed dataset is a valid context as
  authored.
- **Unbound-root asymmetry, worth designing around rather than discovering
  later**: `Predicator.evaluate("missing", %{})` returns `{:error,
  %UndefinedVariableError{}}` (`deps/predicator/lib/predicator.ex:619-626`
  rewrites a final `:undefined` that came from an unbound load), while
  `Predicator.evaluate("user.nope", %{"user" => %{}})` returns `{:ok,
  :undefined}`. An `expect` of `{"$undefined": true}` is therefore satisfiable
  for a missing nested path but not for a wholly unbound root.
- **Duration round-trip is not identity**: `Predicator.evaluate("3d")` yields
  a seven-key duration map, while `StatifierUI.Value.decode/1` canonicalizes a
  `$duration` to all eight units (`lib/statifier_ui/value.ex:190-192`, and the
  reason is written down at `lib/statifier_ui/shape.ex:92-99`). Comparing an
  expectation to an evaluation with bare `==` would spuriously fail; comparing
  `StatifierUI.Value.encode/1` of both sides canonicalizes them.
- `.doctor.exs` requires 100% moduledoc coverage and 75% function doc/spec
  coverage; `coveralls.json` sets an 80% floor and skips `test/support/`.

## What We're NOT Doing

- **Not reopening any ADR-0006 decision.** Guard matching stays source-text
  byte equality, never `t_index`/`c_index`. An unmatched expression stays a
  lint warning. The sidecar `version` stays `1`. `expect` values keep the
  ADR-0005 `$`-prefixed encodings via `StatifierUI.Value` and gain no second
  spelling.
- **Not resolving ADR-0006's two carried open questions.** No dataset overlay
  syntax (no `"extends"`, no delta-over-a-scenario merge, no key-removal
  spelling), and no change to the normative status of expression fixtures in
  the language-neutral spec. Duplication between a dataset and a near-identical
  scenario is authored by hand, exactly as ADR-0006's consequences accept.
- **Not adding a schema language.** Datasets are examples and expectations are
  values, per ADR-0003 and ADR-0006 alike.
- **Not touching the engine or predicator.** ADR-0002. Guard source text is
  already retained (`Statifier.Machine.expr/0`), so nothing upstream is needed.
- **Not building a truth-table renderer.** That is `sui-t0a`, which this bead
  blocks. This bead produces the data a renderer consumes and stops there.
- **Not shipping a mix task.** Justified under Phase 4; the runner is a test
  helper.
- **Not introducing an `%Expression{}` struct.** Expressions stay plain
  string-keyed maps, matching scenarios, datasets, and the existing plain-map
  `Fixtures.diagnostic/0` type (`lib/statifier_ui/fixtures.ex:49-54`). A struct
  would introduce a normalization asymmetry between the two delivery paths that
  the convergence test would then have to prove away, and the sidecar's object
  is carried verbatim onto the wire (`docs/wire-format.md:370-373`), where a
  struct means nothing. Accessor functions supply the ergonomics instead.
- **Not converting `convergence_test.exs` to a table.** Its moduledoc explains
  why the compared field list is explicit; a third hand-written pair is added
  in its existing style.
- **Not emitting a diagnostic for an unrecognized key inside an expression
  entry.** Such keys are preserved verbatim rather than dropped or rejected.
  See Open Questions; this is the minimal lossless reading of ADR-0006's
  ignore-unknown-keys discipline and it is reversible in either direction once
  ruled on.

## Implementation Approach

Five phases, ordered so each leaves the gate green on its own and the risky
work lands last.

The organizing idea is that **all four maps are validated by one function**.
`StatifierUI.Fixtures.new/1` already is that function for scenarios and events,
and both delivery paths already call it. Every phase that adds validation adds
it there and nowhere else; the loader's only new job is decoding JSON into the
terms `new/1` validates. That is what keeps ADR-0003 convergence structural,
and the convergence test is what proves it did not quietly stop being true.

Datasets go first because they reuse the existing `check_keys/2` walk and the
existing `decode_section/2` decoder almost verbatim - a small, mechanically
verifiable extension that establishes the four-map shape. Expressions follow,
needing their own decoder because their entry values are objects. Lint follows
expressions because it has nothing to lint until they exist. The runner lands
fourth, because it is the phase that first calls `Predicator` from `lib/` and
therefore the phase that must declare the dependency. Docs land last, once the
shape they describe has stopped moving.

TDD throughout, matching the repo's established pattern: a failing test that
states the rule in its name, then the code. `test/statifier_ui/fixtures/` is
the home for the new tests, mirroring the lib path, with cross-cutting tests
placed under the subject's directory as `convergence_test.exs` already is.

Backward compatibility gets one specific mechanism, in Phase 1: the two new
`Source` callbacks are declared `@optional_callbacks`, and `from_source/1`
probes with `function_exported?/3` and defaults to `%{}`. Injected `__using__`
defaults alone would cover a host that wrote `use StatifierUI.Fixtures.Source`,
but not one that wrote `@behaviour StatifierUI.Fixtures.Source` by hand - that
host would start seeing "does not implement callback" warnings, which under a
`warnings_as_errors` gate is a broken build for a purely additive change.

---

## Phase 1: Datasets on both delivery paths

### Overview

The bundle grows a third map. Datasets validate exactly as scenarios do -
string keys at every depth - and load through the sidecar's existing
value-decoding section reader.

### Changes Required:

#### 1. The struct and its validation

**File**: `lib/statifier_ui/fixtures.ex`
**Changes**: add the field, the type, the `new/1` option, validation, and two
accessors. Generalize `check_keys/2`'s duration report so a dataset says
`:duration_in_dataset` rather than borrowing the scenario's wording, without
changing the existing `{:duration_in_scenario, path}` tuple any test asserts.

```elixir
@typedoc "The name of a fixture dataset."
@type dataset_name :: String.t()

@type t :: %__MODULE__{
        scenarios: %{optional(scenario_name()) => datamodel()},
        events: %{optional(event_name()) => term()},
        datasets: %{optional(dataset_name()) => datamodel()},
        diagnostics: [diagnostic()]
      }

defstruct scenarios: %{}, events: %{}, datasets: %{}, diagnostics: []
```

`new/1` gains `datasets = Keyword.get(opts, :datasets, %{})` and a
`validate_datasets/1` clause in the `with` chain. `validate_datasets/1` is
`validate_scenarios/1`'s shape with its own error atoms
(`:invalid_datasets`, `:invalid_dataset_name`, `:invalid_dataset`) and passes
a section tag into the shared walk so the duration arm reports
`{:duration_in_dataset, path}`. The walk itself is not duplicated.

Accessors, mirroring `scenario/2` and `scenario_names/1`:

```elixir
@spec dataset(t(), dataset_name()) :: {:ok, datamodel()} | :error
@spec dataset_names(t()) :: [dataset_name()]   # sorted, ADR-0005 canonical order
```

Moduledoc gains a paragraph distinguishing a dataset from a scenario in
ADR-0006's own terms (a scenario is a complete example of the host-supplied
datamodel for running a chart; a dataset is a situation for evaluating
expressions, and may be as small as the expression needs), and notes that a
predicator duration cannot appear inside a dataset for the same atom-key
reason it cannot appear inside a scenario - the reasoning already written at
`test/support/fixtures/tagged_source.ex:8-19`.

#### 2. The behaviour

**File**: `lib/statifier_ui/fixtures/source.ex`
**Changes**: a `datasets/0` callback, an injected default, and - the
backward-compatibility mechanism - optionality.

```elixir
@typedoc "A named example datamodel for evaluating expressions."
@type datasets :: %{optional(String.t()) => map()}

@callback datasets() :: datasets()

@optional_callbacks datasets: 0
```

`__using__` gains the injected default and extends `defoverridable`:

```elixir
@impl StatifierUI.Fixtures.Source
@spec datasets() :: StatifierUI.Fixtures.Source.datasets()
def datasets, do: %{}

defoverridable scenarios: 0, example_events: 0, datasets: 0
```

#### 3. The behaviour delivery path

**File**: `lib/statifier_ui/fixtures.ex`
**Changes**: `from_source/1` reads the new callback defensively.
`ensure_source/1` keeps requiring only `scenarios/0` and `example_events/0`,
so a pre-existing host module is still a valid source.

```elixir
def from_source(module) do
  with :ok <- ensure_source(module) do
    new(
      scenarios: module.scenarios(),
      events: module.example_events(),
      datasets: optional_callback(module, :datasets)
    )
  end
end

@spec optional_callback(module(), atom()) :: map()
defp optional_callback(module, fun) do
  if function_exported?(module, fun, 0), do: apply(module, fun, []), else: %{}
end
```

#### 4. The sidecar delivery path

**File**: `lib/statifier_ui/fixtures/sidecar.ex`
**Changes**: one attribute and one `with` clause. `datasets` is a map of names
to free values, so `decode_section/2` applies unchanged.

```elixir
@known_top_level_keys ~w(version scenarios events datasets)
```

```elixir
with {:ok, version_diagnostics} <- validate_version(json, source),
     {:ok, scenarios} <- decode_section(json, "scenarios"),
     {:ok, events} <- decode_section(json, "events"),
     {:ok, datasets} <- decode_section(json, "datasets") do
```

Moduledoc updated: the ignored-unknown-key sentence now names four known keys,
and a sentence records that `$duration` is rejected inside a dataset for the
same reason it is rejected inside a scenario.

#### 5. Tests

**Files**: `test/statifier_ui/fixtures_test.exs`,
`test/statifier_ui/fixtures/sidecar_test.exs`,
`test/statifier_ui/fixtures/convergence_test.exs`,
`test/support/fixtures/expressions_source.ex` (new),
`test/support/fixtures/expressions.fixtures.json` (new),
`test/support/fixtures/behaviour_only_source.ex` (new)

- `fixtures_test.exs`: a `describe "new/1 - datasets"` block mirroring the
  scenario cases - a valid bundle, the `%{}` default, a non-map rejection, an
  atom key at depth naming the dataset in its path, and the duration
  rejection reporting `{:duration_in_dataset, path}`. A `dataset_names/1`
  sorting case. A case asserting `from_source/1` on `EventsOnlySource` (which
  implements neither new callback) still returns `datasets: %{}` - that is the
  backward-compatibility guarantee made mechanical.
- `sidecar_test.exs`: the `extended.fixtures.json` unknown-key assertion flips
  to `["expressions", "nonsense"]`, and the "scenarios and events load as
  empty maps" test grows an assertion that `datasets` loaded with two entries.
  A new case asserting a `$duration` inside a dataset is rejected, following
  the existing temp-file idiom at `:135-162`.
- `behaviour_only_source.ex` (new): a module declaring
  `@behaviour StatifierUI.Fixtures.Source` **by hand**, without `use`,
  implementing only `scenarios/0` and `example_events/0`. Its existence is the
  backward-compatibility guarantee: it must compile warning-free under
  `warnings_as_errors: true`, which is exactly what `@optional_callbacks`
  buys, and `from_source/1` on it must return `datasets: %{}`. Every host
  module in the wild that wrote `@behaviour` instead of `use` is represented
  by this one file.
- New third convergence pair. `ExpressionsSource` and
  `expressions.fixtures.json` describe the same bundle - two datasets, and (in
  Phase 2) one expression - so that the convergence comparison has non-empty
  values on the new fields rather than comparing `%{} == %{}`. Both existing
  convergence tests grow `assert source.datasets == sidecar.datasets`.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes (`mix quality`), including the 80% coverage
      floor and `warnings_as_errors`
- [x] `test/statifier_ui/fixtures/convergence_test.exs` compares `datasets` on
      all three pairs and the third pair's datasets are non-empty
- [x] `test/support/fixtures/events_only_source.ex` compiles unchanged, and a
      test asserts `from_source(EventsOnlySource)` yields `datasets: %{}`
- [x] `test/support/fixtures/behaviour_only_source.ex` exists, declares
      `@behaviour StatifierUI.Fixtures.Source` without `use`, implements only
      the two original callbacks, and compiles with no warning under
      `warnings_as_errors: true`; a test asserts `from_source/1` on it yields
      `datasets: %{}`
- [x] `extended.fixtures.json` loads with `:unknown_key` diagnostics for
      `["expressions", "nonsense"]` only

#### Manual Verification:
- [ ] The dataset-versus-scenario distinction in the `StatifierUI.Fixtures`
      moduledoc reads as teachable to someone who has not read ADR-0006
- [ ] Error tuples for a malformed dataset name the dataset, not just the key,
      when read in a terminal

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 2: Expressions on both delivery paths

### Overview

The fourth map. An expression entry is an object, not a free value, so it gets
its own validation and its own decoder - but the validation still lives in
`Fixtures.new/1`, so the two paths still converge through one implementation.

### Changes Required:

#### 1. The struct and its validation

**File**: `lib/statifier_ui/fixtures.ex`
**Changes**: field, types, `new/1` option, validation, accessors.

```elixir
@typedoc "The name of a fixture expression."
@type expression_name :: String.t()

@typedoc """
A free-standing expression fixture: a predicator `"source"` string and an
optional `"expect"` map keyed by dataset name (ADR-0006). Keys beyond those
two are preserved verbatim.
"""
@type expression :: %{required(String.t()) => term()}

defstruct scenarios: %{}, events: %{}, datasets: %{}, expressions: %{}, diagnostics: []
```

`validate_expressions/1` enforces, and only enforces:

- the container is a map, else `{:invalid_expressions, other}`
- each name is a binary, else `{:invalid_expression_name, name}`
- each entry is a map, else `{:invalid_expression, name}`
- `"source"` is present and a binary, else `{:invalid_expression_source, name}`
- `"expect"`, when present, is a map whose keys are all binaries, else
  `{:invalid_expect, name}`
- every key in the entry is a binary (so the behaviour path cannot express an
  atom-keyed entry a sidecar could not), else
  `{:invalid_expression_key, name, key}`

`"expect"` **values** are not key-walked and not otherwise constrained: they
are predicator values, and a duration is a legal one (unlike inside a
datamodel). Entry keys other than `"source"` and `"expect"` are preserved as
they arrived.

Accessors:

```elixir
@spec expression(t(), expression_name()) :: {:ok, expression()} | :error
@spec expression_names(t()) :: [expression_name()]   # sorted
@spec expect(t(), expression_name(), dataset_name()) :: {:ok, term()} | :error
```

`expect/3` returns `:error` for both "no such expression" and "no expectation
stated for that dataset", which is the ADR's own semantics: an absent key means
no expectation is stated, and that is not an error condition.

#### 2. The behaviour

**File**: `lib/statifier_ui/fixtures/source.ex`
**Changes**: as Phase 1, for `expressions/0`.

```elixir
@type expressions :: %{optional(String.t()) => map()}
@callback expressions() :: expressions()
@optional_callbacks datasets: 0, expressions: 0
```

with the injected default and `defoverridable scenarios: 0, example_events: 0,
datasets: 0, expressions: 0`. `from_source/1` gains
`expressions: optional_callback(module, :expressions)`.

#### 3. The sidecar decoder

**File**: `lib/statifier_ui/fixtures/sidecar.ex`
**Changes**: `"expressions"` joins `@known_top_level_keys`, and a dedicated
decoder handles the entry shape. `decode_map_of_values/2` cannot be reused:
running `Value.decode/1` over a whole entry object would try to interpret the
entry itself as a value.

```elixir
@known_top_level_keys ~w(version scenarios events datasets expressions)

@spec decode_expressions(map()) :: {:ok, map()} | {:error, term()}
defp decode_expressions(json) do
  case Map.get(json, "expressions", %{}) do
    map when is_map(map) ->
      Enum.reduce_while(map, {:ok, %{}}, fn {name, entry}, {:ok, acc} ->
        case decode_expression_entry(name, entry) do
          {:ok, decoded} -> {:cont, {:ok, Map.put(acc, name, decoded)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    other ->
      {:error, {:invalid_section, "expressions", other}}
  end
end
```

`decode_expression_entry/2` passes `"source"` through untouched (it is source
text, never a tagged value), runs each `"expect"` value through
`StatifierUI.Value.decode/1` so `{"$undefined": true}` and the other three
tags mean here what they mean everywhere else, and copies any other key
through verbatim. Structural rejections are left to `Fixtures.new/1`; the
decoder's only errors are decode failures, reported as
`{:invalid_value, "expressions", name, reason}` to match the existing
`decode_map_of_values/2` error shape.

#### 4. Tests

**Files**: `test/statifier_ui/fixtures_test.exs`,
`test/statifier_ui/fixtures/sidecar_test.exs`,
`test/statifier_ui/fixtures/convergence_test.exs`,
`test/support/fixtures/expressions_source.ex`,
`test/support/fixtures/expressions.fixtures.json`

- One `describe "new/1 - expressions"` case per validation rule above, each
  named for the rule.
- `expect/3` cases: a stated expectation, an unstated one for a real dataset,
  an unknown expression.
- Sidecar: `extended.fixtures.json`'s unknown-key assertion flips to
  `["nonsense"]`; a case asserting `expressions` loaded with the
  `is-adult-us` entry and its two expectations; a case asserting a
  `{"$undefined": true}` expect value decodes to `:undefined`; a case
  asserting a `$duration` expect value decodes (proving expect values are not
  key-walked).
- The third convergence pair gains its expression - written in Elixir terms in
  the source module (`:undefined`, a real `Date`) and in `$`-tagged JSON in
  the sidecar - and both new fields join the compared field list in all three
  convergence tests.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes
- [x] `extended.fixtures.json` loads with exactly one `:unknown_key`
      diagnostic, for `"nonsense"`
- [x] The convergence test compares all four maps across three pairs, and the
      third pair's `expressions` map is non-empty on both sides and contains at
      least one `$`-tagged expect value
- [x] A sidecar declaring `"version": 1` with both new keys loads without a
      version diagnostic (ADR-0006's version-stays-1 decision, made mechanical)

#### Manual Verification:
- [ ] The `expect` semantics read correctly in the moduledoc: an absent key is
      "no expectation stated", not "expected to be absent"
- [ ] Preserving unrecognized entry keys verbatim looks right against a
      hand-written sidecar carrying a future key

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 3: Lint - guard matching and dangling expect keys

### Overview

ADR-0006's two lint findings, in a pure module that reads a compiled
`%Statifier.Machine{}` and a `%StatifierUI.Fixtures{}` and returns
diagnostics. Both findings are warnings. Matching is byte equality on source
text; indexes appear only as an output pointer, never as a matching key.

### Changes Required:

#### 1. The lint module

**File**: `lib/statifier_ui/fixtures/lint.ex` (new)
**Changes**: a new pure module returning `StatifierUI.Fixtures.diagnostic/0`
lists, reusing the existing diagnostic map shape rather than inventing a
second one.

```elixir
@doc """
Expression names matched to the `t_index` of every transition whose guard
source text is byte-equal to the expression's source.

Matching is **byte equality on source text only** (ADR-0006). The `t_index`
values in the result are an output - a pointer for a consumer that wants to
annotate a transition - never an input to the match: they are document-order
positions that shift under any edit above the transition, so an index-matched
fixture would silently pin the wrong guard.
"""
@spec guard_matches(Fixtures.t(), Statifier.Machine.t()) ::
        %{optional(Fixtures.expression_name()) => [non_neg_integer()]}
```

Guard source is read from the compiled machine's transitions:
`{:compiled, _compiled, source}` yields `source`; `{:static, _term}` and `nil`
carry no author-written expression text and are skipped. This is the
`Statifier.Machine.expr/0` contract at
`deps/statifier/lib/statifier/machine.ex:161`. No SCXML re-parse, no engine
change (ADR-0002).

```elixir
@spec unmatched_expressions(Fixtures.t(), Statifier.Machine.t()) :: [Fixtures.diagnostic()]
@spec dangling_expect_keys(Fixtures.t()) :: [Fixtures.diagnostic()]
@spec lint(Fixtures.t(), Statifier.Machine.t() | nil) :: [Fixtures.diagnostic()]
```

- `unmatched_expressions/2` emits `kind: :unmatched_expression` per expression
  with no byte-equal guard. The moduledoc records why this is a warning and
  not an error, in ADR-0006's words: free-standing expressions are a feature of
  the contract, so unmatched must be a legal state, and the warning exists for
  the near-miss case where a guard's text has drifted (reformatting included -
  matching is exact).
- `dangling_expect_keys/1` emits `kind: :dangling_expect_dataset` per `expect`
  key naming no dataset, with `path: [name, "expect", dataset_name]`. It needs
  no machine, so it is callable on a bundle alone.
- `lint/2` composes both and sorts by `path` so output is stable and
  byte-comparable, per ADR-0005's canonical-order habit. `nil` for the machine
  runs only the machine-free checks.

Every returned diagnostic uses the existing `%{kind:, message:, path:,
source:}` map. `source` is `nil` here - lint runs on an already-loaded bundle
and does not know the file - unless the bundle's own diagnostics carry one, in
which case that value is propagated.

#### 2. Tests

**File**: `test/statifier_ui/fixtures/lint_test.exs` (new)

Charts are triple-quoted heredocs at 4-space base indentation, per CLAUDE.md,
compiled through statifier's public compile path and asserted structurally.
Cases:

- an expression whose source is byte-equal to a guard matches, and the match
  names the guard's `t_index`
- an expression differing only by whitespace or quoting does **not** match,
  and produces an `:unmatched_expression` warning - this is the test that pins
  "matching is exact" as behavior rather than prose
- a chart edit that shifts `t_index` values (a state inserted above) leaves
  the match on the same guard - the regression test for ADR-0006's central
  argument against index matching
- a guard written as a static literal, and a transition with no `cond`, are
  both skipped without error
- a bundle with no expressions lints clean against any chart
- a dangling `expect` key produces exactly one finding naming the expression
  and the missing dataset
- every finding's kind is a warning kind; no lint path returns `{:error, _}`

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes
- [x] The `t_index`-shift test passes: matching survives an edit that
      renumbers transitions
- [x] A whitespace-only difference produces an `:unmatched_expression`
      diagnostic and no match
- [x] `StatifierUI.Fixtures.Lint` has no `{:error, _}` return path anywhere in
      its public API (checked by the specs and by a test asserting lint on a
      deliberately broken-looking bundle still returns a list)
- [x] No `Predicator.*` call appears in this module (it reads source strings
      out of the machine; it does not evaluate), so `mix.exs` still needs no
      change in this phase

#### Manual Verification:
- [ ] Diagnostic messages read usefully in a terminal - an unmatched
      expression message should make the near-miss case obvious
- [ ] The `guard_matches/2` output shape is what a truth-table or
      guard-annotation consumer (`sui-t0a`) would actually want

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 4: The executable-expectations runner

### Overview

Every `expect` entry, evaluated against its dataset, compared to its expected
value, with a failure mode a host's test suite goes red on. This is ADR-0006's
direct countermeasure to the example-drift cost ADR-0003 accepted.

**A test helper, not a mix task.** The reasons, recorded because the
acceptance criteria asks for one of the two and the choice should not have to
be re-derived:

1. ADR-0006 states the goal as running "every expectation in the host's suite"
   (`docs/adr/0006-datasets-and-expression-fixtures.md:103-105`). Drift has to
   fail *the host's* build. A mix task fails only when someone runs it, which
   is the "documentation nobody reads" failure mode this repo's `.quality.exs`
   preamble already names for its own gate.
2. `lib/mix/tasks/` does not exist, and `mix.exs` has no `aliases/0`. Creating
   a task means creating a distribution surface: `package files:` is `~w(lib
   mix.exs README.md LICENSE CHANGELOG.md)`, so a task under `lib/` would ship
   into every consumer's build and appear in their `mix help`, for a feature
   that is opt-in per host.
3. The bead pairs this runner with `st-hbdr`, which publishes chart-author
   test helpers in statifier-ex's `lib/`. Matching that shape keeps the pair
   coherent.
4. A helper composes: a host that does want a task can write a three-line one
   over the same public function. The reverse is not true.

A mix task remains a cheap later addition if a corpus or CLI setting asks for
one; nothing here forecloses it.

### Changes Required:

#### 1. Declare the predicator dependency

**File**: `mix.exs`
**Changes**: this phase is the first to call `Predicator.*` from `lib/`.
Without a direct declaration, Elixir emits a cross-application warning and
`warnings_as_errors: true` fails the gate.

```elixir
{:predicator, "~> 9.0"},
```

added to `deps/0` beside `statifier_dep()`, matching the constraint statifier
2.0.0 itself declares (`mix.lock:29`). It is not optional: the runner is core,
and predicator is already a hard transitive requirement, so this declares a
fact rather than adding a dependency. `mix.lock` is expected to be unchanged
by this; if it moves, that is a resolution change worth reading before
committing.

#### 2. The runner

**File**: `lib/statifier_ui/fixtures/expectations.ex` (new)

```elixir
@typedoc """
One expectation's outcome. `:match` and `:mismatch` are comparisons that
happened; `:error` is an evaluation that returned `{:error, e}` and
`:missing_dataset` is an `expect` key naming no dataset.
"""
@type result :: %{
        expression: String.t(),
        dataset: String.t(),
        source: String.t(),
        expected: term(),
        actual: term() | nil,
        status: :match | :mismatch | :error | :missing_dataset,
        error: struct() | nil
      }

@spec run(Fixtures.t(), keyword()) :: [result()]
@spec check(Fixtures.t(), keyword()) :: :ok | {:error, [result()]}
@spec check!(Fixtures.t(), keyword()) :: :ok
```

- `run/2` evaluates every `(expression, dataset)` pair for which an
  expectation is stated, in sorted expression-then-dataset order so output is
  stable. It never raises and never returns an error tuple: an evaluation
  failure is a `:error` result carrying the predicator error struct, per
  CLAUDE.md's errors-are-values rule and ADR-0006's "a mismatch or an
  evaluation error is data the UI and the test helper render".
- Evaluation is `Predicator.evaluate(source, dataset, opts)`. The dataset is
  already a string-keyed map, which is `Predicator.Types.context/0` as
  authored. `opts` forwards `:functions` and `:providers` so a host whose
  expressions call its own function providers can supply them; nothing else is
  forwarded.
- Comparison canonicalizes both sides through `StatifierUI.Value.encode/1` and
  then compares with `===`. This is the phase's one subtle decision and it has
  a concrete reason: `Predicator.evaluate("3d")` yields a seven-key duration
  map while a `$duration` expectation decodes to all eight
  (`lib/statifier_ui/value.ex:190-192`), so a bare `==` would report a
  spurious mismatch on every duration-valued expectation. `===` on the encoded
  forms also keeps `1` and `1.0` distinct, which matters because JSON does.
  If either side fails to encode (a value outside predicator's closed domain),
  the result is `:error` carrying `{:unsupported_value, term}`.
- A `expect` key naming no dataset is `:missing_dataset`, not an evaluation.
  It is the same fact `Lint.dangling_expect_keys/1` reports; the runner
  surfaces it as a result so a host running only the runner still sees it.
- `check/2` partitions `run/2`'s results: anything not `:match` is a failure.
  `:missing_dataset` counts as a failure here even though lint treats it as a
  warning - the two are different questions. Lint asks "is this bundle
  well-formed enough to author against", where ADR-0006 fixes warning
  severity; the runner asks "did every stated expectation get checked", and an
  expectation that was never evaluated was not checked.
- `check!/2` raises `StatifierUI.Fixtures.ExpectationError` with a formatted,
  multi-line message naming each failure's expression, dataset, expected,
  actual, and error. It raises a plain exception rather than
  `ExUnit.AssertionError` so nothing under `lib/` depends on ExUnit being
  loaded - the same optional-dependency discipline `.Kino` and
  `.Phoenix.LiveView` get, applied to the test framework.

**File**: `lib/statifier_ui/fixtures/expectation_error.ex` (new) - or
`defexception` inside the runner module if doctor's moduledoc rule is
satisfied either way. A separate file is preferred: the repo's convention is
one module per file under `lib/statifier_ui/`.

#### 3. Tests

**File**: `test/statifier_ui/fixtures/expectations_test.exs` (new)

- ADR-0006's own example end to end: the `is-adult-us` expression over the
  `minor` and `adult-us` datasets from `extended.fixtures.json`, both
  expectations satisfied, `check/2` returns `:ok`. **This is the "fail on
  drift" guarantee running in this repo's own suite** - edit either dataset or
  either expectation and the suite goes red.
- A deliberately drifted bundle: `check/2` returns `{:error, [result]}` with
  `status: :mismatch` and both values reported; `check!/2` raises and the
  message names the expression and dataset.
- An expression referencing an unbound root: `status: :error` carrying
  `%Predicator.Errors.UndefinedVariableError{}` - and a sibling case for a
  missing *nested* path expecting `{"$undefined": true}`, which succeeds.
  These two cases pin the asymmetry recorded under Key Discoveries, so a later
  reader does not file it as a bug.
- A duration-valued expectation written as `$duration` against an expression
  evaluating to a seven-key duration: `:match`. This is the regression test
  for the canonicalizing comparison.
- An `expect` key naming no dataset: `:missing_dataset`, and `check/2` fails.
- A bundle with no expressions: `run/2` returns `[]`, `check/2` returns `:ok`.
- Result ordering is stable across runs.
- `:functions` forwarding: an expression calling a host-supplied function
  evaluates.

### Success Criteria:

#### Automated Verification:
- [x] Full quality gate passes, including dialyzer over the new `Predicator`
      call sites
- [x] `mix.exs` declares `{:predicator, "~> 9.0"}`, and `git diff mix.lock`
      shows no change to the resolved version or checksum of any package -
      declaring a dependency that already resolves transitively should move
      nothing. A resolver-metadata-only touch is acceptable; any actual
      dependency-graph change is read and called out in the commit message
      rather than committed silently
- [x] The repo's suite runs `check/2` over `test/support/fixtures/extended.fixtures.json`
      and asserts `:ok` - the drift alarm is armed on a real file
- [x] A drifted-expectation test asserts `check!/2` raises
      `StatifierUI.Fixtures.ExpectationError`
- [x] The duration canonicalization test passes (a `$duration` expectation
      matching a seven-key evaluated duration)
- [x] No module under `lib/` references `ExUnit`

#### Manual Verification:
- [ ] The `check!/2` failure message is readable enough to act on without
      opening the fixture file
- [ ] A host wiring `check!/2` into one ExUnit test gets a useful failure, not
      a wall of inspected terms
- [ ] The helper-over-mix-task choice still looks right once the failure
      output is in front of a human

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Phase 5: Documentation and changelog

### Overview

The shape has stopped moving, so the prose can describe it. Moduledocs were
updated inside each phase; this phase covers the standalone documents.

### Changes Required:

#### 1. Architecture

**File**: `docs/architecture.md`
**Changes**:

- "The fixtures contract" (heading at `:106`, body `:108-169`): the bundle is
  described at `:127-128` as "a named scenario datamodel plus example events".
  Add a paragraph after the four-features list (`:133-142`) introducing
  datasets and expressions in ADR-0006's terms - what each is, why datasets
  are shared across expressions rather than inlined, and that guard matching is
  by source text only. Extend the deferral sentence at `:167-169` to cite
  ADR-0006 alongside ADR-0003 and ADR-0005.
- Add the new consumers to the same section: lint and the executable-expectations
  runner, one line each, citing ADR-0006.
- "What exists today" (`:67-80`): the literal count "eleven core modules" at
  `:69` becomes the new count, and the bulleted inventory gains
  `StatifierUI.Fixtures.Lint` and `StatifierUI.Fixtures.Expectations` with
  one-line descriptions in the existing style.

#### 2. Wire format

**File**: `docs/wire-format.md`
**Changes**: deliberately minimal. The `fixtures` field carries the sidecar's
decoded object **verbatim** (`:370-373`) and the sidecar version stays `1`, so
the additive keys ride the wire with no format change - which is ADR-0006's
version argument arriving where it pays off. Two edits only:

- `:370-373`: note that the carried object may contain ADR-0006's `datasets`
  and `expressions` keys alongside ADR-0003's `scenarios` and `events`, and
  that this producer neither constructs nor validates them, exactly as it does
  not for the other two.
- References (`:915-917`): add an ADR-0006 entry beside the ADR-0003 one.

The section must **not** claim expression fixtures are normatively part of the
spec. ADR-0006 carries that as an open question; the wording stays descriptive
("may contain") rather than conformance-bearing ("a conformant producer must").

#### 3. Changelog fragment

**File**: `changelog.d/sui-bob.md` (new)
**Changes**: an `### Added` section, one line per user-visible addition, per
`changelog.d/README.md`'s convention - the two struct fields, the two
behaviour callbacks, the lint module, the expectations runner, and the direct
predicator dependency.

### Success Criteria:

#### Automated Verification:
- [ ] Full quality gate passes (format check-mode covers markdown only
      incidentally, but the suite and doctor stages must stay green)
- [ ] `changelog.d/sui-bob.md` exists and uses only Keep-a-Changelog headings
- [ ] `docs/architecture.md`'s module count matches the actual count of
      modules under `lib/statifier_ui/` named in its inventory

#### Manual Verification:
- [ ] The architecture section teaches the scenario/dataset distinction rather
      than restating it
- [ ] The wire-format edit reads as descriptive, not normative, so it does not
      pre-empt ADR-0006's second open question
- [ ] Cross-references to ADR-0006 are by number, per ADR-0001's convention
- [ ] **Terminology firewall.** This repo is public and has no scanner of its
      own; the phrasing table and the pre-push scan command live in the private
      umbrella at `docs/terminology-firewall.md`, one level above this
      checkout. Run that scan over the changed files before pushing. It is
      manual because the command is not available from inside this repo, not
      because it is optional - no employer or product terminology may appear in
      any changed file, commit message, or branch name.

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

## Testing Strategy

### Unit Tests:

- `test/statifier_ui/fixtures_test.exs` - validation of both new maps, one
  test per rule, error tuples asserted structurally with full path lists in the
  existing style (`{:invalid_key, :ok, ["s", "a", "b", 0]}` at `:37`).
- `test/statifier_ui/fixtures/sidecar_test.exs` - decoding, the flipped
  `extended.fixtures.json` unknown-key assertions, `$`-tagged expect values,
  and the `$duration`-in-a-dataset rejection using the existing temp-file
  idiom.
- `test/statifier_ui/fixtures/convergence_test.exs` - the load-bearing test.
  Both new fields join the compared field list on all three pairs, and a third
  pair exists precisely so the new fields are compared with non-empty values
  rather than `%{} == %{}`.
- `test/statifier_ui/fixtures/lint_test.exs` - byte-equality matching, the
  `t_index`-shift regression, whitespace non-matching, dangling `expect` keys,
  and warning-only severity.
- `test/statifier_ui/fixtures/expectations_test.exs` - ADR-0006's own example
  passing, a drifted bundle failing, evaluation errors as values, the
  unbound-root versus missing-nested-path asymmetry, duration canonicalization,
  and stable ordering.

Key edge cases, listed because each one is a place a naive implementation goes
wrong:

- a duration inside a dataset (rejected, atom keys) versus a duration as an
  `expect` value (accepted, it is a value)
- an `expect` value of `{"$undefined": true}` versus a JSON `null` - distinct,
  per ADR-0005
- an `expect` map covering a subset of datasets - legal, not a finding
- an expression matching more than one guard with identical source text
- a host module implementing the behaviour without `use`, and one implementing
  it with `use` but overriding nothing
- a sidecar with `datasets` but no `expressions`, and the reverse

### Manual Testing Steps:

1. Load `test/support/fixtures/extended.fixtures.json` in IEx and inspect the
   struct; confirm four populated maps and one `:unknown_key` diagnostic.
2. Edit an `expect` value in that file to a wrong belief, run the suite, and
   confirm it goes red with a message naming the expression and dataset. Revert.
3. Compile a small chart with a guard, author an expression with byte-equal
   source, and confirm `Lint.guard_matches/2` finds it; add a space to the
   guard and confirm the match degrades to an `:unmatched_expression` warning
   rather than an error.
4. Insert a state above that transition, recompile, and confirm the match still
   points at the same guard - the behavior ADR-0006 chose source-text matching
   to get.
5. Read `docs/architecture.md`'s fixtures section start to finish and check
   that a reader who has not read ADR-0006 can tell a dataset from a scenario.

## References

- Bead: `sui-bob` (blocks `sui-t0a`, the truth-table rendering component)
- Spec: `docs/adr/0006-datasets-and-expression-fixtures.md` (accepted
  2026-08-16)
- `docs/adr/0003-fixtures-as-the-example-data-contract.md` - the two-maps,
  two-delivery-paths, one-struct contract this extends
- `docs/adr/0005-language-neutral-trace-wire-format.md` - the `$`-prefixed
  value encoding, canonical ordering, and the additive-change versioning rule
  ADR-0006 adopts for the sidecar
- `docs/adr/0002-adopt-upstream-decisions-by-reference.md` - the engine is not
  modified from here; predicator evaluation is `{:ok, v} | {:error, e}`
- Existing implementation: `lib/statifier_ui/fixtures.ex:83` (`new/1`, the one
  validation implementation), `lib/statifier_ui/fixtures/sidecar.ex:28`
  (`@known_top_level_keys`), `lib/statifier_ui/fixtures/source.ex:33`
  (`__using__` defaults), `lib/statifier_ui/value.ex` (the ADR-0005 codec)
- Engine seams used: `deps/statifier/lib/statifier/machine.ex:161`
  (`expr/0` retains guard source text),
  `deps/statifier/lib/statifier/machine/transition.ex:79` (`:cond`)
- Predicator API: `deps/predicator/lib/predicator.ex:178-183`
  (`evaluate/3`), `deps/predicator/lib/predicator/types.ex:66-76` (`value/0`),
  `:89` (`context/0`), `deps/predicator/lib/predicator.ex:619-626` (the
  unbound-root rewrite)
- Prior scope exclusions this bead inherits:
  `docs/plans/260816-sui-t36.2-fixtures-core-and-shape-inference.md:153-156,176-177`,
  `docs/plans/260822-sui-t36.7-datamodel-explorer-pane.md:222-223`

## Open Questions

Recorded, not resolved. None blocks implementation; each has a defensible
default chosen above and reversible either way.

1. **Unrecognized keys inside an expression entry.** ADR-0006 fixes the
   ignore-unknown-keys rule for *top-level* sidecar keys and calls it
   load-bearing, but says nothing about a key inside an expression entry
   beyond `"source"` and `"expect"`. Three readings are available: preserve
   verbatim (chosen here - lossless, forward-compatible, no new diagnostic
   kind), preserve with an `:unknown_key` diagnostic at a deeper path, or
   reject. Needs a contract ruling; the plan takes the least destructive
   option meanwhile.
2. **A dataset cannot carry a duration value.** Datasets are validated as
   datamodels (string keys at every depth), and a predicator duration is a bare
   atom-keyed map, so `{"$duration": ...}` inside a dataset is rejected - the
   same restriction `test/support/fixtures/tagged_source.ex:8-19` records for
   scenarios. But a dataset is an evaluation *context*, not a datamodel a chart
   runs against, and `Predicator.Types.context/0` admits atom keys and duration
   values. An expression over duration-valued data therefore cannot be given a
   dataset. Whether datasets should relax to context rules, or keep datamodel
   rules for convergence, is a contract question ADR-0006 does not address.
   The plan keeps the datamodel rule, which is what the bead's convergence
   requirement asks for.
3. **`:missing_dataset` severity differs between lint and the runner.** Lint
   reports a dangling `expect` key as a warning, as ADR-0006 fixes. The runner
   counts it as a failure, on the reasoning that an expectation which was never
   evaluated was not checked. That is a defensible reading of two different
   questions, but it is an inference rather than a stated rule, and a host
   might reasonably want a strict-lint or lenient-runner switch.
4. **Whether `guard_matches/2` should take a machine or a list of guard
   sources.** Taking a `%Statifier.Machine{}` is convenient and needs no
   engine change, but it couples lint to the compiled-machine shape, which is
   the wrong direction for a repo whose stated boundary with the engine is a
   wire format. A guard-source-list arity would keep lint engine-free at the
   cost of making callers extract. The plan takes the machine, with the
   extraction isolated in one private function so the second arity is a small
   later addition.

## Deferred Manual Verification

Manual verification items are deferred during looped (--loop) execution and
surfaced here once, rather than blocking after each phase. Confirm these
before considering the plan fully landed.

### Phase 1

- [ ] The dataset-versus-scenario distinction in the `StatifierUI.Fixtures`
      moduledoc reads as teachable to someone who has not read ADR-0006
- [ ] Error tuples for a malformed dataset name the dataset, not just the key,
      when read in a terminal

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 2

- [ ] The `expect` semantics read correctly in the moduledoc: an absent key is
      "no expectation stated", not "expected to be absent"
- [ ] Preserving unrecognized entry keys verbatim looks right against a
      hand-written sidecar carrying a future key

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---

### Phase 3

- [ ] Diagnostic messages read usefully in a terminal - an unmatched
      expression message should make the near-miss case obvious
- [ ] The `guard_matches/2` output shape is what a truth-table or
      guard-annotation consumer (`sui-t0a`) would actually want

**Implementation Note**: Use `mix quality --profile loop` between edits; run
full `mix quality` as the phase gate. In interactive execution, pause here for
the human to confirm the manual testing before moving to the next phase. In
looped (`--loop`) execution, this phase's Automated Verification gates
advancement automatically (via `/wurk:commit --auto`), and Manual Verification
items are deferred and surfaced once at the end instead of blocking here.

---
