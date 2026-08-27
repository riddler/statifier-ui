# Per-fragment fixture bundles

How a reusable chart fragment carries its own executable examples, so a
palette entry can show a "test this step" panel of its own rather than
borrowing a whole chart's fixtures.

This is the convention `sui-13q` settles. It adds no new fixture shape:
everything below is the ADR-0003 bundle with ADR-0006's `datasets` and
`expressions` keys, addressed by **fragment name** instead of by chart path.
Read those two records for why the shapes are what they are; read this page
for how one travels with a fragment.

## The problem this solves

ADR-0003 pairs a bundle with a chart. A chart at `authorization.scxml`
carries `authorization.fixtures.json` beside it, and every consumer
downstream of the loader gets one `StatifierUI.Fixtures` struct whichever
delivery path produced it.

An embedder composing charts from a palette of reusable fragments has no such
file to sit beside. The fragment is a module in the host's code, or an entry
in a palette the host assembles at runtime, and the chart it will eventually
be dropped into does not exist yet. Its examples still want to travel with
it: an author picking "Authorize a card" out of a palette wants to see what
that step's guard evaluates to under a transaction inside the account's
budget and one over it, before committing to it and without authoring a
chart first.

`StatifierUI.Fixtures.Bundle` is that: a `StatifierUI.Fixtures` struct plus
the fragment's name and a record of where it came from.

## The convention

A fragment supplies its bundle by answering a zero-arity callback -
`fixtures/0` by default - with any of four spellings.

| Spelling | Recognized by | Validated through |
|---|---|---|
| `%StatifierUI.Fixtures{}` | the struct | already validated at construction |
| `%{scenarios: ..., events: ..., datasets: ..., expressions: ...}` | **atom** top-level keys | `StatifierUI.Fixtures.new/1` |
| `%{"version" => 1, "datasets" => ...}` | **string** top-level keys | `StatifierUI.Fixtures.Sidecar.from_json/2` |
| `"palette/authorize.fixtures.json"` | a binary path | `StatifierUI.Fixtures.Sidecar.load/1` |

The atom-versus-string top-level key is the whole discriminator. Atom keys
are the Elixir spelling a host writes by hand in a module; string keys are
the JSON spelling that survives a file. ADR-0003 requires both delivery paths
to converge on one struct rather than one to be primary, and this keeps that
true one level up. A map mixing the two is rejected as `:mixed_bundle_keys`
rather than guessed at.

**Unknown top-level keys behave differently by spelling, on purpose.** The
JSON spelling keeps the sidecar's ignore-unknown-keys discipline (ADR-0006),
so a file written by a newer producer still loads and reports what it
ignored. The Elixir spelling rejects an unknown atom key, because an atom key
in a host's own module is compiled code the author is looking at, and a
silently ignored `:datsets` typo there is a bundle reporting zero datasets
with no reason why. Forward compatibility is a property of a wire format, not
of a function call.

A fragment that ships no examples at all is never an error. Discovery reports
it as an absence.

## Fragment names and invoke types are two namespaces

A fragment name here is spelled with a **dot** - `myapp.authorize`. The
family's invoke types are spelled with a **colon** - `myapp:authorize`. That
is not a typo on either side, and the difference is load-bearing.

The operator's ruling of 2026-08-27 settles it:

> D5) two namespaces, with a documented one-to-one mapping convention.

So: **two namespaces**, and this is the documented mapping convention.

- A **fragment name** (`myapp.authorize`) names an entry in a palette. It is
  the key `Bundle.load/2` and `Bundle.discover/1` are given, the name a
  bundle is reported under, and - via `name_from_path/1` - the stem of a
  sidecar filename. It is an *authoring-surface* identifier: what an author
  picks out of a palette.
- An **invoke type** (`myapp:authorize`) names something the engine can
  invoke at runtime. It is an *execution* identifier, resolved through the
  per-session invoke registry, and it is statifier-ex's contract, not this
  package's.

