defmodule StatifierUI.DatamodelExplorer.SessionTest do
  use ExUnit.Case, async: true

  alias Statifier.Session
  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.Test.Support.Trace.SessionCase
  alias StatifierUI.Trace.Subscriber

  # A self-transition on "bump" that assigns `count`, so a second macrostep
  # is driven by an ordinary external event rather than the initialize
  # burst. `<data id="count" expr="41 + 1"/>` proves the fold reads the
  # engine's own binding-fold result, not a value this test computed.
  @chart """
  <?xml version="1.0" encoding="UTF-8"?>
  <scxml xmlns="http://www.w3.org/2005/07/scxml" initial="a" version="1.0">
      <datamodel>
          <data id="count" expr="41 + 1"/>
      </datamodel>
      <state id="a">
          <transition event="bump" target="a">
              <assign location="count" expr="count + 1"/>
          </transition>
      </state>
  </scxml>
  """

  @spec macrostep_stable_count(pid()) :: non_neg_integer()
  defp macrostep_stable_count(sub) do
    sub
    |> Subscriber.messages()
    |> Enum.filter(&(&1.type == "trace.macrostep_stable"))
    |> Enum.map(& &1.macrostep)
    |> Enum.uniq()
    |> length()
  end

  # `Subscriber.stats/1` carries no macrostep information, so this polls
  # `Subscriber.messages/1` directly through `wait_until/3`'s predicate
  # rather than `wait_for_seq/3`, which only knows about `seq`.
  @spec wait_for_macrostep_count(pid(), pos_integer()) :: :ok
  defp wait_for_macrostep_count(sub, count) do
    SessionCase.wait_until(sub, 1000, fn _stats -> macrostep_stable_count(sub) >= count end)
    :ok
  end

  @spec fold(pid()) :: DatamodelExplorer.t()
  defp fold(sub) do
    assert {:ok, pane} = DatamodelExplorer.build_live(Subscriber.messages(sub))
    pane
  end

  @spec entry(DatamodelExplorer.t(), String.t()) :: DatamodelExplorer.Entry.t()
  defp entry(pane, name), do: Enum.find(pane.entries, &(&1.name == name))

  test "the fold tracks a real session's <data> binding, then its <assign>" do
    machine = SessionCase.compile!(@chart)
    {sub, session} = SessionCase.start_early!(machine, "sess_dm_live")

    wait_for_macrostep_count(sub, 1)
    pane = fold(sub)

    count = entry(pane, "count")
    assert count.value == 42
    assert count.changed? == true

    session_id_entry = entry(pane, "_sessionid")
    assert session_id_entry.value == "sess_dm_live"

    first_macrostep = pane.macrostep

    assert :ok = Session.send_event(session, "bump")
    wait_for_macrostep_count(sub, 2)
    pane = fold(sub)

    count = entry(pane, "count")
    assert count.value == 43
    assert count.changed? == true
    assert pane.macrostep > first_macrostep

    # _sessionid was untouched by this macrostep's writes, so it must not
    # be marked changed? even though it is still present and correct.
    session_id_entry = entry(pane, "_sessionid")
    assert session_id_entry.value == "sess_dm_live"
    assert session_id_entry.changed? == false
  end
end
