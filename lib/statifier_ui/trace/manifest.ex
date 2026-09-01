defmodule StatifierUI.Trace.Manifest do
  @moduledoc """
  Turns a compiled `%Statifier.Machine{}` plus caller-supplied context into
  the `session.start` definition message (`docs/wire-format.md`) - the
  message that makes every later index (state `index`, `t_index`,
  `c_index`, `d_index`) resolvable to a source location without a compiler
  on the reading end.
  Pure, no process.

  The Machine does not retain the SCXML source text and has no
  `id -> index` reverse map beyond the partial `id_to_index`
  (`deps/statifier/lib/statifier/machine.ex:29`), so the state table is built
  by walking `machine.states` (a tuple in document order) rather than by any
  lookup, and `source` is accepted from the caller rather than derived
  (decision 7 of the plan).

  ## The `Content.Script`/`Content.Assign` location gotcha

  Every executable-content node kind carries a `:location` field holding its
  own `%Statifier.Parser.Location{}` span, with two exceptions this module
  handles explicitly rather than by a generic fallback:

  - `Statifier.Machine.Content.Script` has no `:location` field at all - its
    span lives on `:node_location` instead
    (`deps/statifier/lib/statifier/machine/content/script.ex:48`).
  - `Statifier.Machine.Content.Assign` has *both* fields, but its `:location`
    is a `String.t()` - the raw, uncompiled `location` attribute (a path
    expression such as `"foo.bar"`), not a location span. Its span is on
    `:node_location`
    (`deps/statifier/lib/statifier/machine/content/assign.ex:42-46`).

  A naive `Map.get(node, :location) || Map.get(node, :node_location)`
  handles `Script` correctly (its `:location` key does not exist, so
  `Map.get/2` returns `nil` and the fallback wins) but silently picks the
  wrong value for `Assign` - its `:location` is a truthy string, so the `||`
  never reaches `:node_location`, and a string ends up where a location
  object belongs. `content_location/1` below dispatches on the struct
  itself instead, naming `Assign` and `Script` as the two kinds whose span
  is `:node_location` and treating every other kind's `:location` as the
  span it already is.

  ## `attribute_locations`: key presence is the contract

  A state row and a transition row each carry an `attribute_locations`
  object alongside the element-level `location`, built from the Machine
  field of the same name (`Statifier.Machine.State`,
  `Statifier.Machine.Transition`). It maps an attribute name to that
  attribute's own value span, and its value is not the interesting part:
  **an entry exists only for an attribute the author actually wrote**, so
  `Map.has_key?(row["attribute_locations"], "type")` is the "was `type`
  written" question that `type`'s own value cannot answer once lowering has
  applied the `:external` default. The map is carried verbatim from the
  Document node through the Machine, so that contract survives the whole
  trip to the wire.

  The object is always present and is `%{}` for an element that wrote no
  attributes at all, for the synthesized initial transition no author wrote,
  and for a Machine compiled by an engine old enough not to populate the
  field. Those three are indistinguishable on the wire and deliberately so:
  a consumer that finds no entry for the attribute it wants falls back to
  the row's element-level `location`, which is exactly the granularity the
  format offered before this field existed.

  `cond_location` stays where it is. It is not folded into this object
  because it carries a fallback the raw map does not - the transition's own
  `location` when `cond` was written without a recorded span - so the two
  answer different questions. Prefer `attribute_locations["cond"]` for new
  work; read `cond_location` when the fallback is what is wanted.
  """

  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Machine.Data
  alias Statifier.Machine.State
  alias Statifier.Machine.Transition
  alias Statifier.Parser.Location
  alias StatifierUI.Trace.Message

  @typedoc "Caller-supplied context `build/3` cannot derive from the Machine alone."
  @type opts :: [
          source: String.t(),
          fixtures: map(),
          parent_session: String.t(),
          invokeid: String.t()
        ]

  @manifest_version 1

  @doc "The `session.start` schema version this module produces - `1` (ADR-0005's initial value)."
  @spec version() :: pos_integer()
  def version, do: @manifest_version

  @doc """
  Builds the `session.start` message for `machine`, stamped `session:
  session` and `seq: 0`.

  Returns `{:error, {:invalid_fixtures, opts[:fixtures]}}` when `:fixtures`
  is supplied and is not a map, and `{:error, {:invalid_source,
  opts[:source]}}` when `:source` is supplied and is not a binary. Nothing
  else can fail: every other field comes from a compiled `Machine`, which is
  well-formed by construction.
  """
  @spec build(Machine.t(), session :: String.t(), opts()) :: {:ok, Message.t()} | {:error, term()}
  def build(%Machine{} = machine, session, opts \\ []) when is_binary(session) do
    with {:ok, source} <- validate_source(Keyword.get(opts, :source)),
         {:ok, fixtures} <- validate_fixtures(Keyword.get(opts, :fixtures)) do
      payload =
        %{
          "version" => @manifest_version,
          "states" => states(machine),
          "transitions" => transitions(machine),
          "contents" => contents(machine),
          "data" => data(machine)
        }
        |> put_present("source", source)
        |> put_present("fixtures", fixtures)
        |> put_present("parent_session", Keyword.get(opts, :parent_session))
        |> put_present("invokeid", Keyword.get(opts, :invokeid))

      Message.validate(%Message{
        type: "session.start",
        session: session,
        seq: 0,
        payload: payload
      })
    end
  end

  @spec validate_source(term()) :: {:ok, String.t() | nil} | {:error, {:invalid_source, term()}}
  defp validate_source(nil), do: {:ok, nil}
  defp validate_source(source) when is_binary(source), do: {:ok, source}
  defp validate_source(other), do: {:error, {:invalid_source, other}}

  @spec validate_fixtures(term()) :: {:ok, map() | nil} | {:error, {:invalid_fixtures, term()}}
  defp validate_fixtures(nil), do: {:ok, nil}
  defp validate_fixtures(fixtures) when is_map(fixtures), do: {:ok, fixtures}
  defp validate_fixtures(other), do: {:error, {:invalid_fixtures, other}}

  # -- states -----------------------------------------------------------------

  @spec states(Machine.t()) :: [map()]
  defp states(%Machine{states: states}) do
    states
    |> Tuple.to_list()
    |> Enum.map(&state_object/1)
  end

  @spec state_object(State.t()) :: map()
  defp state_object(%State{} = state) do
    %{
      "index" => state.index,
      "kind" => Atom.to_string(state.kind),
      "children" => state.children,
      "transitions" => state.transitions,
      "location" => location_object(state.location),
      "attribute_locations" => attribute_locations_object(state.attribute_locations)
    }
    |> put_present("id", state.id)
    |> put_present("parent", state.parent)
  end

  # -- transitions --------------------------------------------------------------

  @spec transitions(Machine.t()) :: [map()]
  defp transitions(%Machine{transitions: transitions}) do
    transitions
    |> Tuple.to_list()
    |> Enum.map(&transition_object/1)
  end

  @spec transition_object(Transition.t()) :: map()
  defp transition_object(%Transition{} = transition) do
    %{
      "t_index" => transition.t_index,
      "source" => transition.source,
      "targets" => transition.targets,
      "events" => transition.events,
      "type" => Atom.to_string(transition.type),
      "content" => transition.content,
      "location" => location_object(transition.location),
      "attribute_locations" => attribute_locations_object(transition.attribute_locations)
    }
    |> put_present("cond_location", location_object_or_nil(transition.cond_location))
  end

  # -- contents -----------------------------------------------------------------

  @spec contents(Machine.t()) :: [map()]
  defp contents(%Machine{contents: contents}) do
    contents
    |> Tuple.to_list()
    |> Enum.map(&content_object/1)
  end

  @spec content_object(Content.t()) :: map()
  defp content_object(node) do
    %{
      "c_index" => node.c_index,
      "kind" => content_kind(node),
      "location" => location_object(content_location(node))
    }
  end

  # The struct module's last segment, underscored - "Raise" -> "raise",
  # "Assign" -> "assign", "Script" -> "script", and so on, matching
  # `docs/wire-format.md`'s `contents.kind` enumeration.
  @spec content_kind(Content.t()) :: String.t()
  defp content_kind(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
  end

  # `Content.Script` has no `:location` field at all; `Content.Assign` has
  # one, but it is the raw (uncompiled) `location` *attribute* string, not a
  # span - see the moduledoc's gotcha section. Both kinds' span is
  # `:node_location`. Every other kind's `:location` is already the span.
  @spec content_location(Content.t()) :: Location.t()
  defp content_location(%Content.Assign{node_location: node_location}), do: node_location
  defp content_location(%Content.Script{node_location: node_location}), do: node_location
  defp content_location(%{location: %Location{} = location}), do: location

  # -- data ---------------------------------------------------------------------

  @spec data(Machine.t()) :: [map()]
  defp data(%Machine{data_elements: data_elements}) do
    data_elements
    |> Tuple.to_list()
    |> Enum.map(&data_object/1)
  end

  @spec data_object(Data.t()) :: map()
  defp data_object(%Data{} = element) do
    %{
      "d_index" => element.d_index,
      "id" => element.id,
      "location" => location_object(element.location)
    }
    |> put_present("value_location", location_object_or_nil(element.value_location))
  end

  # -- Locations ----------------------------------------------------------------

  # A location is always all six fields, wholly present - there is no
  # partial location on a compiled Machine.
  @spec location_object(Location.t()) :: map()
  defp location_object(%Location{} = location) do
    %{
      "start_line" => location.start_line,
      "start_column" => location.start_column,
      "start_offset" => location.start_offset,
      "end_line" => location.end_line,
      "end_column" => location.end_column,
      "end_offset" => location.end_offset
    }
  end

  # The attribute name is an atom on the Machine and a string on the wire.
  # The map is passed through key by key rather than filtered: what the
  # compiler recorded is exactly what a consumer needs, and dropping a key
  # here would destroy the key-presence contract this field exists to carry.
  @spec attribute_locations_object(%{optional(atom()) => Location.t()}) :: map()
  defp attribute_locations_object(attribute_locations) do
    Map.new(attribute_locations, fn {attribute, %Location{} = location} ->
      {Atom.to_string(attribute), location_object(location)}
    end)
  end

  @spec location_object_or_nil(Location.t() | nil) :: map() | nil
  defp location_object_or_nil(nil), do: nil
  defp location_object_or_nil(%Location{} = location), do: location_object(location)

  @spec put_present(map(), String.t(), term()) :: map()
  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
