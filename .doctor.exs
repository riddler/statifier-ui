# Doctor configuration for statifier-ui.
#
# Read by `mix doctor` and, in the quality gate, by ExQuality's Doctor stage.
#
# These thresholds are deliberately below statifier-ex's, which sits at 100% on
# every axis. That is a difference in what the two codebases are, not a
# difference in care:
#
#   - Moduledoc coverage stays at 100%. A module with no moduledoc is the one
#     doc failure that is always worth fixing, and it costs nothing to hold.
#
#   - Function doc and spec coverage sit at 75%. A component library's public
#     surface is largely LiveView and Kino callbacks - `render/1`,
#     `handle_event/3`, `update/2` - whose contracts are defined by the
#     behaviours upstream, and restating them here as `@spec` is noise that
#     documents nothing the behaviour does not already fix. The 75% floor is
#     what keeps the genuinely-public API - the functions a host calls
#     directly - documented and spec'd.
#
# Raise these when the shape of the codebase changes. Do not lower them to make
# a red run green; that is the signal doing its job.
%Doctor.Config{
  ignore_modules: [],
  ignore_paths: [],
  min_module_doc_coverage: 75,
  min_module_spec_coverage: 75,
  min_overall_doc_coverage: 75,
  min_overall_moduledoc_coverage: 100,
  min_overall_spec_coverage: 75,
  exception_moduledoc_required: true,
  raise: false,
  reporter: Doctor.Reporters.Full,
  struct_type_spec_required: true,
  umbrella: false,
  failed: false
}
