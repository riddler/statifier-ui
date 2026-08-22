defmodule StatifierUI.EventInjection.Draft do
  @moduledoc """
  Turns a form's two free-form fields - an event name and a payload text -
  into a `Statifier.Event.t()`, the ordinary recordable input
  (`Statifier.Event.external/2`) rather than a side door.

  ## The three-way payload distinction

  `Statifier.Event`'s own moduledoc is explicit that `data` has three
  states that must not collapse into each other: **no data** (`:undefined`),
  **data, present, and null** (`nil`), and **data, present, and empty**
  (`%{}`). One text field has to spell all three, and `build/2` resolves
  them this way:

    * **blank** (`nil`, or a string that is empty after trimming) means
      `data: :undefined` - "no data" - the same default `Event.external/2`
      itself uses when the caller passes no `:data` option at all.
    * `"null"` decodes through `JSON.decode/1` to `nil`, which
      `StatifierUI.Value.decode/1` passes through unchanged - "data,
      present, and null".
    * `"{}"` decodes to `%{}` the same way - "data, present, and empty".

  Any other payload text is decoded as ADR-0005 JSON via `JSON.decode/1`
  and then `StatifierUI.Value.decode/1`, so a `$`-tagged shape
  (`$undefined`, `$date`, `$datetime`, `$duration`) resolves to the
  predicator value it encodes.
  """

  alias Statifier.Event
  alias StatifierUI.Value

  @typedoc """
  Why `build/2` refused to produce an event.

    * `:blank_event_name` - the name was empty, or all whitespace.
    * `{:invalid_event_name, name}` - `name` was not a binary, or contained
      whitespace or a control character (SCXML event names are
      dot-delimited tokens; one with a space in it can never match a
      transition's `event` attribute, so it is a typo rather than a
      debugging choice).
    * `{:invalid_json, reason}` - the payload text was not valid JSON;
      `reason` is `JSON.decode/1`'s own error value.
    * `{:invalid_payload, reason}` - the payload decoded as JSON but not as
      an ADR-0005 value (an unknown `$`-prefixed tag, a malformed `$date`);
      `reason` is `StatifierUI.Value.decode/1`'s own error value.
  """
  @type reason ::
          :blank_event_name
          | {:invalid_event_name, term()}
          | {:invalid_json, term()}
          | {:invalid_payload, term()}

  @doc """
  Builds a `Statifier.Event.t()` from a form's name and payload text.

  `name` is trimmed of leading/trailing whitespace before validation. An
  unmatched but well-formed name is legal and is not rejected here - only
  syntax is checked; whether the name matches any transition is the
  chart's business, not this function's.

  `payload_text` defaults to `nil`. `nil`, or a string that is blank after
  trimming, means no data (`data: :undefined`); see the moduledoc for the
  full three-way spelling.

  No option other than `:data` is passed to `Statifier.Event.external/2`:
  `invokeid`, `origin`, `origintype`, and `sendid` all belong to delivery
  paths this function is not.

  ## Examples

      iex> {:ok, event} = StatifierUI.EventInjection.Draft.build("payment.success", ~s({"amount":1999}))
      iex> event.data
      %{"amount" => 1999}

      iex> {:ok, event} = StatifierUI.EventInjection.Draft.build("payment.success", "")
      iex> event.data
      :undefined

      iex> StatifierUI.EventInjection.Draft.build("")
      {:error, :blank_event_name}

  """
  @spec build(String.t(), String.t() | nil) :: {:ok, Event.t()} | {:error, reason()}
  def build(name, payload_text \\ nil)

  def build(name, payload_text) when is_binary(name) do
    trimmed_name = String.trim(name)

    with :ok <- validate_name(trimmed_name),
         {:ok, data} <- decode_payload(payload_text) do
      {:ok, Event.external(trimmed_name, data: data)}
    end
  end

  def build(other, _payload_text), do: {:error, {:invalid_event_name, other}}

  @spec validate_name(String.t()) :: :ok | {:error, reason()}
  defp validate_name(""), do: {:error, :blank_event_name}

  defp validate_name(name) do
    if String.match?(name, ~r/[\s\p{Cc}]/u) do
      {:error, {:invalid_event_name, name}}
    else
      :ok
    end
  end

  @spec decode_payload(String.t() | nil) :: {:ok, term()} | {:error, reason()}
  defp decode_payload(nil), do: {:ok, :undefined}

  defp decode_payload(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:ok, :undefined}

      trimmed ->
        with {:ok, decoded} <- json_decode(trimmed) do
          value_decode(decoded)
        end
    end
  end

  @spec json_decode(String.t()) :: {:ok, term()} | {:error, reason()}
  defp json_decode(text) do
    case JSON.decode(text) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  @spec value_decode(term()) :: {:ok, term()} | {:error, reason()}
  defp value_decode(decoded) do
    case Value.decode(decoded) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end
end