Both spellings are `<namespace><separator><local name>`, and the mapping
between them is one to one in both directions: **swap the separator, change
nothing else**. `myapp.authorize` is the palette entry for the invoke type
`myapp:authorize`; `myapp:capture` is invoked by the fragment named
`myapp.capture`. The namespace segment and the local name are identical
character for character, so the mapping is total and mechanical - there is
no lookup table, and there is nothing for a host to configure.

Two consequences worth stating, because they are what the convention buys:

- **A dot is the only separator a fragment name uses**, and a colon never
  appears in one. Filenames are why: a sidecar is named for its fragment, and
  a dot survives every filesystem and every archive format a palette travels
  through. A fragment name carrying more than one dot has no invoke
  counterpart under this convention.
- **A fragment need not be invoke-backed at all.** A fragment that expands to
  ordinary SCXML rather than to an `<invoke>` has a name and no invoke type,
  and that is not a gap - the mapping is one to one over the invoke-backed
  fragments, not over every palette entry. Nothing here requires a host to
  mint an invoke type for a fragment that does not need one.

Neither namespace is derived from the other at runtime. This package never
turns a fragment name into an invoke type or back; the convention is a rule
for humans naming things, so that a reader seeing `myapp.authorize` in a
palette and `myapp:authorize` in a trace knows without asking that they are
the two faces of one step.

## Wiring a palette entry

A host's fragment type - a block type, a step type, whatever the host calls
it - answers the callback:

The corpus below is the card-processing one, deliberately **not** the
signup-wizard corpus that
`test/support/fixtures/expressions.fixtures.json` carries and ADR-0006
illustrates with. A fragment's bundle is self-contained by construction (see
the last bullet of this page), so a fragment gets the corpus its own domain
calls for; the two are canonical example domains, not a primary and a
variant. Both stay inside the family's two domains - card processing, and a
signup wizard with A/B testing - and nothing here reads a chart-level corpus
to build a fragment-level one.

```elixir
defmodule MyApp.Blocks.Authorize do
  @doc "Executable examples for this palette entry."
  def fixtures do
    %{
      datasets: %{
        "within-budget" => %{
          "transaction" => %{"amount" => 14, "currency" => "USD"},
          "account" => %{"budget_remaining" => 500}
        },
        "over-budget" => %{
          "transaction" => %{"amount" => 900, "currency" => "USD"},
          "account" => %{"budget_remaining" => 500}
        }
      },
      expressions: %{
        "exceeds-budget" => %{
          "source" => "transaction.amount > account.budget_remaining",
          "expect" => %{"within-budget" => false, "over-budget" => true}
        }
      }
    }
  end
end
```

Load one fragment's bundle directly:

```elixir
{:ok, bundle} =
  StatifierUI.Fixtures.Bundle.load("myapp.authorize", MyApp.Blocks.Authorize.fixtures())
```

Or discover every fragment's bundle across the palette at once:

```elixir
palette = %{
  "myapp.authorize" => MyApp.Blocks.Authorize,
  "myapp.capture" => MyApp.Blocks.Capture,
  "myapp.assign_variant" => MyApp.Blocks.AssignVariant,
  "myapp.signup" => MyApp.Blocks.Signup
}

discovery = StatifierUI.Fixtures.Bundle.discover(palette)

discovery.bundles  # loaded, sorted by name
discovery.without  # ["myapp.signup"] - ships no examples, which is fine
discovery.errors   # [{name, reason}] - meant to load, did not
```

Discovery is never all-or-nothing. One fragment's malformed bundle is
reported against that fragment's name and every other fragment still loads,
because a palette is exactly the setting where one bad entry hiding every
good one is least useful. A callback that *raises* is caught the same way,
for the same reason.

## Fragments that travel as files

The other delivery path needs no host code at all. Put a directory of
sidecars beside the fragments they describe, one file per fragment, named for
it:

```
palette/
  authorize.fixtures.json
  capture.fixtures.json
  README.md
```

```elixir
{:ok, discovery} = StatifierUI.Fixtures.Bundle.discover_dir("palette")

Enum.map(discovery.bundles, & &1.name)
#=> ["authorize", "capture"]
```

