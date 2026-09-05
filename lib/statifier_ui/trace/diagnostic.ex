defmodule StatifierUI.Trace.Diagnostic do
  @moduledoc """
  The wire `error` object: what `docs/wire-format.md` documents as an event
  object's `error` key.

  It has two arms, discriminated on the wire by `"class"` (ADR-0014).
  `object/4` renders an expression failure (`class: "expression"`) and is
  the bulk of this module - spans, anchors, and the `location_kind`
  discipline below are all its. `reason_object/4` renders a non-value
  reason term (`class: "reason"`), peeling `{:nested_content, _, _}` first
  so a wrapped expression failure comes back through `object/4` with its
  span intact rather than as an opaque string.

  This is the **only** caller of `Statifier.Parser.Location.resolve_span/4`
  in this repo (ADR-0002 - never reimplement the engine's span composition
  locally). Every span this module emits, and every location it composes
  from one, follows that helper's convention: both the predicator span's
  end and the returned location's end are **exclusive**.

  `resolve_span/4` degrades rather than raising - a position past the end
  of the value clamps to the value location's end, and a raw/expanded
  desync returns the value location whole - so this module never rescues
  it. Per project convention (CLAUDE.md, "errors are values / never
  rescue-to-default at a leaf"), a call that could fail is not the shape
  the failure takes here: the helper's own degraded return already is the
  fallback.

  A `nil` value location or a `nil` span means there is nothing to resolve.
  `anchor/3` never calls `resolve_span/4` in either case - it returns
  `{:node, _}` instead, so `object/4` falls back to the owning node's own
  span. That branch is this module deciding *not to call* the helper, which
  is a different thing from catching what it raises.

  ## `location_kind` reports what the producer did, not what the helper decided

  `"resolved"` means `resolve_span/4` was called with a value location and
  a span. `"node"` means it was not (no span, or no value location) and the
  owning node's own span was emitted instead. This module never inspects
  the *result* to guess which happened - `resolve_span/4`'s own degraded
  return (falling back to the value location whole) is indistinguishable
  from a genuine resolution by looking at the location alone, and modeling
  that distinction here would be exactly the ADR-0002 failure this module
  exists to prevent. So `"resolved"` may still span the whole attribute
  value when the helper degraded internally.
  """

  alias Statifier.Evaluator
  alias Statifier.Machine
  alias Statifier.Machine.Content
  alias Statifier.Machine.Param
  alias Statifier.Parser.Location

  @doc """
  The wire `error` object for `error`, raised with cause `origin`.

  `"class"` is always `"expression"` here - ADR-0014's discriminator,
  explicit on both arms rather than absent-means-expression, so a consumer
  never infers the class from a key's absence. `"kind"` and `"expression"`
  are always present. `"span"` is present only
  when `error.span` is non-nil. `"location"`/`"location_kind"` are present
  only when both `machine` and `source` are supplied *and* `anchor/3` finds
  a location to anchor on - `origin` of `nil`, `machine`/`source` of `nil`,
  or an origin `anchor/3` cannot resolve at all all omit both keys, key
  absence being the ADR-0005 discipline for "nothing here" rather than a
  null or a sentinel.
  """
  @spec object(
          Evaluator.Error.t(),
          Statifier.Event.Cause.origin() | nil,
          Machine.t() | nil,
          String.t() | nil
        ) :: map()
  def object(%Evaluator.Error{} = error, origin, machine, source) do
    %{"class" => "expression", "kind" => kind(error.error), "expression" => error.source}
    |> put_span(error.span)
    |> put_location(error, origin, machine, source)
  end

  @doc """
  The wire `error` object for a **non-value reason** term - ADR-0014's
  `class: "reason"` arm, and the terms it peels on the way there.

  `term` is the unconstrained `reason` `Statifier.Interpreter.Content`
  raises an execution error with, which reaches an `error.execution` or
  `error.communication` event's `data` as a tagged tuple, a bare atom, or
  anything else at all. Three things happen to it here, in this order:

  1. **`{:nested_content, c_index, inner}` is peeled**, repeatedly,
     collecting each `c_index` in order into `"content_path"`. The wrapper
     is what an `<if>` partition or a `<foreach>` body puts around a failure
     raised inside it, and treating it as opaque would leave every nested
     expression failure rendering as a string - ADR-0014 decision 4.
  2. **An innermost `%Statifier.Evaluator.Error{}` routes to `object/4`**,
     so a wrapped expression failure keeps its span and its location and
     renders as `class: "expression"`, with `"content_path"` beside it.
  3. **Anything else renders as `class: "reason"`**: `"kind"` derived from
     the term's shape by `reason_kind/1`, and `"reason"` the whole term's
     `inspect/1`.

  `"reason"` is documented on the wire as human-readable text rather than
  structured data to branch on, the same wording `session.terminated`'s
  `reason` carries. `"kind"` is the branchable half.

  `"location"`/`"location_kind"` are present only when the producer could
  anchor, and on this arm the anchor is always the owning node's own span
  (`location_kind: "node"`): there is no expression span to resolve
  against, so `anchor/3` is called with no error at all.
  """
  @spec reason_object(
          term(),
          Statifier.Event.Cause.origin() | nil,
          Machine.t() | nil,
          String.t() | nil
        ) :: map()
  def reason_object(term, origin, machine, source) do
    {content_path, innermost} = peel(term, [])

    innermost
    |> classified(origin, machine, source)
    |> put_content_path(content_path)
  end

  @spec classified(
          term(),
          Statifier.Event.Cause.origin() | nil,
          Machine.t() | nil,
          String.t() | nil
        ) ::
          map()
  defp classified(%Evaluator.Error{} = error, origin, machine, source),
    do: object(error, origin, machine, source)

  defp classified(term, origin, machine, source) do
    %{"class" => "reason", "kind" => reason_kind(term), "reason" => inspect(term)}
    |> put_node_location(origin, machine, source)
  end

  # `c_index` values only - a `{:nested_content, _, _}` whose second element
  # is not a content index is not the engine's wrapper, so it is classified
  # as an ordinary tagged tuple rather than peeled into a `content_path`
  # this format promises is a `session.start` contents-table index.
  @spec peel(term(), [non_neg_integer()]) :: {[non_neg_integer()], term()}
  defp peel({:nested_content, c_index, inner}, path) when is_integer(c_index) and c_index >= 0,
    do: peel(inner, [c_index | path])

  defp peel(term, path), do: {Enum.reverse(path), term}

  @spec put_content_path(map(), [non_neg_integer()]) :: map()
  defp put_content_path(object, []), do: object
  defp put_content_path(object, path), do: Map.put(object, "content_path", path)

  # ADR-0014 decision 2: derived from the term's shape, never from a table
  # of statifier's tags. The tags belong to the engine, they arrive with
  # engine ADRs, and a table here would be stale on the next one.
  @spec reason_kind(term()) :: String.t()
  defp reason_kind(term) when is_atom(term), do: Atom.to_string(term)

  defp reason_kind(term) when is_tuple(term) and tuple_size(term) > 0 do
    case elem(term, 0) do
      tag when is_atom(tag) -> Atom.to_string(tag)
      _other -> "unknown"
    end
  end

  defp reason_kind(_term), do: "unknown"

  @doc """
  Where to anchor `error`'s span for `origin`: the value location of the
  failing expression (`{:value, _}`, resolved against `error.span` by the
  caller), the owning node's own span with nothing further to resolve
  (`{:node, _}`), or nothing at all (`:none`).

  Dispatches on `origin` and, for content, on the content struct itself -
  never on a generic `Map.get(node, :location) || Map.get(node, :node_location)`
  reflection, the same posture `StatifierUI.Trace.Manifest`'s own
  content-location dispatch takes and for the same reason: that fallback
  is silently wrong for
  `Statifier.Machine.Content.Assign`, whose `:location` is a path-expression
  *string*, not a span.

  A candidate value location is only ever returned as `{:value, _}` when
  `error.span` is non-nil - a `nil` span means `resolve_span/4` would not be
  called, so the caller must not be handed a location that invites it.

  `error` of `nil` is ADR-0014's `class: "reason"` arm: there is no
  expression and no span, so every origin that names a node at all returns
  `{:node, _}` and nothing ever returns `{:value, _}`.
  """
  @spec anchor(Statifier.Event.Cause.origin() | nil, Machine.t(), Evaluator.Error.t() | nil) ::
          {:value, Location.t()} | {:node, Location.t()} | :none
  def anchor(nil, _machine, _error), do: :none

  def anchor({:transition, t_index}, machine, error) do
    transition = Machine.transition(machine, t_index)
    value_or_node(transition.cond_location, transition.location, error)
  end

  # `Statifier.Machine.Data.value_location` falls back to the element's own
  # `location` when there is no distinct value span. The wire format drops
  # that fallback and omits the key instead (`docs/wire-format.md:420-432`),
  # but this reads the compiled struct, where the fallback is still present:
  # anchoring on it would be anchoring on the whole `<data>` element, which
  # is what `{:node, _}` already does honestly. Equal means `{:node, _}`.
  def anchor({:data, d_index}, machine, error) do
    data = Machine.data(machine, d_index)

    candidate =
      if data.value_location && data.value_location != data.location do
        data.value_location
      end

    value_or_node(candidate, data.location, error)
  end

  def anchor({:content, c_index, _owner}, machine, error) do
    node = Machine.content(machine, c_index)

    value_or_node(
      content_expr_location(node, error_source(error)),
      content_node_location(node),
      error
    )
  end

  def anchor({:state, state_index}, machine, _error) do
    {:node, Machine.at(machine, state_index).location}
  end

  def anchor({:donedata_param, state_index, param_index}, machine, error) do
    state = Machine.at(machine, state_index)

    case donedata_param(state, param_index) do
      nil -> :none
      %Param{} = param -> value_or_node(param.expr_location, param.location, error)
    end
  end

  # `Statifier.Machine.program()` (`{:program, compiled, source}`) carries
  # no `Statifier.Parser.Location` at all - unlike every other origin's
  # target, a top-level `<script>` has no node struct here to name a span
  # with, so the machine genuinely names nothing for this origin.
  def anchor({:global_script, _index}, _machine, _error), do: :none

  def anchor({:invoke, state_index, invoke_index}, machine, _error) do
    invoke_node(machine, state_index, invoke_index)
  end

  def anchor({:finalize, state_index, invoke_index}, machine, _error) do
    invoke_node(machine, state_index, invoke_index)
  end

  def anchor(_origin, _machine, _error), do: :none

  @spec invoke_node(Machine.t(), non_neg_integer(), non_neg_integer()) ::
          {:node, Location.t()} | :none
  defp invoke_node(machine, state_index, invoke_index) do
    case Enum.at(Machine.at(machine, state_index).invoke, invoke_index) do
      nil -> :none
      invoke -> {:node, invoke.location}
    end
  end

  @spec donedata_param(Statifier.Machine.State.t(), non_neg_integer()) :: Param.t() | nil
  defp donedata_param(%{donedata: nil}, _param_index), do: nil

  defp donedata_param(%{donedata: donedata}, param_index),
    do: Enum.at(donedata.params, param_index)

  # `candidate` is a value location worth trying to resolve - or `nil`,
  # meaning there either was none or the caller already ruled it out (the
  # `<data>` "no distinct value" case). Only ever `{:value, _}` when
  # `error.span` is non-nil, per this module's own "nil span means the
  # helper is not called" rule.
  @spec error_source(Evaluator.Error.t() | nil) :: String.t() | nil
  defp error_source(%Evaluator.Error{source: source}), do: source
  defp error_source(nil), do: nil

  @spec value_or_node(Location.t() | nil, Location.t(), Evaluator.Error.t() | nil) ::
          {:value, Location.t()} | {:node, Location.t()}
  defp value_or_node(nil, node_location, _error), do: {:node, node_location}

  defp value_or_node(_candidate, node_location, nil), do: {:node, node_location}

  defp value_or_node(_candidate, node_location, %Evaluator.Error{span: nil}),
    do: {:node, node_location}

  defp value_or_node(candidate, _node_location, %Evaluator.Error{span: span})
       when not is_nil(span),
       do: {:value, candidate}

  # The explicit per-kind expression-span table (plan's "Bounds on the
  # anchor/3 table for this phase"): `Content.Log.expr_location`,
  # `Content.Assign.expr_location`, `Content.Foreach.array_location` - the
  # only one of `Foreach`'s three `*_location` fields that spans an
  # expression, `item_location`/`index_location` span datamodel location
  # paths instead - and, for `Content.If`, the branch whose compiled
  # `{:compiled, _, source}` matches `error.source` selects among several
  # candidate guards. Every other kind (`Content.Send`, `Content.Cancel`,
  # `Content.Script`, `Content.Raise`), or an `If` with no matching branch,
  # has no expression candidate here.
  @spec content_expr_location(Content.t(), String.t() | nil) :: Location.t() | nil
  defp content_expr_location(%Content.Log{expr_location: expr_location}, _source),
    do: expr_location

  defp content_expr_location(%Content.Assign{expr_location: expr_location}, _source),
    do: expr_location

  defp content_expr_location(%Content.Foreach{array_location: array_location}, _source),
    do: array_location

  defp content_expr_location(%Content.If{branches: branches}, source) do
    branches
    |> Enum.find(&branch_matches?(&1, source))
    |> case do
      nil -> nil
      branch -> branch.cond_location
    end
  end

  defp content_expr_location(_node, _source), do: nil

  @spec branch_matches?(Content.If.Branch.t(), String.t() | nil) :: boolean()
  defp branch_matches?(%Content.If.Branch{cond: {:compiled, _compiled, source}}, source), do: true
  defp branch_matches?(%Content.If.Branch{}, _source), do: false

  # `Content.Assign`'s `:location` is the raw, uncompiled path-expression
  # string - not a span - and `Content.Script` has no `:location` field at
  # all; both kinds' own span lives on `:node_location` instead. Every other
  # kind's `:location` is already the span. Mirrors
  # `StatifierUI.Trace.Manifest.content_location/1` exactly, duplicated
  # rather than shared: that function is private, and this module's
  # moduledoc already commits to the same explicit-dispatch discipline for
  # its own reasons.
  @spec content_node_location(Content.t()) :: Location.t()
  defp content_node_location(%Content.Assign{node_location: node_location}), do: node_location
  defp content_node_location(%Content.Script{node_location: node_location}), do: node_location
  defp content_node_location(%{location: %Location{} = location}), do: location

  @spec put_span(map(), Predicator.Types.span() | nil) :: map()
  defp put_span(object, nil), do: object

  defp put_span(object, {{start_line, start_column}, {end_line, end_column}}) do
    Map.put(object, "span", %{
      "start_line" => start_line,
      "start_column" => start_column,
      "end_line" => end_line,
      "end_column" => end_column
    })
  end

  @spec put_location(map(), Evaluator.Error.t(), term(), Machine.t() | nil, String.t() | nil) ::
          map()
  defp put_location(object, error, origin, machine, source) do
    case anchored(origin, machine, source, error) do
      :none ->
        object

      {:node, location} ->
        put_node(object, location)

      {:value, value_location} ->
        resolved = Location.resolve_span(value_location, error.span, error.source, source)

        object
        |> Map.put("location", location_object(resolved))
        |> Map.put("location_kind", "resolved")
    end
  end

  # The `class: "reason"` arm's location: `anchored/4` is handed no error at
  # all, so it can only ever come back `:none` or `{:node, _}` - there is no
  # span to compose and nothing to compose it against.
  @spec put_node_location(map(), term(), Machine.t() | nil, String.t() | nil) :: map()
  defp put_node_location(object, origin, machine, source) do
    case anchored(origin, machine, source, nil) do
      {:node, location} -> put_node(object, location)
      _none_or_value -> object
    end
  end

  @spec put_node(map(), Location.t()) :: map()
  defp put_node(object, location) do
    object
    |> Map.put("location", location_object(location))
    |> Map.put("location_kind", "node")
  end

  @spec anchored(term(), Machine.t() | nil, String.t() | nil, Evaluator.Error.t() | nil) ::
          {:value, Location.t()} | {:node, Location.t()} | :none
  defp anchored(_origin, nil, _source, _error), do: :none
  defp anchored(_origin, _machine, nil, _error), do: :none

  defp anchored(origin, %Machine{} = machine, source, error) when is_binary(source),
    do: anchor(origin, machine, error)

  # A location is always all six fields, wholly present - mirrors
  # `StatifierUI.Trace.Manifest.location_object/1`.
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

  # `"undefined_variable"`, `"type_mismatch"`, `"evaluation"`, `"parse"`,
  # `"location"` - the underscored last segment of predicator's own error
  # struct module, with its trailing `_error` dropped
  # (`Predicator.Errors.UndefinedVariableError` -> `"undefined_variable"`).
  @spec kind(struct()) :: String.t()
  defp kind(%module{}) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace_suffix("_error", "")
  end
end
