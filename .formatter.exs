# Used by "mix format"
[
  # phoenix_live_view is an optional dependency (ADR-0004) but is always
  # fetched here, and this is what keeps `attr` and `slot` declarations in
  # lib/statifier_ui/live.ex paren-free the way every LiveView codebase
  # writes them.
  import_deps: [:phoenix_live_view],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
