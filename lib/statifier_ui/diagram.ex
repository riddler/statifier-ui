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
  - Every compound state carries a `[*] --> sN` marker per resolved initial
    state, including one written without an `initial` attribute (the
    compiler resolves it to the first child). A parallel state carries
    none, because entering it enters every region at once.
  - Transitions are labeled with their event descriptors; a guarded
    transition carries a `[cond]` marker (the Machine retains the compiled
    expression, not its source text).
  - A **targetless** transition - spec-legal, and the way a chart runs
    executable content without changing configuration - is drawn as a
    self-edge marked `[internal]`. UML puts one inside the state's box;
    Mermaid has no in-box notation, and dropping the transition entirely
    is worse: it renders a state that handles an event as one that
    ignores it.
  - A transition written `type="internal"` also carries `[internal]`.
    SCXML's `external` default is left unmarked, so the marker means "this
    edge does not exit and re-enter its source".
  - A **history** state's default transition (`State.history_default`) is
    drawn with a `[default]` marker. It is not selectable, so it is not in
    `State.transitions`; without this the `(H)` / `(H*)` label would name a
    pseudo-state whose fallback target is invisible.
  - Active states - every index in the configuration, ancestors included,
    per the full-configuration convention of statifier-ui ADR-0005 - are
    assigned the `active` Mermaid class. Out-of-range indexes and the root
    are ignored, so a stale or empty configuration degrades to an
    unhighlighted chart rather than an error.

  ## Theming the active highlight

  The `active` class is styled by a `classDef` line the source carries, and
  by default that line is the shipped light palette. A host whose chrome is
  dark passes `active_style: :none` to `render/3`, which drops the
  `classDef` and leaves the `class sN active` assignment: the rendered nodes
  still carry the class, so the host's own stylesheet or Mermaid theme
  reaches them. A host that would rather keep the styling inside the source
  passes its own `classDef` body as a binary instead. Neither path asks a
  host to post-process the source it was handed.

  `StatifierUI.Inspector.diagram/3` takes the same option and passes it
  through, and `StatifierUI.Live.diagram/1` takes it as an attribute. The
  Livebook inspector (`StatifierUI.Kino`) builds its own fold options and
  forwards none, so it always draws the default palette.

  ## Known limits of this projection

  These are accepted, not defects to file. Each is a thing the Mermaid
  backend cannot express; the destination elkjs renderer (ADR-0008) is
  where they get fixed, and none of them makes the source *silently*
  wrong - every one is either marked in the output or listed here.

  - **Lifted edges lose their real endpoints in the picture.** A lifted
    edge is drawn composite-to-composite and the true endpoints survive
    only in the `[lifted: ...]` label text, not in the geometry. This also
    covers an edge between two regions of the same parallel state: it is
    lifted to the two regions, which reads as leaving one lane for
    another when the semantics are an exit and re-entry within them.
  - **Internal transitions are drawn as self-edges.** The arrow implies a
    round trip through exit and entry that an internal transition does not
    make; only the `[internal]` marker says otherwise.
  - **Pseudo-states are ordinary nodes.** History and final states are
    drawn as boxes with a label suffix, so a chart with many of them reads
    as having more real states than it has.
  - **Shallow and deep history differ only in the label.** `(H)` versus
    `(H*)` is the whole distinction; what each restores is not drawable.
  - **Executable content is not drawn at all.** `onentry`, `onexit`,
    transition content, `<invoke>` and `donedata` have no notation here.
    An edge label says which event fires a transition, never what it does.
  - **Nothing is laid out by this module.** Mermaid decides geometry, so
    region order within a parallel is document order and nothing keeps a
    deeply nested chart from rendering wider than it is readable.
  """

  alias Statifier.Machine
  alias Statifier.Machine.State
  alias Statifier.Machine.Transition

  @indent "    "

  @default_active_style "fill:#e0f2fe,stroke:#0284c7,stroke-width:2px,color:#0c4a6e"

  @typedoc """
  How the `active` class is styled in the emitted source.

    * `:default` - the shipped light palette, emitted as a `classDef`.
    * `:none` - emit no `classDef` at all. The `class sN active` assignment
      stays, so the rendered nodes still carry the class and the host's own
      stylesheet or Mermaid theme decides how they look.
    * a binary - the body of the `classDef`, verbatim: Mermaid style
      declarations separated by commas, as in
      `"fill:#0c4a6e,stroke:#38bdf8,color:#e0f2fe"`.
  """
  @type active_style :: :default | :none | String.t()

  @typedoc "Options accepted by `render/3`."
  @type opt :: {:active_style, active_style()}

  @doc """
  Renders `machine` with `configuration` highlighted, as Mermaid
  `stateDiagram-v2` source.

  `configuration` is any enumerable of state indexes - typically the full
  active configuration (`MapSet.t(non_neg_integer())`) a trace message or
  `Statifier.MachineState` carries. Pass `[]` (or an empty set) for a chart
  that is not running.

  ## Options

    * `:active_style` - how the active-configuration highlight is styled;
      `t:active_style/0`. Defaults to `:default`, which emits the shipped
      light palette unchanged.

  A host under a dark theme passes `:none` and styles `.active` from its own
  stylesheet, or passes its own `classDef` body as a binary. Neither
  requires post-processing the returned source.

  ## Examples

      iex> {:ok, machine} =
      ...>   Statifier.compile(\"\"\"
      ...>       <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending">
      ...>         <state id="pending">
      ...>           <transition event="authorize.approved" target="authorized"/>
      ...>         </state>
      ...>         <state id="authorized"/>
      ...>       </scxml>
      ...>   \"\"\")
      iex> source = StatifierUI.Diagram.render(machine, [1])
      iex> String.starts_with?(source, "stateDiagram-v2")
      true
      iex> source =~ "class s1 active"
      true
      iex> source =~ "classDef active"
      true

      iex> {:ok, machine} =
      ...>   Statifier.compile(\"\"\"
      ...>       <scxml xmlns="http://www.w3.org/2005/07/scxml" version="1.0" initial="pending">
      ...>         <state id="pending"/>
      ...>       </scxml>
      ...>   \"\"\")
      iex> source = StatifierUI.Diagram.render(machine, [1], active_style: :none)
      iex> source =~ "class s1 active"
      true
      iex> source =~ "classDef"
      false
  """
  @spec render(Machine.t(), Enumerable.t(), [opt()]) :: String.t()
  def render(machine, configuration, opts \\ [])

  def render(%Machine{} = machine, configuration, opts) when is_list(opts) do
    style = active_style(Keyword.get(opts, :active_style, :default))
    root = Machine.at(machine, 0)

    lines =
      ["stateDiagram-v2"] ++
        Enum.flat_map(root.children, &declare(machine, &1, 1)) ++
        initial_lines(machine, root, 1) ++
        transition_lines(machine) ++
        highlight_lines(machine, configuration, style)

    Enum.join(lines, "\n") <> "\n"
  end

  @spec active_style(term()) :: :none | String.t()
  defp active_style(:default), do: @default_active_style
  defp active_style(:none), do: :none
  defp active_style(body) when is_binary(body) and body != "", do: body

  defp active_style(other) do
    raise ArgumentError,
          ":active_style must be :default, :none, or a Mermaid classDef body " <>
            "as a binary, got: #{inspect(other)}"
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
        state = Machine.at(machine, index),
        line <- selectable_lines(machine, state, skip) ++ history_default_lines(machine, state) do
      line
    end
  end

  @spec selectable_lines(Machine.t(), State.t(), MapSet.t(non_neg_integer())) :: [String.t()]
  defp selectable_lines(machine, %State{transitions: transitions}, skip) do
    for t_index <- transitions,
        not MapSet.member?(skip, t_index),
        transition = Machine.transition(machine, t_index),
        line <- edge_lines(machine, transition, nil) do
      line
    end
  end

  # A history state's default transition is not selectable, so it does not
  # live in `State.transitions` - it lives in `history_default`. Drawing it
  # is what makes the `(H)` / `(H*)` label mean something: without it the
  # marker names a pseudo-state whose fallback target is invisible.
  @spec history_default_lines(Machine.t(), State.t()) :: [String.t()]
  defp history_default_lines(_machine, %State{history_default: nil}), do: []

  defp history_default_lines(machine, %State{history_default: t_index}) do
    edge_lines(machine, Machine.transition(machine, t_index), "[default]")
  end

  @spec initial_transition_indexes(Machine.t()) :: MapSet.t(non_neg_integer())
  defp initial_transition_indexes(machine) do
    for index <- 0..(tuple_size(machine.states) - 1)//1,
        t_index = Machine.at(machine, index).initial_transition,
        into: MapSet.new() do
      t_index
    end
  end

  # One line per target, or a single self-edge for a targetless transition.
  @spec edge_lines(Machine.t(), Transition.t(), String.t() | nil) :: [String.t()]
  defp edge_lines(_machine, %Transition{targets: []} = transition, extra) do
    source = transition.source
    [draw(source, source, edge_label(transition, ["[internal]", extra]))]
  end

  defp edge_lines(machine, %Transition{} = transition, extra) do
    Enum.map(transition.targets, fn target ->
      {source, drawn_target, lifted?} = lift(machine, transition.source, target)

      lifted_marker =
        if lifted? do
          "[lifted: #{name(machine, transition.source)} -> #{name(machine, target)}]"
        end

      edge = edge_label(transition, [type_marker(transition), lifted_marker, extra])
      draw(source, drawn_target, edge)
    end)
  end

  @spec draw(non_neg_integer(), non_neg_integer(), String.t()) :: String.t()
  defp draw(source, target, ""), do: "#{@indent}s#{source} --> s#{target}"
  defp draw(source, target, label), do: "#{@indent}s#{source} --> s#{target} : #{label}"

  @spec edge_label(Transition.t(), [String.t() | nil]) :: String.t()
  defp edge_label(transition, markers) do
    [events_label(transition), cond_label(transition) | markers]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  # An `internal` transition to a descendant neither exits nor re-enters the
  # source, which the arrow alone cannot say; SCXML's `external` default is
  # left unmarked so the marker means "this one is unusual".
  @spec type_marker(Transition.t()) :: String.t() | nil
  defp type_marker(%Transition{type: :internal}), do: "[internal]"
  defp type_marker(%Transition{}), do: nil

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

  @spec highlight_lines(Machine.t(), Enumerable.t(), :none | String.t()) :: [String.t()]
  defp highlight_lines(machine, configuration, style) do
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
        class_def(style) ++
          [@indent <> "class " <> Enum.map_join(indexes, ",", &"s#{&1}") <> " active"]
    end
  end

  @spec class_def(:none | String.t()) :: [String.t()]
  defp class_def(:none), do: []
  defp class_def(style), do: [@indent <> "classDef active " <> style]

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
