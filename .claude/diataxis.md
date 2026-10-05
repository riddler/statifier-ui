---
# The docs manifest the documentation tools read. Generated from the family's manifest
# table: change a key there and regenerate. The two prose lines below may be sharpened.
product: statifier_ui
family: statifier
audience: Elixir developers who show an execution to an operator
tone: "plain, second person, no marketing"
terminology:
  use:
    - execution
    - chart
    - document
    - revision
  avoid:
    - "run (noun)"
    - workflow instance
example_world: library-loan
docs_root: docs
quadrants:
  tutorials: docs/tutorials
  how_to: docs/guides
  reference: docs/reference
  explanation: docs/explanation
readme: README.md
reference_generator: ex_doc
publish: hexdocs
contributor_paths:
  - docs/adr
  - docs/plans
  - docs/spikes
  - docs/research
  - docs/design
  - docs/measurements
  - CLAUDE.md
executed_snippets:
  - test/statifier_ui/live/state_test.exs
  - test/statifier_ui/trace/projection_drift_test.exs
  - test/statifier_ui/trace/wire_format_payload_schema_test.exs
  - test/statifier_ui/trace/wire_format_spec_test.exs
  - test/packaging_test.exs
readme_max_lines: 250
---

Viewers and inspectors for executions: LiveView components and a Livebook kino over one wire format.
Examples are written in the library loan: a copy of a book lent to a patron, due, renewed, returned or lost.
