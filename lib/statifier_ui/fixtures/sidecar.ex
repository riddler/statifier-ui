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

  A missing sidecar is `{:error, :enoent}`, not an empty bundle - whether
  "no fixtures" is acceptable is a caller-level decision.
  """
  @spec load_for_chart(Path.t()) :: {:ok, Fixtures.t()} | {:error, term()}
  def load_for_chart(chart_path) do
    chart_path |> sidecar_path() |> load()
  end

  @doc """
  Reads, parses, and validates a sidecar file at `path`, returning the same
  struct `StatifierUI.Fixtures.from_source/1` produces.
  """
  @spec load(Path.t()) :: {:ok, Fixtures.t()} | {:error, term()}
  def load(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- JSON.decode(contents) do
      from_json(decoded)
    end
  end

  @doc """
  Converts an already JSON-decoded sidecar map into a validated
  `StatifierUI.Fixtures` struct.
  """
  @spec from_json(map()) :: {:ok, Fixtures.t()} | {:error, term()}
  def from_json(json) when is_map(json) do
    with {:ok, version_diagnostics} <- validate_version(json),
         {:ok, scenarios} <- decode_section(json, "scenarios"),
         {:ok, events} <- decode_section(json, "events") do
      unknown_key_diagnostics = unknown_key_diagnostics(json)

      case Fixtures.new(scenarios: scenarios, events: events) do
        {:ok, fixtures} ->
          diagnostics = version_diagnostics ++ unknown_key_diagnostics
          Enum.each(diagnostics, &log_diagnostic/1)
          {:ok, %Fixtures{fixtures | diagnostics: diagnostics}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  def from_json(other), do: {:error, {:invalid_sidecar, other}}

  @spec validate_version(map()) :: {:ok, [Fixtures.diagnostic()]} | {:error, term()}
  defp validate_version(%{"version" => version}) when is_integer(version) and version == 1 do
    {:ok, []}
  end

  defp validate_version(%{"version" => version}) when is_integer(version) and version > 1 do
    {:ok,
     [
       %{
         kind: :future_version,
         message: "sidecar declares version #{version}, newer than the version this loader knows",
         path: ["version"]
       }
     ]}
  end

  defp validate_version(%{"version" => version}) when is_integer(version) do
    {:error, {:invalid_version, version}}
  end

  defp validate_version(%{"version" => version}), do: {:error, {:invalid_version, version}}
  defp validate_version(_json), do: {:error, :missing_version}

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

  @spec unknown_key_diagnostics(map()) :: [Fixtures.diagnostic()]
  defp unknown_key_diagnostics(json) do
    json
    |> Map.keys()
    |> Enum.reject(&(&1 in @known_top_level_keys))
    |> Enum.sort()
    |> Enum.map(fn key ->
      %{
        kind: :unknown_key,
        message: "ignoring unknown sidecar key #{inspect(key)}",
        path: [key]
      }
    end)
  end

  @spec log_diagnostic(Fixtures.diagnostic()) :: :ok
  defp log_diagnostic(%{message: message}), do: Logger.warning(message)
end
