defmodule StatifierUI.DiagramTest do
  use ExUnit.Case, async: true

  alias StatifierUI.Diagram

  doctest StatifierUI.Diagram

  defp compile!(xml) do
    {:ok, machine} = Statifier.compile(xml)
    machine
  end

  defp index!(machine, id) do
    {:ok, index} = Statifier.Machine.index(machine, id)
    index
  end

  @flat """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
        <state id="a">
          <transition event="go" target="b"/>
        </state>
        <state id="b"/>
      </scxml>
  """

  @nested """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="outer">
        <state id="outer" initial="inner_a">
          <state id="inner_a">
            <transition event="step" target="inner_b"/>
          </state>
          <state id="inner_b"/>
        </state>
        <state id="other"/>
      </scxml>
  """

  @cross """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="left">
        <state id="left" initial="l1">
          <state id="l1">
            <transition event="jump" target="r1"/>
          </state>
        </state>
        <state id="right" initial="r1">
          <state id="r1"/>
        </state>
      </scxml>
  """

  @parallel """
      <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
        <parallel id="p">
          <state id="region_one" initial="r1a">
            <state id="r1a"/>
          </state>
          <state id="region_two" initial="r2a">
            <state id="r2a"/>
          </state>
        </parallel>
      </scxml>
  """

  describe "render/2 - flat charts" do
    test "produces stateDiagram-v2 source with aliased states and transitions" do
      machine = compile!(@flat)
      a = index!(machine, "a")
      b = index!(machine, "b")

      source = Diagram.render(machine, [])
      lines = String.split(source, "\n")

      assert hd(lines) == "stateDiagram-v2"
      assert ~s(state "a" as s#{a}) in Enum.map(lines, &String.trim/1)
      assert ~s(state "b" as s#{b}) in Enum.map(lines, &String.trim/1)
      assert "s#{a} --> s#{b} : go" in Enum.map(lines, &String.trim/1)
    end

    test "marks the chart's initial state from the root" do
      machine = compile!(@flat)
      a = index!(machine, "a")

      source = Diagram.render(machine, [])

      assert "[*] --> s#{a}" in trimmed_lines(source)
    end

    test "renders eventless guarded transitions with a cond marker" do
      machine =
        compile!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a" datamodel="predicator">
              <state id="a">
                <transition cond="true" target="b"/>
              </state>
              <state id="b"/>
            </scxml>
        """)

      a = index!(machine, "a")
      b = index!(machine, "b")

      assert "s#{a} --> s#{b} : [cond]" in trimmed_lines(Diagram.render(machine, []))
    end

    test "renders one edge per target of a multi-target transition" do
      machine =
        compile!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="p">
              <state id="a">
                <transition event="split" target="one two"/>
              </state>
              <parallel id="p">
                <state id="one"/>
                <state id="two"/>
              </parallel>
            </scxml>
        """)

      a = index!(machine, "a")
      one = index!(machine, "one")
      two = index!(machine, "two")
      lines = trimmed_lines(Diagram.render(machine, []))

      assert "s#{a} --> s#{one} : split" in lines
      assert "s#{a} --> s#{two} : split" in lines
    end
  end

  describe "render/2 - active configuration highlighting" do
    test "declares the active class and assigns it to every active state" do
      machine = compile!(@nested)
      outer = index!(machine, "outer")
      inner_a = index!(machine, "inner_a")

      source = Diagram.render(machine, MapSet.new([0, outer, inner_a]))
      lines = trimmed_lines(source)

      assert Enum.any?(lines, &String.starts_with?(&1, "classDef active "))
      assert "class s#{outer},s#{inner_a} active" in lines
    end

    test "omits highlighting entirely for an empty configuration" do
      machine = compile!(@flat)
      source = Diagram.render(machine, MapSet.new())

      refute source =~ "classDef"
      refute source =~ "\nclass "
    end

    test "never assigns the synthesized root a class" do
      machine = compile!(@flat)
      source = Diagram.render(machine, MapSet.new([0]))

      refute source =~ ~r/^\s*class /m
    end

    test "accepts a plain list as the configuration" do
      machine = compile!(@flat)
      a = index!(machine, "a")

      assert "class s#{a} active" in trimmed_lines(Diagram.render(machine, [a]))
    end
  end

  describe "render/2 - compound nesting" do
    test "renders a compound state as a composite block with its own initial" do
      machine = compile!(@nested)
      outer = index!(machine, "outer")
      inner_a = index!(machine, "inner_a")
      inner_b = index!(machine, "inner_b")

      source = Diagram.render(machine, [])
      lines = trimmed_lines(source)

      assert ~s(state "outer" as s#{outer} {) in lines
      assert ~s(state "inner_a" as s#{inner_a}) in lines
      assert "[*] --> s#{inner_a}" in lines
      assert "s#{inner_a} --> s#{inner_b} : step" in lines

      # The composite block closes.
      assert "}" in lines
    end

    test "nested declarations sit inside their parent's block" do
      machine = compile!(@nested)
      outer = index!(machine, "outer")
      inner_a = index!(machine, "inner_a")

      source = Diagram.render(machine, [])

      opens = :binary.match(source, ~s(state "outer" as s#{outer} {)) |> elem(0)
      inner = :binary.match(source, ~s(state "inner_a" as s#{inner_a})) |> elem(0)
      closes = source |> String.reverse() |> :binary.match("}") |> elem(0)
      closes = String.length(source) - closes

      assert opens < inner
      assert inner < closes
    end
  end

  describe "render/2 - parallel states" do
    test "separates parallel regions with the -- divider" do
      machine = compile!(@parallel)
      p = index!(machine, "p")
      r1 = index!(machine, "region_one")
      r2 = index!(machine, "region_two")

      source = Diagram.render(machine, [])
      lines = trimmed_lines(source)

      assert ~s(state "p" as s#{p} {) in lines
      assert "--" in lines

      # Both regions render inside; the divider sits between them.
      r1_at = Enum.find_index(lines, &(&1 == ~s(state "region_one" as s#{r1} {)))
      div_at = Enum.find_index(lines, &(&1 == "--"))
      r2_at = Enum.find_index(lines, &(&1 == ~s(state "region_two" as s#{r2} {)))

      assert r1_at < div_at
      assert div_at < r2_at
    end
  end

  describe "render/2 - cross-hierarchy transitions (the documented Mermaid limit)" do
    test "lifts an edge between substates of different composites to the composites" do
      machine = compile!(@cross)
      left = index!(machine, "left")
      right = index!(machine, "right")
      l1 = index!(machine, "l1")
      r1 = index!(machine, "r1")

      source = Diagram.render(machine, [])
      lines = trimmed_lines(source)

      assert "s#{left} --> s#{right} : jump [lifted: l1 -> r1]" in lines
      refute "s#{l1} --> s#{r1} : jump" in lines
    end

    test "an edge from a substate to a top-level sibling is drawn directly" do
      machine =
        compile!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="outer">
              <state id="outer" initial="inner">
                <state id="inner">
                  <transition event="out" target="other"/>
                </state>
              </state>
              <state id="other"/>
            </scxml>
        """)

      inner = index!(machine, "inner")
      other = index!(machine, "other")

      assert "s#{inner} --> s#{other} : out" in trimmed_lines(Diagram.render(machine, []))
    end
  end

  describe "render/2 - final and history states" do
    test "labels a final state" do
      machine =
        compile!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="a">
              <state id="a">
                <transition event="stop" target="done_state"/>
              </state>
              <final id="done_state"/>
            </scxml>
        """)

      done = index!(machine, "done_state")

      assert "state \"done_state (final)\" as s#{done}" in trimmed_lines(
               Diagram.render(machine, [])
             )
    end

    test "labels shallow and deep history states" do
      machine =
        compile!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="outer">
              <state id="outer" initial="inner">
                <history id="h_shallow" type="shallow">
                  <transition target="inner"/>
                </history>
                <history id="h_deep" type="deep">
                  <transition target="inner"/>
                </history>
                <state id="inner"/>
              </state>
            </scxml>
        """)

      shallow = index!(machine, "h_shallow")
      deep = index!(machine, "h_deep")
      lines = trimmed_lines(Diagram.render(machine, []))

      assert "state \"h_shallow (H)\" as s#{shallow}" in lines
      assert "state \"h_deep (H*)\" as s#{deep}" in lines
    end
  end

  describe "render/2 - anonymous states" do
    test "falls back to an index-derived label for a state without an id" do
      machine =
        compile!("""
            <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0">
              <state>
                <transition event="go" target="b"/>
              </state>
              <state id="b"/>
            </scxml>
        """)

      lines = trimmed_lines(Diagram.render(machine, []))

      assert "state \"(state 1)\" as s1" in lines
    end
  end

  defp trimmed_lines(source) do
    source |> String.split("\n") |> Enum.map(&String.trim/1)
  end
end
