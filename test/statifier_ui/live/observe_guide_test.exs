defmodule StatifierUI.Live.ObserveGuideTest do
  # Executes `docs/guides/observe-an-execution.md` step by step. The page's
  # LiveView cannot mount here (there is no endpoint), so its callbacks are
  # copied into `GuidePage` below as written on the page, this test process
  # stands in for the LiveView process, and every result the page states is
  # asserted against them. A change to the page's code or to a result it
  # states is made here in the same commit.
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Statifier.Session
  alias StatifierUI.Live.State
  alias StatifierUI.Trace.Message
  alias StatifierUI.Trace.Subscriber

  # The README's Basic usage loan chart, which the page names as its example.
  @loan """
  <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on_loan">
    <datamodel>
      <data id="renewals" expr="0"/>
    </datamodel>
    <state id="on_loan">
      <transition event="loan.renew" target="on_loan">
        <assign location="renewals" expr="renewals + 1"/>
      </transition>
      <transition event="loan.due" target="due"/>
    </state>
    <state id="due">
      <transition event="loan.returned" target="returned"/>
      <transition event="loan.lost" target="lost"/>
    </state>
    <final id="returned"/>
    <final id="lost"/>
  </scxml>
  """

  defmodule GuidePage do
    @moduledoc false
    # Steps 3, 4 and 5 of the page, in the order a module holds them.
    use Phoenix.Component

    alias StatifierUI.Live.State
    alias StatifierUI.Trace.Message

    def handle_info(
          {:statifier_ui, _session_id, %Message{type: "session.halted"} = message},
          socket
        ) do
      {:noreply, socket |> update(:trace, &State.push(&1, message)) |> assign(:finished, true)}
    end

    def handle_info({:statifier_ui, _session_id, %Message{} = message}, socket) do
      {:noreply, update(socket, :trace, &State.push(&1, message))}
    end

    def render(assigns) do
      ~H"""
      <p id="loan-state">{current_state(@trace)}</p>
      <p :if={@finished}>This loan's execution has finished.</p>
      """
    end

    defp current_state(trace) do
      case State.configuration_ids(trace) do
        {:ok, ids} -> Enum.join(ids, ", ")
        {:error, :no_manifest} -> "unknown"
      end
    end
  end

  test "the page's steps produce the results it states" do
    {:ok, chart} = Statifier.compile(@loan)

    {:ok, session} =
      Session.start_link(chart, trace: true, record: true, session_id: "loan_42")

    # Step 1: subscriber started and attached with catch-up.
    {:ok, subscriber} = Subscriber.start_link(machine: chart, source: @loan)
    :ok = Subscriber.attach(subscriber, session, catch_up: true)

    assert %{status: :attached, session: "loan_42", diagnostics: []} =
             Subscriber.stats(subscriber)

    # Step 2: listener first, then the read model from the subscriber.
    :ok = Subscriber.add_listener(subscriber, self())
    trace = State.new(chart) |> State.sync(subscriber)
    assert State.configuration_ids(trace) == {:ok, ["<scxml>", "on_loan"]}

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    socket = Phoenix.Component.assign(socket, trace: trace, finished: false)

    # Step 3: every message folded in after the session takes loan.due.
    :ok = Session.send_event(session, "loan.due")
    socket = fold_until(socket, "trace.macrostep_stable")
    assert State.configuration_ids(socket.assigns.trace) == {:ok, ["<scxml>", "due"]}

    # Step 4: the rendered paragraph.
    html = render_page(socket)
    assert html =~ ~s(<p id="loan-state">&lt;scxml&gt;, due</p>)
    refute html =~ "has finished"

    # Step 5: the halted clause after the session takes loan.returned.
    :ok = Session.send_event(session, "loan.returned")
    socket = fold_until(socket, "session.halted")
    assert socket.assigns.finished

    html = render_page(socket)
    assert html =~ ~s(<p id="loan-state">&lt;scxml&gt;, returned</p>)
    assert html =~ "This loan's execution has finished."
  end

  test "step 1's branch: a session without record: true says :not_recorded" do
    {:ok, chart} = Statifier.compile(@loan)
    {:ok, session} = Session.start_link(chart, trace: true, session_id: "loan_43")
    {:ok, subscriber} = Subscriber.start_link(machine: chart, source: @loan)
    :ok = Subscriber.attach(subscriber, session, catch_up: true)

    assert [%{kind: :not_recorded}] = Subscriber.stats(subscriber).diagnostics
  end

  # Feeds every fan-out message to the page's handle_info/2, oldest first,
  # until one of `type` has been folded in.
  defp fold_until(socket, type) do
    assert_receive {:statifier_ui, "loan_42", %Message{} = message}, 1_000
    {:noreply, socket} = GuidePage.handle_info({:statifier_ui, "loan_42", message}, socket)

    if message.type == type, do: socket, else: fold_until(socket, type)
  end

  defp render_page(socket) do
    socket.assigns
    |> Map.take([:trace, :finished])
    |> GuidePage.render()
    |> rendered_to_string()
  end
end
