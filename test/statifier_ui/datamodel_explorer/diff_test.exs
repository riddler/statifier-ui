defmodule StatifierUI.DatamodelExplorer.DiffTest do
  use ExUnit.Case, async: true

  alias StatifierUI.DatamodelExplorer
  alias StatifierUI.DatamodelExplorer.Diff
  alias StatifierUI.DatamodelExplorer.Entry

  doctest StatifierUI.DatamodelExplorer.Diff
  doctest StatifierUI.DatamodelExplorer.Diff.Markdown

  # Panes are built by hand here rather than folded from a stream: this
  # module compares two panes and knows nothing about where they came from,
  # so a stream would only put a second thing under test.
  defp pane(entries) do
    %DatamodelExplorer{mode: :live, session: "sess_diff", entries: entries}
  end

  defp entry(name, value, opts \\ []) do
    %Entry{
      name: name,
      tier: Keyword.get(opts, :tier, :data),
      value: value,
      shape: :unknown,
      label: "any",
      children: Keyword.get(opts, :children, [])
    }
  end

  describe "between/2" do
    test "reports a slot whose value moved" do
      earlier = pane([entry("count", 41)])
      later = pane([entry("count", 42)])

      assert Diff.between(earlier, later) == [
               %{name: "count", tier: :data, kind: :changed, from: 41, to: 42}
             ]
    end

    test "reports an added slot with :absent on the before side" do
      earlier = pane([])
      later = pane([entry("captured_cents", 1999)])

      assert [%{name: "captured_cents", kind: :added, from: :absent, to: 1999}] =
               Diff.between(earlier, later)
    end

    test "reports a removed slot with :absent on the after side" do
      earlier = pane([entry("draft", "x")])
      later = pane([])

      assert [%{name: "draft", kind: :removed, from: "x", to: :absent}] =
               Diff.between(earlier, later)
    end

    test "says nothing about a slot that did not move" do
      pane = pane([entry("count", 42), entry("variant", "B")])

      assert Diff.between(pane, pane) == []
    end

    test "nil and :undefined are values, not absence" do
      earlier = pane([entry("reason", nil)])
      later = pane([entry("reason", :undefined)])

      assert [%{kind: :changed, from: nil, to: :undefined}] = Diff.between(earlier, later)
    end

    test "1 and 1.0 are a change, because the datamodel holds them apart" do
      earlier = pane([entry("amount", 1)])
      later = pane([entry("amount", 1.0)])

      assert [%{kind: :changed, from: 1, to: 1.0}] = Diff.between(earlier, later)
    end

    test "a child renders as its own qualified slot" do
      child_a = entry("name", "a", tier: :system)
      child_b = entry("name", "b", tier: :system)
      earlier = pane([entry("_event", %{}, tier: :system, children: [child_a])])
      later = pane([entry("_event", %{}, tier: :system, children: [child_b])])

      assert [%{name: "_event.name", tier: :system, kind: :changed, from: "a", to: "b"}] =
               Diff.between(earlier, later)
    end

    test "tier 2b provider functions are never compared" do
      earlier = pane([entry("len", :fun_a, tier: :function)])
      later = pane([entry("len", :fun_b, tier: :function)])

      assert Diff.between(earlier, later) == []
    end

    test "orders additions and changes by the later pane, removals last" do
      earlier = pane([entry("gone", 1), entry("kept", 1)])
      later = pane([entry("kept", 2), entry("new", 3)])

      assert [
               %{name: "kept", kind: :changed},
               %{name: "new", kind: :added},
               %{name: "gone", kind: :removed}
             ] = Diff.between(earlier, later)
    end
  end

  describe "Markdown.render/2" do
    test "renders one row per change, absence as a dash" do
      changes = [
        %{name: "count", tier: :data, kind: :changed, from: 41, to: 42},
        %{name: "note", tier: :runtime, kind: :added, from: :absent, to: "hi"}
      ]

      markdown = Diff.Markdown.render(changes)

      assert markdown =~ "#### Datamodel changes"
      assert markdown =~ "| `count` | data | changed | `41` | `42` |"
      assert markdown =~ "| `note` | runtime | added | - | `\"hi\"` |"
    end

    test "an empty list says so rather than rendering an empty table" do
      markdown = Diff.Markdown.render([], title: "#### Datamodel changes in macrostep 3")

      assert markdown =~ "#### Datamodel changes in macrostep 3"
      assert markdown =~ "_No datamodel slot changed._"
      refute markdown =~ "| slot |"
    end

    test "the empty note is overridable and the title omittable" do
      assert Diff.Markdown.render([], title: nil, empty_note: "nothing here") == "nothing here"
    end
  end

  describe "absent/0" do
    test "names the sentinel the change maps use" do
      assert Diff.absent() == :absent
    end
  end
end
