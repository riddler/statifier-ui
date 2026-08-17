# ADR-0011: Exit and entry sets are sequences, not sets

Status: accepted (2026-08-17)

Amends ADR-0005 in part: the "Set-valued fields" sentence of its JSON
discipline.

## Context

ADR-0005's JSON discipline includes this sentence:

> Set-valued fields (configurations, exit/entry sets) serialize as arrays
> in a canonical order (ascending index), and object keys in lexicographic
> order, so two traces of the same run are byte-comparable.

Read literally, that sentence is wrong about exit and entry sets, and the
engine is the evidence. Statifier draws a set-versus-sequence distinction
the sentence collapses:

- `Statifier.Effect.Trace.ExitSet.indexes` and
  `Statifier.Effect.Trace.EntrySet.indexes` are typed
  `[non_neg_integer()]` - lists, not `MapSet`s - and their moduledocs say
  "in exit order" and "in entry order" respectively.
- `Selection.compute_exit_set/2` does return a `MapSet`, but
  `exit_states/2` then pipes it through `Statifier.Machine.exit_order/2`,
  which is descending index - "exit order, the exact reverse of document
  order" (`machine.ex`). Entry order is `Machine.document_order/2`,
  ascending index, "the mirror of `exit_states/2`'s `exit_order`"
  (`interpreter/exit_entry.ex`).
- By contrast, `Statifier.Effect.Trace.MacrostepStable.configuration`
  genuinely is `MapSet.t(non_neg_integer())` - an unordered set the engine
  never sequences.

For `trace.exit_set` specifically, an ascending sort is not merely a
re-ordering: it is the exact reverse of what happened. Verified live on a
nested chart, the producer emitted `{"indexes":[3,2,1]}` for an
inner/mid/outer exit, and `[4,0]` at interpreter shutdown. Sorting would
report an outer-to-inner exit of a run that exited inner-to-outer - the
order Appendix D's `exitStates` actually visits states, and the sequence
the event-log pane renders to a user stepping through a run.

The blast radius is one field. Entry sets are already ascending, so "keep
the engine's order" and "sort ascending" agree there; only `trace.exit_set`
is observably different under the two readings.

`docs/wire-format.md` already implements the correct behavior, and its
"Canonical order" section documented it as "a deliberate, narrow departure"
from ADR-0005. A spec that ships carrying a documented departure from its
own governing record is a standing invitation to "fix" the code to match
the record. ADR-0001 governs the mechanism for resolving that: an ADR is
amended by a new ADR that amends it in part, never by rewriting history.

## Decision

**Genuinely set-valued fields - `MapSet`s in the engine - serialize as
arrays in ascending canonical order. Engine-ordered sequences keep the
order the engine produced and are never re-sorted.**

Precisely: the `indexes` fields of `trace.exit_set` and `trace.entry_set`
are sequences in the engine's own emission order - descending index for
exit (inner-to-outer), ascending index for entry. `configuration`
(`trace.macrostep_stable`, `trace.done`, `effect.budget_exhausted`) remains
a genuine set and serializes ascending. Every other sequence field the spec
defines that is not identified as a genuine set likewise keeps the engine's
order.

ADR-0005's sentence is amended accordingly: its "canonical order (ascending
index)" applies to configurations and any other `MapSet`-backed field, not
to exit/entry sets. Everything else in ADR-0005 - the envelope, the value
codec, lexicographic object keys, the byte-comparability commitment -
stands unchanged.

Both exit and entry orders are deterministic for a given chart, fixtures,
and event script, so preserving them costs byte-comparability nothing - the
property the ascending-index wording existed to protect. The golden-trace
conformance mechanism is unaffected, and the existing golden fixture is
byte-unchanged by this record: it documents the behavior the producer
already has.

## Consequences

- `docs/wire-format.md`'s "Canonical order" section drops its departure
  framing and states the rule plainly, citing this record; the spec no
  longer disagrees with its governing ADR.
- ADR-0005's status line records the partial amendment, per ADR-0001; its
  body is untouched, so the original sentence remains visible as the path
  taken.
- Consumers must not assume `trace.exit_set` arrays are sorted; the order
  is meaningful (exit order), and a consumer that wants a set view sorts
  for itself.
- A second interpreter's conformance burden is stated honestly: it must
  emit exit and entry indexes in its own Appendix D visit order, not in a
  normalized order that hides a traversal bug from the golden-trace check.
- No code, fixture, or producer change accompanies this record; it aligns
  the recorded decision with the behavior the engine and producer already
  have.
