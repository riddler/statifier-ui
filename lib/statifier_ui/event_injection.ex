defmodule StatifierUI.EventInjection do
  @moduledoc """
  The pane model behind the inspector's event-firing form: a palette built
  from a fixture bundle's `events` map (`StatifierUI.EventInjection.Palette`),
  a `free_form_only?` flag for the degraded mode the bead requires when there
  are no fixtures to draw buttons from, and the one send path every submitted
  form goes through.

  ## The one door in

  Every send in this pane goes through `Statifier.Session.send_event/2` with
  a `Statifier.Event.external/2` value - the ordinary recordable input path.
  Per statifier ADR-0029, replay records the external event log as one of
  its four recorded inputs; `send_event/2` is what keeps a recorded session
  replayable, because it is the path the recording actually watches.
  `Statifier.Session.interpret/2` and `send_invoked_event/3` are **not**
  this pane's doors: `interpret/2` is the embedder seam ADR-0029 widened the
  recording obligation for, and `send_invoked_event/3` is the child-to-parent
  invoke direction, not an operator firing an event by hand. Neither is
  called from anywhere in this module, or anywhere else in this pane.

  `send_event/2` is a `GenServer.cast` - it returns `:ok` once the event is
  enqueued, not once it has been processed. The effect of an injected event
  (the dequeue, the transitions it triggers, the states it enters) shows up
  on the trace stream (`StatifierUI.Trace.Subscriber`, `StatifierUI.EventLog`),
  never on this module's return value.

  ## Degraded mode

  `build/1` sets `free_form_only?: true` whenever the palette has no
  entries: for `nil`, for a bundle whose `events` map is empty, and for a
  bundle whose every event payload turned out to be unencodable (in which
  case `diagnostics/1` says why). The free-form escape hatch
  (`send_draft/3` with a name and payload text typed by hand) needs no
  fixtures at all and always works, degraded mode or not.
  """

  import Kernel, except: [send: 2]

  alias Statifier.Event
  alias Statifier.Session
  alias StatifierUI.EventInjection.Draft
  alias StatifierUI.EventInjection.Entry
  alias StatifierUI.EventInjection.Palette
  alias StatifierUI.Fixtures

  @type t :: %__MODULE__{
          palette: Palette.t(),
          free_form_only?: boolean()
        }

  @enforce_keys [:palette, :free_form_only?]
  defstruct [:palette, :free_form_only?]

  @doc """
  Builds a pane model from a fixture bundle, or from `nil` for the
  fixture-less degraded mode.

  Delegates to `StatifierUI.EventInjection.Palette.build/1` and returns
  `{:error, {:invalid_fixtures, other}}` for the same inputs that function
  rejects. `free_form_only?` is `true` exactly when the resulting palette
  has no entries.
  """
  @spec build(Fixtures.t() | nil) :: {:ok, t()} | {:error, term()}
  def build(fixtures) do
    with {:ok, palette} <- Palette.build(fixtures) do
      {:ok, %__MODULE__{palette: palette, free_form_only?: palette.entries == []}}
    end
  end

  @doc "The pane's palette entries, in event-name order."
  @spec entries(t()) :: [Entry.t()]
  def entries(%__MODULE__{palette: palette}), do: palette.entries

  @doc "The pane's diagnostics: one per fixture event that could not be encoded."
  @spec diagnostics(t()) :: [Fixtures.diagnostic()]
  def diagnostics(%__MODULE__{palette: palette}), do: palette.diagnostics

  @doc """
  Delivers `event` to `server` through `Statifier.Session.send_event/2` and
  nothing else - the only line in this pane, and in this repository's
  `lib/`, that puts an event into a session.

  `:ok` means enqueued, not processed; see the moduledoc.
  """
  @spec send(Session.server(), Event.t()) :: :ok
  def send(server, %Event{} = event), do: Session.send_event(server, event)

  @doc """
  Builds a draft from a form's name and payload text
  (`StatifierUI.EventInjection.Draft.build/2`) and, on success, sends it
  (`send/2`). A build failure is returned without touching `server` at all.
  """
  @spec send_draft(Session.server(), String.t(), String.t() | nil) ::
          :ok | {:error, Draft.reason()}
  def send_draft(server, name, payload_text \\ nil) do
    with {:ok, event} <- Draft.build(name, payload_text) do
      send(server, event)
    end
  end
end
