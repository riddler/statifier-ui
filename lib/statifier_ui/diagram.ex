defmodule StatifierUI.Diagram do
  @moduledoc """
  Renders a compiled `Statifier.Machine` and an active configuration as
  Mermaid `stateDiagram-v2` source, for display via `Kino.Mermaid` (or any
  other Mermaid consumer - this module is pure and depends on neither Kino
  nor LiveView).

  `render/2` is a pure function: machine and configuration in, diagram
  source out. That interface is the stable part. The Mermaid backend is the
  Livebook inspector's first rendering (statifier-ui ADR-0008 fixes the
  destination stack as client-side elkjs producing SVG, and explicitly
  leaves this first cut to the inspector epic); when the elkjs renderer
  arrives it replaces the body of this module, not its callers.

  ## The accepted Mermaid compromise

  Mermaid cannot draw a transition between internal states of two
  *different* composite states - the cross-hierarchy edges SCXML's LCCA
  semantics make routine, and the limitation that disqualified Mermaid as
  the destination renderer (ADR-0008). Rather than drop those transitions,
  `render/2` lifts each one to the pair of composite siblings under the
  endpoints' least common ancestor and draws the edge there, with a
  `[lifted: <source> -> <target>]` marker appended to the label naming the
  real endpoints. The same lifting applies to a composite's `[*]` initial
  marker when its resolved initial state is a deep descendant rather than a
  direct child - the marker there is `[deep: <target>]`.

  ## What the source contains

  - Every state except the synthesized `:scxml` root is declared with a
    stable `s<index>` alias (the engine's document-order state index, the
    identity vocabulary of statifier ADR-0012), so tests and callers can
    address nodes without depending on how labels are escaped.
  - Compound states are composite blocks; parallel states are composite
    blocks whose children are separated by Mermaid's `--` region divider.
  - `<final>` states carry a `(final)` label suffix; history states carry
    `(H)` (shallow) or `(H*)` (deep) - Mermaid has no native pseudo-state
    notation for either.
  - Transitions are labeled with their event descriptors; a guarded
    transition carries a `[cond]` marker (the Machine retains the compiled
    expression, not its source text).
  - Active states - every index in the configuration, ancestors included,
    per the full-configuration convention of statifier-ui ADR-0005 - are
    assigned the `active` Mermaid class. Out-of-range indexes and the root
    are ignored, so a stale or empty configuration degrades to an
    unhighlighted chart rather than an error.
  """

  alias Statifier.Machine
  alias Statifier.Machine.State
  alias Statifier.Machine.Transition

  @indent "    "

  @active_class "classDef active fill:#e0f2fe,stroke:#0284c7," <>
                  "stroke-width:2px,color:#0c4a6e"

  @doc """
  Renders `machine` with `configuration` highlighted, as Mermaid
  `stateDiagram-v2` source.

  `configuration` is any enumerable of state indexes - typically the full
  active configuration (`MapSet.t(non_neg_integer())`) a trace message or
  `Statifier.MachineState` carries. Pass `[]` (or an empty set) for a chart
  that is not running.

  ## Examples

      iex> {:ok, machine} =
      ...>   Statifier.compile(\"\"\"
      ...>       <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="on">
      ...>         <state id="on">
      ...>           <transition event="toggle" target="off"/>
      ...>         </state>
      ...>         <state id="off"/>
      ...>       </scxml>
      ...>   \"\"\")
      iex> source = StatifierUI.Diagram.render(machine, [1])
      iex> String.starts_with?(source, "stateDiagram-v2")
      true
      iex> source =~ "class s1 active"
      true
  """
  @spec render(Machine.t(), Enumerable.t()) :: String.t()
  def render(%Machine{} = machine, configuration) do
    root = Machine.at(machine, 0)

    lines =
      ["stateDiagram-v2"] ++
        Enum.flat_map(root.children, &declare(machine, &1, 1)) ++
        initial_lines(machine, root, 1) ++
        transition_lines(machine) ++
        highlight_lines(machine, configuration)

    Enum.join(lines, "\n") <> "\n"
  end

  # ── Declarations ──────────────────────────────────────────────────

  @spec declare(Machine.t(), non_neg_integer(), pos_integer()) :: [String.t()]
  defp declare(machine, index, depth) do
    state = Machine.at(machine, index)
    pad = String.duplicate(@indent, depth)

    case state do
      %State{children: []} ->
        [~s(#{pad}state "#{label(state)}" as s#{index})]

      %State{kind: :parallel} = parallel ->
        regions =
          parallel.children
          |> Enum.map(&declare(machine, &1, depth + 1))
          |> Enum.intersperse([pad <> @indent <> "--"])
          |> List.flatten()

        [~s(#{pad}state "#{label(parallel)}" as s#{index} {)] ++
          regions ++ ["#{pad}}"]

      %State{} = compound ->
        [~s(#{pad}state "#{label(compound)}" as s#{index} {)] ++
          Enum.flat_map(compound.children, &declare(machine, &1, depth + 1)) ++
          initial_lines(machine, compound, depth + 1) ++
          ["#{pad}}"]
    end
  end

  # A `[*] --> sN` marker per resolved initial state. A parallel state
  # enters every region, so it gets no markers. An initial state that is
  # not a direct child is lifted to the direct child on its path, with a
  # `[deep: ...]` marker naming the real target (see the moduledoc).
  @spec initial_lines(Machine.t(), State.t(), pos_integer()) :: [String.t()]
  defp initial_lines(_machine, %State{kind: :parallel}, _depth), do: []

  defp initial_lines(machine, %State{index: index, initial: initial}, depth) do
    pad = String.duplicate(@indent, depth)

    Enum.map(initial, fn target ->
      case child_toward(machine, index, target) do
        ^target -> "#{pad}[*] --> s#{target}"
        lifted -> "#{pad}[*] --> s#{lifted} : [deep: #{name(machine, target)}]"
      end
    end)
  end

  # ── Transitions ───────────────────────────────────────────────────

  @spec transition_lines(Machine.t()) :: [String.t()]
  defp transition_lines(machine) do
    skip = initial_transition_indexes(machine)

    for index <- 1..(tuple_size(machine.states) - 1)//1,
        t_index <- Machine.at(machine, index).transitions,
        not MapSet.member?(skip, t_index),
        transition = Machine.transition(machine, t_index),
        target <- transition.targets do
      edge_line(machine, transition, target)
    end
  end

  @spec initial_transition_indexes(Machine.t()) :: MapSet.t(non_neg_integer())
  defp initial_transition_indexes(machine) do
    for index <- 0..(tuple_size(machine.states) - 1)//1,
        t_index = Machine.at(machine, index).initial_transition,
        into: MapSet.new() do
      t_index
    end
  end

  @spec edge_line(Machine.t(), Transition.t(), non_neg_integer()) :: String.t()
  defp edge_line(machine, transition, target) do
    {source, drawn_target, lifted?} = lift(machine, transition.source, target)

    marker =
      if lifted? do
        "[lifted: #{name(machine, transition.source)} -> #{name(machine, target)}]"
      end

    edge_label =
      [events_label(transition), cond_label(transition), marker]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    line = "#{@indent}s#{source} --> s#{drawn_target}"
    if edge_label == "", do: line, else: "#{line} : #{edge_label}"
  end

  @spec events_label(Transition.t()) :: String.t() | nil
  defp events_label(%Transition{events: []}), do: nil

  defp events_label(%Transition{events: events}) do
    Enum.map_join(events, " ", &Enum.join(&1, "."))
  end

  @spec cond_label(Transition.t()) :: String.t() | nil
  defp cond_label(%Transition{cond: nil}), do: nil
  defp cond_label(%Transition{}), do: "[cond]"

  # Mermaid draws an edge unless *both* endpoints sit strictly inside
  # different composite children of their least common ancestor. In that
  # one case, lift each endpoint to its composite child of the LCA.
  @spec lift(Machine.t(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer(), boolean()}
  defp lift(machine, source, target) do
    lca = last_common(ancestry(machine, source), ancestry(machine, target))
    source_child = child_toward(machine, lca, source)
    target_child = child_toward(machine, lca, target)

    if source_child not in [nil, source] and target_child not in [nil, target] do
      {source_child, target_child, true}
    else
      {source, target, false}
    end
  end

  # ── Highlighting ──────────────────────────────────────────────────

  @spec highlight_lines(Machine.t(), Enumerable.t()) :: [String.t()]
  defp highlight_lines(machine, configuration) do
    count = tuple_size(machine.states)

    drawn =
      configuration
      |> MapSet.new()
      |> Enum.filter(&(is_integer(&1) and &1 > 0 and &1 < count))
      |> Enum.sort()

    case drawn do
      [] ->
        []

      indexes ->
        [
          @indent <> @active_class,
          @indent <> "class " <> Enum.map_join(indexes, ",", &"s#{&1}") <> " active"
        ]
    end
  end

  # ── Naming ────────────────────────────────────────────────────────

  @spec label(State.t()) :: String.t()
  defp label(%State{kind: :final} = state), do: "#{base_name(state)} (final)"

  defp label(%State{kind: :history, history_type: :deep} = state) do
    "#{base_name(state)} (H*)"
  end

  defp label(%State{kind: :history} = state), do: "#{base_name(state)} (H)"
  defp label(%State{} = state), do: base_name(state)

  @spec base_name(State.t()) :: String.t()
  defp base_name(%State{id: nil, index: index}), do: "(state #{index})"
  defp base_name(%State{id: id}), do: String.replace(id, ~s("), "'")

  @spec name(Machine.t(), non_neg_integer()) :: String.t()
  defp name(machine, index), do: base_name(Machine.at(machine, index))

  # ── Hierarchy walks ───────────────────────────────────────────────

  # Root-first ancestor chain, `index` included.
  @spec ancestry(Machine.t(), non_neg_integer()) :: [non_neg_integer()]
  defp ancestry(machine, index), do: ancestry(machine, index, [])

  defp ancestry(_machine, nil, acc), do: acc

  defp ancestry(machine, index, acc) do
    ancestry(machine, Machine.at(machine, index).parent, [index | acc])
  end

  @spec last_common([non_neg_integer()], [non_neg_integer()]) :: non_neg_integer()
  defp last_common([x, a | as], [x, b | bs]) when a == b do
    last_common([a | as], [b | bs])
  end

  defp last_common([x | _], [x | _]), do: x

  # The direct child of `ancestor` on the path down to `descendant`;
  # `descendant` itself when it is that child, `nil` when `descendant`
  # is `ancestor`.
  @spec child_toward(Machine.t(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer() | nil
  defp child_toward(_machine, ancestor, ancestor), do: nil

  defp child_toward(machine, ancestor, descendant) do
    case Machine.at(machine, descendant).parent do
      ^ancestor -> descendant
      parent -> child_toward(machine, ancestor, parent)
    end
  end
end
