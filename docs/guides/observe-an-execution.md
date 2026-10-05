# How to observe an execution from a LiveView host

This guide shows you how to put one execution's current state on a page of
your own LiveView and keep it current while the execution moves. To put the
shipped diagram and event log on a page instead, see
[How to embed the ops view in a host LiveView](../ops-embedding.md).

You start from a Phoenix host that declares `:statifier_ui` and
`:phoenix_live_view` as dependencies, with a loan's execution already started
as a `Statifier.Session` under `trace: true` and `record: true`. The examples
use the loan chart from the README's Basic usage (`on_loan`, `due`,
`returned`, `lost`) and a session id of `loan_42`; `MyApp.Loans.fetch!/1`
stands for however your host finds the compiled chart, the session pid and
the SCXML source.

1. Start a subscriber in `mount/3` and attach it to the session with
   catch-up:

   ```elixir
   defmodule MyAppWeb.LoanLive do
     use MyAppWeb, :live_view

     alias StatifierUI.Live.State
     alias StatifierUI.Trace.Message
     alias StatifierUI.Trace.Subscriber

     def mount(%{"loan_id" => loan_id}, _session, socket) do
       {chart, session, source} = MyApp.Loans.fetch!(loan_id)

       {:ok, subscriber} = Subscriber.start_link(machine: chart, source: source)
       :ok = Subscriber.attach(subscriber, session, catch_up: true)
       # step 2 continues here
     end
   end
   ```

   `Subscriber.stats(subscriber)` now shows `status: :attached`,
   `session: "loan_42"` and `diagnostics: []`. If `diagnostics` carries a
   `:not_recorded` entry, start the session with `record: true`.

2. Register the LiveView as a listener, then build the read model from what
   the subscriber already holds:

   ```elixir
       :ok = Subscriber.add_listener(subscriber, self())
       trace = State.new(chart) |> State.sync(subscriber)

       {:ok, assign(socket, trace: trace, finished: false)}
   ```

   `State.configuration_ids(trace)` returns `{:ok, ["<scxml>", "on_loan"]}`
   for a loan still on loan. Listener first and snapshot second, so no
   message falls between the two calls.

3. Fold every message the subscriber sends into the read model:

   ```elixir
     def handle_info({:statifier_ui, _session_id, %Message{} = message}, socket) do
       {:noreply, update(socket, :trace, &State.push(&1, message))}
     end
   ```

   After the session takes `loan.due`,
   `State.configuration_ids(socket.assigns.trace)` returns
   `{:ok, ["<scxml>", "due"]}`.

4. Render the current state on your page:

   ```elixir
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
   ```

   The `#loan-state` paragraph reads `<scxml>, due`, and changes on the next
   event without a reload.

5. Mark the page when the execution finishes, with a clause placed above the
   one from step 3:

   ```elixir
     def handle_info(
           {:statifier_ui, _session_id, %Message{type: "session.halted"} = message},
           socket
         ) do
       {:noreply, socket |> update(:trace, &State.push(&1, message)) |> assign(:finished, true)}
     end
   ```

   After the session takes `loan.returned`, the `#loan-state` paragraph reads
   `<scxml>, returned` and the "finished" line appears.

For every option `Subscriber.start_link/1` and `Subscriber.attach/3` take, see
`StatifierUI.Trace.Subscriber`; for every read the model answers, see
`StatifierUI.Live.State`.
