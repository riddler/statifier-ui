defmodule StatifierUI.Test.Support.Trace.SessionCase do
  @moduledoc """
  Test-only plumbing for `StatifierUI.Trace.Subscriber` tests: compile a
  heredoc chart, start a subscriber and a session with a pinned
  `session_id`, and poll `stats/1` for a target `seq` instead of
  `assert_receive` on the session's own messages - the test process is
  never the subscriber, so it cannot `assert_receive` on messages the
  subscriber process consumes.
  """

  alias Statifier.Session
  alias StatifierUI.Trace.Subscriber

  @doc "Compiles `xml`, raising on a parse/compile failure a test did not expect."
  @spec compile!(String.t()) :: Statifier.Machine.t()
  def compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  @doc """
  The recommended (early) attach path: starts a subscriber, then starts a
  session over `machine` with the subscriber pre-registered in
  `:subscribers` (so it sees the initialize burst) and `session_id`
  pinned, then attaches with `subscribe: false` - the session already has
  the subscriber in its monitored set. Returns `{subscriber, session}`.
  """
  @spec start_early!(Statifier.Machine.t(), String.t(), keyword()) :: {pid(), pid()}
  def start_early!(machine, session_id, subscriber_opts \\ []) do
    {:ok, sub} = Subscriber.start_link(Keyword.put(subscriber_opts, :machine, machine))

    {:ok, session} =
      Session.start_link(machine, trace: true, subscribers: [sub], session_id: session_id)

    :ok = Subscriber.attach(sub, session, subscribe: false)
    {sub, session}
  end

  @doc """
  The late attach path: starts a session first (with `session_id` pinned,
  no subscriber), then a subscriber, then attaches with the default
  `subscribe: true` - the initialize burst has already been delivered to
  nobody by the time this subscriber joins. Returns `{subscriber,
  session}`.
  """
  @spec start_late!(Statifier.Machine.t(), String.t(), keyword()) :: {pid(), pid()}
  def start_late!(machine, session_id, subscriber_opts \\ []) do
    {:ok, session} = Session.start_link(machine, trace: true, session_id: session_id)
    {:ok, sub} = Subscriber.start_link(Keyword.put(subscriber_opts, :machine, machine))
    :ok = Subscriber.attach(sub, session)
    {sub, session}
  end

  @doc """
  The catch-up attach path (statifier ADR-0049): starts a session over
  `machine` with `record: true` and `session_id` pinned - and no
  subscriber, so everything up to the attach is missed mail - then starts
  a subscriber and attaches with `catch_up: true`. The caller drives
  events between the two halves via the returned session; use
  `wait_for_macrostep/3` to know the session has processed them before
  attaching. Returns the session; pair with `attach_catch_up!/2`.
  """
  @spec start_recorded!(Statifier.Machine.t(), String.t()) :: pid()
  def start_recorded!(machine, session_id) do
    {:ok, session} =
      Session.start_link(machine, trace: true, record: true, session_id: session_id)

    session
  end

  @doc "Starts a subscriber over `machine` and attaches it to `session` with `catch_up: true`."
  @spec attach_catch_up!(Statifier.Machine.t(), pid(), keyword()) :: pid()
  def attach_catch_up!(machine, session, subscriber_opts \\ []) do
    {:ok, sub} = Subscriber.start_link(Keyword.put(subscriber_opts, :machine, machine))
    :ok = Subscriber.attach(sub, session, catch_up: true)
    sub
  end

  @doc """
  Polls `Statifier.Session.status/1` until `macrostep` reaches at least
  `target` with an empty external queue, or `timeout` milliseconds elapse.
  Returns the last observed status projection either way.
  """
  @spec wait_for_macrostep(pid(), non_neg_integer(), timeout()) :: map()
  def wait_for_macrostep(session, target, timeout \\ 1000) do
    status = Session.status(session)

    if (status.macrostep >= target and status.queued_events == 0) or timeout <= 0 do
      status
    else
      step = min(10, timeout)
      Process.sleep(step)
      wait_for_macrostep(session, target, timeout - step)
    end
  end

  @doc """
  Polls `Subscriber.stats/1` until `seq` reaches at least `target`, or
  `timeout` milliseconds elapse. Returns the last observed `stats()` map
  either way, so a caller can assert on it directly instead of getting a
  bare boolean.
  """
  @spec wait_for_seq(pid(), non_neg_integer(), timeout()) :: Subscriber.stats()
  def wait_for_seq(sub, target, timeout \\ 1000) do
    wait_until(sub, timeout, fn stats -> stats.seq >= target end)
  end

  @doc "As `wait_for_seq/3`, but the caller supplies its own predicate over `stats()`."
  @spec wait_until(pid(), timeout(), (Subscriber.stats() -> boolean())) :: Subscriber.stats()
  def wait_until(sub, timeout, _predicate) when timeout <= 0 do
    Subscriber.stats(sub)
  end

  def wait_until(sub, timeout, predicate) do
    stats = Subscriber.stats(sub)

    if predicate.(stats) do
      stats
    else
      step = min(10, timeout)
      Process.sleep(step)
      wait_until(sub, timeout - step, predicate)
    end
  end
end