Each bundle is named after its file with the `.fixtures.json` suffix stripped
(`StatifierUI.Fixtures.Bundle.name_from_path/1`), so a fragment named
`myapp.assign_variant` is a file named
`myapp.assign_variant.fixtures.json`. Files that are not
sidecars are ignored rather than reported. The directory is not walked
recursively: a palette directory is a flat list of fragments, and a nested
one is a second palette rather than a deeper part of this one.

This is the corpus and CLI half of ADR-0003's two-paths rule, and it is what
lets a palette of fragments move between repositories - or to a non-Elixir
consumer - with nothing but plain JSON.

## The test panel

`StatifierUI.Fixtures.Bundle.Markdown.render/2` renders one bundle as its
panel, and `StatifierUI.Kino.test_panel/2` wraps that for a Livebook cell:

```elixir
{:ok, bundle} =
  StatifierUI.Fixtures.Bundle.load("myapp.authorize", MyApp.Blocks.Authorize.fixtures())

StatifierUI.Kino.test_panel(bundle)
```

The panel is deliberately both halves of the fixture contract at once:

- the **truth table** (`StatifierUI.TruthTable`) - what every expression
  actually evaluates to under every dataset, whether or not an expectation
  was stated;
- the **expectations** (`StatifierUI.Fixtures.Expectations`) - whether every
  stated `expect` value still holds.

Neither alone is enough for a fragment's panel. The table without the
expectations says what happens but not what was meant; the expectations
without the table confirm a stated belief while staying silent about every
expression that stated none.

For a whole palette, `render_discovery/2` (or
`StatifierUI.Kino.palette_panel/2`) prints one panel per bundle, then names
every entry that failed to load. Fragments that ship no examples are not
listed - a palette where most fragments carry none is the normal case, and
reciting them says nothing a reader can act on.

### The summary counts rather than passes

The expectations summary reports four counts and never collapses them into a
pass or a fail:

```
3 matched, 1 mismatched, 0 errored, 1 stated against a dataset this bundle does not carry.
```

That last count is not folded into the others because this package's two
consumers of the same fact already disagree about it.
`StatifierUI.Fixtures.Expectations.check/2` counts a dangling `expect` key as
a failure, since an expectation naming no dataset was never actually checked.
`StatifierUI.Fixtures.Lint` reports the same key as a warning, per ADR-0006's
severity reasoning. Both are right about their own question; a panel printing
one verdict would silently pick a side. Four counts let the reader see which
of the two situations they are in.

## Running a palette's expectations in a suite

The panel is the reading surface. The checking surface is the same one
ADR-0006 already fixed - `StatifierUI.Fixtures.Expectations.check!/2` - now
reachable per fragment, so a host's suite goes red naming the fragment whose
examples drifted rather than naming a chart:

```elixir
defmodule MyApp.PaletteFixturesTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Fixtures.Bundle
  alias StatifierUI.Fixtures.Expectations

  @discovery Bundle.discover(MyApp.Palette.types())

  test "no palette entry's bundle failed to load" do
    assert @discovery.errors == []
  end

  for bundle <- @discovery.bundles do
    @bundle bundle

    test "#{bundle.name} fixture expectations still hold" do
      Expectations.check!(@bundle.fixtures)
    end
  end
end
```

## What this convention does not decide

- **Matrix orientation.** `:orientation` is forwarded verbatim to
  `StatifierUI.TruthTable.Markdown.render/2`, whose own default stands.
  Nothing here states a preference between the two axes.
- **Inner keys of an expression entry.** Keys beyond `"source"` and
  `"expect"` are preserved verbatim, exactly as the sidecar loader already
  preserved them. This convention adds no reading of them and no rule about
  them.
- **The `:missing_dataset` severity split** between `Expectations.check/2`
  and `Fixtures.Lint`, described above. The panel shows both rather than
  reconciling them.
- **Duration-valued datasets**, which `StatifierUI.Fixtures` rejects for the
  convergence reason its moduledoc gives. A bundle loaded here is validated
  by exactly that code and inherits exactly that answer.
- **Whether a fragment's bundle may reference a chart-level one.** Every
  bundle here is self-contained. Sharing datasets across fragments, or
  overlaying a fragment's dataset on a chart's scenario, is ADR-0006's
  carried overlay question and is untouched by this record.
