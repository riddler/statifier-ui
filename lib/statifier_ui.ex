defmodule StatifierUI do
  @moduledoc """
  UI components for authoring, observing, inspecting, and debugging
  [statifier](https://github.com/riddler/statifier-ex) statecharts.

  The package is a set of components rather than an application: a Livebook
  (`Kino`) inspector first, LiveView components after it. Both integrations are
  optional dependencies, so a host that wants one does not pull the other.

  Nothing here changes the engine. Statifier already emits trace effects at
  every Appendix D phase boundary and retains source locations, so a UI is one
  more effect interpreter reading seams that exist.

  Fixture data - example scenario datamodels and event payloads a host
  supplies for a chart - is delivered through `StatifierUI.Fixtures`, either
  by a host module implementing `StatifierUI.Fixtures.Source` or by
  `StatifierUI.Fixtures.Sidecar` reading a `<chart>.fixtures.json` file.
  `StatifierUI.Shape` infers display-type labels from example values.

  Trace data - the wire format that carries a running session's effects to
  a UI - is produced by `StatifierUI.Trace.Subscriber`, which attaches to a
  `Statifier.Session` and normalizes its effects into
  `StatifierUI.Trace.Message` structs via `StatifierUI.Trace.Normalizer`,
  buffering them in a `StatifierUI.Trace.Buffer`. `StatifierUI.Trace.Json`
  renders messages to the canonical JSON `docs/wire-format.md` specifies.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the version of this package as a string.

  ## Examples

      iex> StatifierUI.version() =~ ~r/^\\d+\\.\\d+\\.\\d+/
      true

  """
  @spec version() :: String.t()
  def version, do: @version
end
