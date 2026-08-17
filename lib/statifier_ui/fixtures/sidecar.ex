defmodule StatifierUI.Fixtures.Sidecar do
  @moduledoc """
  Reads a `<chart>.fixtures.json` sidecar (ADR-0003) and produces the same
  `StatifierUI.Fixtures` struct the behaviour-based delivery path produces.

  Uses the stdlib `JSON` module (Elixir 1.18) to decode, never `jason` -
  `jason` reaches this repository only through the optional
  `phoenix_live_view` dependency and must not become load-bearing for core
  fixture loading.

  Every top-level key beyond `"version"`, `"scenarios"`, and `"events"` is
  ignored with a `:unknown_key` diagnostic (ADR-0006's extension-friendly
  requirement), and every value under `"scenarios"` and `"events"` is
  decoded through `StatifierUI.Value.decode/1`.

  A `$duration` cannot appear inside `"scenarios"`: it decodes to an
  atom-keyed map, and a datamodel forbids atom keys at every level (the
  engine's own invariant, tightened in `StatifierUI.Fixtures`). Such a
  sidecar is rejected with `{:duration_in_scenario, path}`. Durations under
  `"events"` are fine - an `_event.data` payload has no key constraint.
  """

  alias StatifierUI.Fixtures
  alias StatifierUI.Value

  require Logger

  @known_top_level_keys ~w(version scenarios events)

  @doc """
  Derives a sidecar path from a chart path, per ADR-0003's naming:
  `payment.scxml` becomes `payment.fixtures.json`. A path with no
  extension has `.fixtures.json` appended.

  ## Examples

      iex> StatifierUI.Fixtures.Sidecar.sidecar_path("payment.scxml")
      "payment.fixtures.json"

      iex> StatifierUI.Fixtures.Sidecar.sidecar_path("payment")
      "payment.fixtures.json"

  """
  @spec sidecar_path(Path.t()) :: Path.t()
  def sidecar_path(chart_path) do
    case Path.extname(chart_path) do
      "" -> chart_path <> ".fixtures.json"
      extname -> String.replace_suffix(chart_path, extname, ".fixtures.json")
    end
  end

  @doc """
  Derives the sidecar path for `chart_path` and loads it.

  A missing sidecar is `{:error, {:sidecar_not_found, path}}`, not an empty
  bundle - whether "no fixtures" is acceptable is a caller-level decision,
  and a typo'd chart path must not look like a chart without fixtures.
  """
  @spec load_for_chart(Path.t()) :: {:ok, Fixtures.t()} | {:error, term()}
  def load_for_chart(chart_path) do
    chart_path |> sidecar_path() |> load()
  end

  @doc """
  Reads, parses, and validates a sidecar file at `path`, returning the same
  struct `StatifierUI.Fixtures.from_source/1` produces.

  Every error names `path`, because a corpus run loads many sidecars and a
  bare POSIX reason does not say which one failed.
  """
  @spec load(Path.t()) :: {:ok, Fixtures.t()} | {:error, term()}
  def load(path) do
    with {:ok, contents} <- read_sidecar(path),
         {:ok, decoded} <- decode_json(contents, path) do
      from_json(decoded, source: path)
    end
  end

  @doc """
  Converts an already JSON-decoded sidecar map into a validated
  `StatifierUI.Fixtures` struct.

  Options:

    * `:source` - the file the map was read from, recorded on each
      diagnostic and named in each logged warning. `load/1` passes it;
      omitting it is for a map that never was a file.
  """
  @spec from_json(map(), keyword()) :: {:ok, Fixtures.t()} | {:error, term()}
  def from_json(json, opts \\ [])

  def from_json(json, opts) when is_map(json) do
    source = Keyword.get(opts, :source)

    with {:ok, version_diagnostics} <- validate_version(json, source),
         {:ok, scenarios} <- decode_section(json, "scenarios"),
         {:ok, events} <- decode_section(json, "events") do
      unknown_key_diagnostics = unknown_key_diagnostics(json, source)

      case Fixtures.new(scenarios: scenarios, events: events) do
        {:ok, fixtures} ->
          diagnostics = version_diagnostics ++ unknown_key_diagnostics
          Enum.each(diagnostics, &log_diagnostic/1)
          {:ok, %Fixtures{fixtures | diagnostics: diagnostics}}

        {:error, reason} ->
          {:error, with_source(reason, source)}
      end
    end
  end

  def from_json(other, _opts), do: {:error, {:invalid_sidecar, other}}

  @spec read_sidecar(Path.t()) :: {:ok, binary()} | {:error, term()}
  defp read_sidecar(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, {:sidecar_not_found, path}}
      {:error, reason} -> {:error, {:sidecar_unreadable, path, reason}}
    end
  end

  @spec decode_json(binary(), Path.t()) :: {:ok, term()} | {:error, term()}
  defp decode_json(contents, path) do
    case JSON.decode(contents) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, path, reason}}
    end
  end

  @spec with_source(term(), Path.t() | nil) :: term()
  defp with_source(reason, nil), do: reason
  defp with_source(reason, source), do: {:invalid_sidecar_contents, source, reason}

  @spec validate_version(map(), Path.t() | nil) ::
          {:ok, [Fixtures.diagnostic()]} | {:error, term()}
  defp validate_version(%{"version" => version}, _source)
       when is_integer(version) and version == 1 do
    {:ok, []}
  end

  defp validate_version(%{"version" => version}, source)
       when is_integer(version) and version > 1 do
    {:ok,
     [
       diagnostic(
         :future_version,
         "sidecar declares version #{version}, newer than the version this loader knows",
         ["version"],
         source
       )
     ]}
  end

  defp validate_version(%{"version" => version}, source) when is_integer(version) do
    {:error, with_source({:invalid_version, version}, source)}
  end

  defp validate_version(%{"version" => version}, source),
    do: {:error, with_source({:invalid_version, version}, source)}

  defp validate_version(_json, source), do: {:error, with_source(:missing_version, source)}

  @spec decode_section(map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_section(json, key) do
    json
    |> Map.get(key, %{})
    |> decode_map_of_values(key)
  end

  @spec decode_map_of_values(term(), String.t()) :: {:ok, map()} | {:error, term()}
  defp decode_map_of_values(map, section) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case Value.decode(value) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, name, decoded)}}
        {:error, reason} -> {:halt, {:error, {:invalid_value, section, name, reason}}}
      end
    end)
  end

  defp decode_map_of_values(other, section), do: {:error, {:invalid_section, section, other}}

  @spec unknown_key_diagnostics(map(), Path.t() | nil) :: [Fixtures.diagnostic()]
  defp unknown_key_diagnostics(json, source) do
    json
    |> Map.keys()
    |> Enum.reject(&(&1 in @known_top_level_keys))
    |> Enum.sort()
    |> Enum.map(fn key ->
      diagnostic(:unknown_key, "ignoring unknown sidecar key #{inspect(key)}", [key], source)
    end)
  end

  @spec diagnostic(atom(), String.t(), [String.t()], Path.t() | nil) :: Fixtures.diagnostic()
  defp diagnostic(kind, message, path, source) do
    %{kind: kind, message: message, path: path, source: source}
  end

  # The file is part of the message, not only of the struct: a corpus run
  # logs these while walking many charts, and a warning that names only the
  # key cannot be traced back to the sidecar that caused it.
  @spec log_diagnostic(Fixtures.diagnostic()) :: :ok
  defp log_diagnostic(%{message: message, source: nil}), do: Logger.warning(message)

  defp log_diagnostic(%{message: message, source: source}),
    do: Logger.warning("#{message} in #{source}")
end
