defmodule StatifierUI.Shape do
  @moduledoc """
  Infers a structured shape from a predicator value, and renders that shape
  as a display label.

  `infer/1` walks a value from the predicator value domain (ADR-0003) and
  produces a `t()` term describing its structure - scalars, lists, maps,
  and the predicator-specific `:null` / `:undefined` / `:duration`
  distinctions, plus `:redacted` for a value a projected trace stream is not
  carrying (ADR-0012). `:redacted` is deliberately distinct from
  `:undefined`: a redacted slot held a value, an undefined one did not, and
  a datamodel pane that renders the first as the second reports a live
  datamodel as permanently unbound. `label/2` renders that term as a short human-readable string
  for use in the explorer tree; a later phase's editor completions consume
  the structured term directly instead of the label.

  Kept a pure, standalone module on purpose: it depends on nothing from
  `StatifierUI.Fixtures` and nothing here reaches back into it.
  """

  @duration_keys MapSet.new([
                   :years,
                   :months,
                   :weeks,
                   :days,
                   :hours,
                   :minutes,
                   :seconds,
                   :milliseconds
                 ])

  @type t ::
          :boolean
          | :integer
          | :float
          | :string
          | :date
          | :datetime
          | :duration
          | :null
          | :undefined
          | :redacted
          | :unknown
          | {:list, t() | :empty}
          | {:map, %{optional(String.t()) => t()}}
          | {:union, [t()]}

  @doc """
  Infers a `t()` shape from a predicator value.

  Total over `term()`: anything outside the predicator value domain (a
  tuple, a pid, a reference, an unrecognized struct) infers as `:unknown`
  rather than raising.

  ## Examples

      iex> StatifierUI.Shape.infer(1999)
      :integer

      iex> StatifierUI.Shape.infer(%{"amount" => 1999})
      {:map, %{"amount" => :integer}}

      iex> StatifierUI.Shape.infer(["a", "b"])
      {:list, :string}
  """
  @spec infer(term()) :: t()
  def infer(value)

  def infer(nil), do: :null
  def infer(:undefined), do: :undefined
  def infer(:redacted), do: :redacted
  def infer(value) when is_boolean(value), do: :boolean
  def infer(value) when is_integer(value), do: :integer
  def infer(value) when is_float(value), do: :float
  def infer(value) when is_binary(value), do: :string
  def infer(%Date{}), do: :date
  def infer(%DateTime{}), do: :datetime
  def infer([]), do: {:list, :empty}
  def infer(value) when is_list(value), do: infer_list(value)

  def infer(%_struct{}), do: :unknown

  def infer(value) when is_map(value) do
    if duration?(value) do
      :duration
    else
      infer_map(value)
    end
  end

  def infer(_value), do: :unknown

  @doc """
  Whether `value` is a predicator duration: a non-empty map whose keys are
  atoms drawn from the eight duration units and whose values are all
  integers.

  A **subset** of the units is enough, deliberately. `Predicator.Duration`'s
  own builder returns all eight, but predicator's expression parser returns
  seven - `Predicator.evaluate("3d")` omits `:milliseconds` - so requiring
  the full set misses every duration produced by evaluating an expression,
  which is the common case. Nothing else in the value domain can collide:
  atom keys reach a fixture only from Elixir, and a datamodel forbids them
  outright (`StatifierUI.Fixtures`), so the only atom-keyed maps that arrive
  here are durations.

  Public because `StatifierUI.Fixtures` and `StatifierUI.Value` need the same
  rule, and three copies of it are what let the seven-versus-eight gap go
  unnoticed once already.

  ## Examples

      iex> StatifierUI.Shape.duration?(%{days: 3, hours: 8})
      true

      iex> StatifierUI.Shape.duration?(%{"days" => 3})
      false

  """
  @spec duration?(term()) :: boolean()
  def duration?(value) when is_map(value) and map_size(value) > 0 and not is_struct(value) do
    keys = value |> Map.keys() |> MapSet.new()

    MapSet.subset?(keys, @duration_keys) and
      Enum.all?(Map.values(value), &is_integer/1)
  end

  def duration?(_value), do: false

  @spec infer_map(map()) :: t()
  defp infer_map(value) do
    pairs =
      Map.new(value, fn {key, val} -> {to_string(key), infer(val)} end)

    {:map, pairs}
  end

  @spec infer_list([term(), ...]) :: t()
  defp infer_list(values) do
    shapes = Enum.map(values, &infer/1)
    {:list, unify(shapes)}
  end

  @spec unify([t()]) :: t()
  defp unify(shapes) do
    case Enum.uniq(shapes) do
      [single] ->
        single

      unique ->
        if Enum.all?(unique, &map_shape?/1) do
          unify_maps(unique)
        else
          {:union, Enum.sort(unique)}
        end
    end
  end

  @spec map_shape?(t()) :: boolean()
  defp map_shape?({:map, _pairs}), do: true
  defp map_shape?(_shape), do: false

  @spec unify_maps([t()]) :: t()
  defp unify_maps(map_shapes) do
    all_keys =
      map_shapes
      |> Enum.flat_map(fn {:map, pairs} -> Map.keys(pairs) end)
      |> Enum.uniq()

    unified =
      Map.new(all_keys, fn key ->
        key_shapes =
          Enum.map(map_shapes, fn {:map, pairs} ->
            Map.get(pairs, key, :undefined)
          end)

        {key, unify(Enum.uniq(key_shapes))}
      end)

    {:map, unified}
  end

  @doc """
  Renders a `t()` shape as a short display label.

  Options:

    * `:max_keys` - maximum map pairs shown before truncating to `...`
      (default `4`).
    * `:max_depth` - maximum nesting depth rendered before a nested map or
      list collapses to `map{...}` / `list<...>` (default `3`).

  Truncation is a label-only concern; `infer/1` itself recurses fully.

  ## Examples

      iex> StatifierUI.Shape.label(StatifierUI.Shape.infer(%{"amount" => 1999}))
      "map{amount: integer}"

      iex> StatifierUI.Shape.label(StatifierUI.Shape.infer(["a", "b"]))
      "list<string>"

      iex> shape = StatifierUI.Shape.infer(%{"amount" => 1999, "currency" => "usd"})
      iex> StatifierUI.Shape.label(shape, max_keys: 1)
      "map{amount: integer, ...}"
  """
  @spec label(t(), keyword()) :: String.t()
  def label(shape, opts \\ []) do
    max_keys = Keyword.get(opts, :max_keys, 4)
    max_depth = Keyword.get(opts, :max_depth, 3)
    render(shape, max_keys, max_depth, 0)
  end

  @spec render(t(), pos_integer(), pos_integer(), non_neg_integer()) :: String.t()
  defp render(:boolean, _max_keys, _max_depth, _depth), do: "boolean"
  defp render(:integer, _max_keys, _max_depth, _depth), do: "integer"
  defp render(:float, _max_keys, _max_depth, _depth), do: "float"
  defp render(:string, _max_keys, _max_depth, _depth), do: "string"
  defp render(:date, _max_keys, _max_depth, _depth), do: "date"
  defp render(:datetime, _max_keys, _max_depth, _depth), do: "datetime"
  defp render(:duration, _max_keys, _max_depth, _depth), do: "duration"
  defp render(:null, _max_keys, _max_depth, _depth), do: "null"
  defp render(:undefined, _max_keys, _max_depth, _depth), do: "undefined"
  defp render(:redacted, _max_keys, _max_depth, _depth), do: "redacted"
  defp render(:unknown, _max_keys, _max_depth, _depth), do: "unknown"

  defp render({:list, :empty}, _max_keys, _max_depth, _depth), do: "list<>"

  defp render({:list, inner}, max_keys, max_depth, depth) do
    if depth >= max_depth do
      "list<...>"
    else
      "list<#{render(inner, max_keys, max_depth, depth + 1)}>"
    end
  end

  defp render({:map, pairs}, max_keys, max_depth, depth) do
    if depth >= max_depth do
      "map{...}"
    else
      body =
        pairs
        |> Enum.sort()
        |> render_pairs(max_keys, max_depth, depth)

      "map{#{body}}"
    end
  end

  defp render({:union, shapes}, max_keys, max_depth, depth) do
    Enum.map_join(shapes, "|", &render(&1, max_keys, max_depth, depth))
  end

  @spec render_pairs([{String.t(), t()}], pos_integer(), pos_integer(), non_neg_integer()) ::
          String.t()
  defp render_pairs(pairs, max_keys, max_depth, depth) do
    {shown, rest} = Enum.split(pairs, max_keys)

    rendered =
      Enum.map(shown, fn {key, shape} ->
        "#{key}: #{render(shape, max_keys, max_depth, depth + 1)}"
      end)

    case rest do
      [] -> Enum.join(rendered, ", ")
      _more -> Enum.join(rendered ++ ["..."], ", ")
    end
  end
end
