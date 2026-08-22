defmodule StatifierUI.EventInjection.Palette do
  @moduledoc """
  A fixture bundle's `events` map (ADR-0003), turned into a sorted list of
  `StatifierUI.EventInjection.Entry.t()` a form can render as buttons.

  `build/1` accepts a `StatifierUI.Fixtures.t()` or `nil`. `nil` (or a bundle
  with no events at all) yields an empty palette with no diagnostics - the
  degraded mode `StatifierUI.EventInjection` turns into its
  `free_form_only?` flag.

  Every entry's payload is encoded through `StatifierUI.Value.encode/1` and
  then `StatifierUI.Trace.Json.encode_to_string/1` - the same canonical,
  byte-stable JSON encoder the trace wire format uses, reused here because a
  `Value.encode/1` result is exactly the "JSON-ready term" shape that encoder
  is typed against. Nothing about the trace wire format itself is touched;
  an injected event is an input, not a trace message.

  A fixture event whose payload falls outside predicator's value domain (a
  tuple, a pid, a struct other than `Date`/`DateTime`) does not fail the
  whole build: the entry is omitted and a diagnostic is appended, in the same
  `StatifierUI.Fixtures.diagnostic()` shape a bundle itself already carries.
  One bad sample takes down one button, not the pane.

  ## Atom-keyed payloads do not round-trip

  `StatifierUI.Fixtures` validates scenario datamodels deeply but leaves
  event payloads verbatim, so a behaviour source can hand over an
  atom-keyed payload map. ADR-0005 says atom keys "serializ[e] as their
  names", which is exactly what `StatifierUI.Trace.Json.encode_to_string/1`
  produces and what `StatifierUI.Value.decode/1` reads back as strings. An
  entry's `payload` field keeps the atoms; its `payload_text`, and therefore
  any event actually sent from it, carries the string-keyed form. This is
  correct rather than lossy: the engine's datamodel is string-keyed, and a
  JSON sidecar could never have expressed the atoms in the first place.
  """

  alias StatifierUI.EventInjection.Entry
  alias StatifierUI.Fixtures
  alias StatifierUI.Trace.Json
  alias StatifierUI.Value

  @type t :: %__MODULE__{
          entries: [Entry.t()],
          diagnostics: [Fixtures.diagnostic()]
        }

  defstruct entries: [], diagnostics: []

  @doc """
  Builds a palette from a fixture bundle's `events` map, or an empty palette
  from `nil`.

  Walks `StatifierUI.Fixtures.event_names/1` (already sorted, ADR-0005's
  canonical order), so entries and diagnostics both come back in event-name
  order. Returns `{:error, {:invalid_fixtures, other}}` for anything that is
  neither a `StatifierUI.Fixtures.t()` nor `nil`.
  """
  @spec build(Fixtures.t() | nil) :: {:ok, t()} | {:error, term()}
  def build(nil), do: {:ok, %__MODULE__{}}

  def build(%Fixtures{} = fixtures) do
    {entries, diagnostics} =
      fixtures
      |> Fixtures.event_names()
      |> Enum.map(&build_entry(fixtures, &1))
      |> Enum.split_with(&match?({:entry, _}, &1))

    {:ok,
     %__MODULE__{
       entries: Enum.map(entries, fn {:entry, entry} -> entry end),
       diagnostics: Enum.map(diagnostics, fn {:diagnostic, diagnostic} -> diagnostic end)
     }}
  end

  def build(other), do: {:error, {:invalid_fixtures, other}}

  @doc """
  Fetches an entry by event name. Mirrors `StatifierUI.Fixtures.event/2`'s
  `{:ok, _} | :error` shape.
  """
  @spec entry(t(), String.t()) :: {:ok, Entry.t()} | :error
  def entry(%__MODULE__{entries: entries}, name) do
    case Enum.find(entries, &(&1.name == name)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc """
  Event names in the palette, sorted.
  """
  @spec names(t()) :: [String.t()]
  def names(%__MODULE__{entries: entries}), do: Enum.map(entries, & &1.name)

  @spec build_entry(Fixtures.t(), Fixtures.event_name()) ::
          {:entry, Entry.t()} | {:diagnostic, Fixtures.diagnostic()}
  defp build_entry(fixtures, name) do
    {:ok, payload} = Fixtures.event(fixtures, name)

    case encode_payload_text(payload) do
      {:ok, payload_text} ->
        {:entry, %Entry{name: name, payload: payload, payload_text: payload_text}}

      {:error, reason} ->
        {:diagnostic, unencodable_diagnostic(name, reason)}
    end
  end

  @spec encode_payload_text(term()) :: {:ok, String.t()} | {:error, term()}
  defp encode_payload_text(:undefined), do: {:ok, ""}

  defp encode_payload_text(payload) do
    with {:ok, encoded} <- Value.encode(payload) do
      {:ok, Json.encode_to_string(encoded)}
    end
  end

  @spec unencodable_diagnostic(Fixtures.event_name(), term()) :: Fixtures.diagnostic()
  defp unencodable_diagnostic(name, reason) do
    %{
      kind: :unencodable_event_payload,
      message: "event #{inspect(name)} has a payload that cannot be encoded: #{inspect(reason)}",
      path: ["events", name],
      source: nil
    }
  end
end
