# Quality configuration for statifier-ui.
#
# Two ways to run:
#
#   mix quality                 - full gate: format, compile, credo, dialyzer,
#                                 deps audit, doc coverage, full test suite
#                                 with coverage. Run before every commit.
#
#   mix quality --profile loop  - inner loop while implementing: skips dialyzer
#                                 and coverage, runs only the tests covering
#                                 changed code. Use between edits.
#
# Agents: prefer `--format json --report -` when you want to route on results.
#
# There is no CI. This project has one contributor, and a workflow nobody reads
# the output of is worse than none - so the local gate carries the whole weight.
# Two things follow from that, and they are the reason this file is worth
# reading rather than copying:
#
#   1. Nothing here is allowed to be slow enough to skip. A gate that gets
#      routinely bypassed enforces nothing, and there is no second net behind
#      it.
#
#   2. The thresholds are the real ones. Where a number is lower than
#      statifier-ex's, the reason is written down at the number (see
#      .doctor.exs and coveralls.json) rather than left as drift for a later
#      reader to guess at.
#
# Coverage sits at 80%, not statifier-ex's 90%. Two honest reasons:
# the JavaScript hooks (CodeMirror, elkjs) are outside ExCoveralls entirely, so
# a meaningful slice of this package's behaviour is never in the measured
# number no matter how high it is set; and rendering code is verified by what
# it renders, which is assertion-level work, not line-count work. Treat the
# percentage as a floor against untested modules, not as evidence of coverage.
[
  compile: [
    warnings_as_errors: true
  ],

  # Check-mode, not reformat-mode (sui-b5y, fleet-wide decision 2026-08-22):
  # a gate that rewrites drifting files cannot report drift as a finding, so
  # in CI unformatted code would pass instead of going red. Drift fails the
  # stage; run `mix format` yourself before committing.
  format: [
    check: true
  ],

  credo: [
    strict: true
  ],

  profiles: [
    loop: [
      stages: [:format, :compile, :credo, :test],
      test: [scope: :changed, coverage: false]
    ]
  ]
]
