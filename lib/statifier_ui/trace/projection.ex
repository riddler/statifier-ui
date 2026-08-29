defmodule StatifierUI.Trace.Projection do
  @moduledoc """
  ADR-0012's producer-side projection: the transform that replaces values in
  a closed set of value positions with the reserved `{"$redacted": true}`
  sentinel while leaving every identity, counter, ordering, and structural
  field untouched.

  `project/2` is applied to a `%StatifierUI.Trace.Message{}` on the
  `StatifierUI.Trace.Subscriber` path, after `StatifierUI.Trace.Normalizer`
  has built the message and before it is buffered or fanned out to any
  listener. That placement is the record's central decision and the reason
  this is not a filter in `StatifierUI.Trace.Json` or in a consumer: every
  shipped consumer reads structs and never passes through the encoder, so a
  redaction placed at the encoder would be visible only to the golden tests.

  The practical test the placement is chosen to pass: a projected stream may
  be buffered, rendered, encoded, written to disk, shipped to a log
  aggregator, or replayed months later without any of those having held a
  datamodel value.

  ## Redaction replaces; it never omits

  A redacted position carries `%{"$redacted" => true}`. It is never dropped,
  never `nil`, never `%{}`, and never `%{"$undefined" => true}`. Key absence,
  JSON `null`, and `$undefined` already mean specific things in this format,
  and every one of them is a claim about what the run did; `$redacted` is the
  format's only encoding for "a value was here and this stream is not
  carrying it," which is a claim about the stream rather than about the run.

  The corollary that governs every clause below: **a position is replaced
  only where it is already present.** Nine of the sixteen key paths this
  module touches are conditionally absent, and writing a sentinel into one
  that was absent would assert something the run never did - an eventless
  round becoming evented (`trace.transitions_selected`'s `event`), a first
  write acquiring a prior value (`effect.datamodel_change`'s `prior_value`),
  or a host that supplied no fixtures acquiring a bundle (`session.start`'s
  `fixtures`). `replace_present/3` is the only way a value is written here.

  ## The two allowlist shapes

  Within projected mode the default is deny. A profile may allow specific
  values back, and the allowlist has two parts because the format's value
  positions divide cleanly in two.

  **Located positions** - the datamodel - are allowlisted by path prefix,
  written as arrays of segments in the same encoding
  `effect.datamodel_change`'s `location_path` already uses. The same prefixes
  apply to `session.datamodel`, whose keys are the first segment of every
  path.

  **Unlocated positions** - payloads, which have no path - are allowlisted by
  naming the position, from the closed set `positions/0` returns. Naming a
  position allows it wholesale, at every message that carries it. There is
  deliberately no per-key allowlist inside a payload: an event payload has no
  stable schema the way a datamodel location does.

  ## Prefix matching, and the shallower-write rule

  Three cases, and the third is the operator ruling of 2026-08-29 recorded on
  ADR-0012 (the accepted text settled only the first two):

  - An allowed prefix **matches the write's leading segments** (the prefix is
    no longer than the write's path): the whole value is allowed through.
  - No allowed prefix relates to the path at all: the whole value is
    redacted.
  - An allowed prefix is **longer than the write's path and extends it** -
    the write is shallower than the prefix, so the written value contains
    both the allowed leaf and its withheld siblings. The projection
    **descends into the value** and redacts selectively, so the allowed leaf
    passes and every sibling is redacted. Allowing the whole write would leak
    a sibling the profile withheld; denying it would withhold a leaf the
    profile allowed.

  Descent applies identically to `session.datamodel`'s snapshot values. Where
  a value cannot be descended into because it is a scalar rather than a map
  or a list, the allowed leaf is unreachable and the value is redacted whole
  - the safe direction.

  ## What is never projected

  Every identity, counter, and structural field: `type`, `session`, `seq`,
  `macrostep`, `microstep`, `round`, state indexes, `t_index`, `c_index`,
  `d_index`, `invokeid`, `send_id`, `state_index`, `invoke_index`, every
  `session.start` table and every `location` object in them, configurations,
  exit and entry sequences, `kind` and `type` discriminators, owner and
  origin objects, event `name`s, `label` on `effect.log`, `src` and
  `invoke_type` on `effect.invoke`, `target` and `send_type` on the send
  family, `location_path` and `location_source` on `effect.datamodel_change`,
  `session.halted`'s `reason` (a closed three-value set), and `effect.done`'s
  `configuration`.

  `location_path`'s integer segments are resolved index expressions, so a
  projected stream still reveals which array index a write landed on. ADR-0012
  records that as an accepted residual: a consumer that cannot see the path
  cannot fold the write at all.

  ## Not anonymization, not access control

  Structure leaks. Which branch a run took, how many rounds a macrostep
  needed, which transition fired on which event - these imply things about
  the values that produced them. The guarantee is narrow and worth stating in
  those terms: **no datamodel value crosses the producer boundary.** Choosing
  the profile correctly per tenant is the host's job, and this format cannot
  check it.
  """

  alias StatifierUI.Trace.Message

  @redacted %{"$redacted" => true}

  @positions [
    :event_data,
    :log_value,
    :send_data,
    :invoke_params,
    :invoke_content,
    :donedata
  ]

  defmodule Profile do
    @moduledoc """
    A named projection profile: the two allowlists plus `allow_source`.

    Built through `StatifierUI.Trace.Projection.profile/2`, which validates
    the shapes rather than letting a malformed allowlist silently allow or
    deny more than the host meant. Profiles are a producer input; where a
    host stores them and how it picks one per tenant is host business.
    """

    @typedoc "One segment of a datamodel location path: an object key or an array index."
    @type segment :: String.t() | integer()

    @typedoc "An unlocated value position, from the closed set `StatifierUI.Trace.Projection.positions/0` returns."
    @type position ::
            :event_data | :log_value | :send_data | :invoke_params | :invoke_content | :donedata

    @type t :: %__MODULE__{
            name: String.t(),
            allow_paths: [[segment()]],
            allow_positions: MapSet.t(position()),
            allow_source: boolean()
          }

    @enforce_keys [:name]
    defstruct name: nil, allow_paths: [], allow_positions: MapSet.new(), allow_source: true
  end

  @doc """
  The reserved sentinel object a redacted position carries.

  ## Examples

      iex> StatifierUI.Trace.Projection.redacted()
      %{"$redacted" => true}

  """
  @spec redacted() :: %{String.t() => boolean()}
  def redacted, do: @redacted

  @doc """
  The closed set of unlocated value positions a profile may name in
  `allow_positions`.

  ## Examples

      iex> :log_value in StatifierUI.Trace.Projection.positions()
      true

  """
  @spec positions() :: [Profile.position()]
  def positions, do: @positions

  @typedoc false
  @type projected_type :: String.t()

  @projected_types [
    "session.datamodel",
    "effect.datamodel_change",
    "trace.event_dequeued",
    "trace.transitions_selected",
    "trace.finalize_autoforward",
    "trace.done",
    "effect.done",
    "effect.autoforward",
    "effect.budget_exhausted",
    "effect.log",
    "effect.invoke",
    "effect.send",
    "effect.send_delayed",
    "session.unroutable",
    "session.start",
    "session.terminated"
  ]

  @doc """
  The closed, sorted list of every message `type` this module has a
  projection rule for - the code side of ADR-0012's position table.

  This exists to be compared against the table in `docs/wire-format.md`'s
  Projection section, which
  `test/statifier_ui/trace/projection_drift_test.exs` does in both
  directions. The standing drift risk ADR-0012 names is a value position
  added to the format later with no projection rule, which would carry
  values through a projected stream silently; the spec table is the
  checklist, and that test is what makes the checklist bite.

  ## Examples

      iex> "effect.log" in StatifierUI.Trace.Projection.projected_types()
      true

  """
  @spec projected_types() :: [projected_type()]
  def projected_types, do: Enum.sort(@projected_types)

  @doc """
  Builds a validated `Profile`.

  `opts`:

    - `:allow_paths` - a list of path prefixes, each a list of string or
      integer segments. Default `[]` (deny every datamodel value).
    - `:allow_positions` - a list of atoms drawn from `positions/0`. Default
      `[]` (deny every payload value).
    - `:allow_source` - whether `session.start`'s `source` is retained.
      Default `true`, which is ADR-0012's default: `source` is authored
      rather than run data and the whole inspector resolves indexes against
      it. Set it `false` when chart source may itself carry a secret, at the
      documented cost that location objects still resolve to line and column
      but nothing can display the text at them.

  Returns `{:error, {:invalid_allow_paths, term}}` or
  `{:error, {:invalid_allow_positions, term}}` rather than accepting an
  allowlist it cannot interpret - a redaction rule that silently stops
  matching is the failure ADR-0012 exists to avoid.

  ## Examples

      iex> {:ok, profile} = StatifierUI.Trace.Projection.profile("end_user_run_history")
      iex> profile.allow_source
      true

      iex> StatifierUI.Trace.Projection.profile("bad", allow_positions: [:nope])
      {:error, {:invalid_allow_positions, [:nope]}}

  """
  @spec profile(String.t(), keyword()) :: {:ok, Profile.t()} | {:error, term()}
  def profile(name, opts \\ []) when is_binary(name) do
    allow_paths = Keyword.get(opts, :allow_paths, [])
    allow_positions = Keyword.get(opts, :allow_positions, [])
    allow_source = Keyword.get(opts, :allow_source, true)

    with :ok <- validate_allow_paths(allow_paths),
         :ok <- validate_allow_positions(allow_positions),
         :ok <- validate_allow_source(allow_source) do
      {:ok,
       %Profile{
         name: name,
         allow_paths: allow_paths,
         allow_positions: MapSet.new(allow_positions),
         allow_source: allow_source
       }}
    end
  end

  @doc """
  `profile/2`, raising on an invalid allowlist.
  """
  @spec profile!(String.t(), keyword()) :: Profile.t()
  def profile!(name, opts \\ []) do
    case profile(name, opts) do
      {:ok, profile} -> profile
      {:error, reason} -> raise ArgumentError, "invalid projection profile: #{inspect(reason)}"
    end
  end

  @doc """
  Projects `message` under `profile`.

  Every value position ADR-0012's table names is replaced with the sentinel
  unless the profile allows it; every other field is returned untouched. A
  `session.start` message additionally gains the `projection` header naming
  the mode and the profile, which is what makes a projected stream
  distinguishable from a full one even when a single message is pulled out of
  a log.

  ## Examples

      iex> profile = StatifierUI.Trace.Projection.profile!("p")
      iex> message = %StatifierUI.Trace.Message{
      ...>   type: "effect.log", session: "s", seq: 1, payload: %{"value" => 42}
      ...> }
      iex> StatifierUI.Trace.Projection.project(message, profile).payload
      %{"value" => %{"$redacted" => true}}

  """
  @spec project(Message.t(), Profile.t()) :: Message.t()
  def project(%Message{} = message, %Profile{} = profile) do
    %{message | payload: project_payload(message.type, message.payload, profile)}
  end

  # -- Per-type payload rules ------------------------------------------------

  # The dispatch mirrors ADR-0012's closed position table row for row. A type
  # with no value position falls through to the catch-all and is returned
  # untouched; that is deliberate rather than an omission, and the drift test
  # in test/statifier_ui/trace/projection_drift_test.exs is what keeps a type
  # gaining a value position from silently landing here.
  @spec project_payload(String.t(), map(), Profile.t()) :: map()
  defp project_payload("session.datamodel", payload, profile) do
    replace_present(payload, "datamodel", fn datamodel ->
      project_datamodel_snapshot(datamodel, profile)
    end)
  end

  defp project_payload("effect.datamodel_change", payload, profile) do
    path = Map.get(payload, "location_path", [])

    payload
    |> replace_present("new_value", &project_located(&1, path, profile))
    |> replace_present("prior_value", &project_located(&1, path, profile))
  end

  defp project_payload(type, payload, profile)
       when type in ["trace.event_dequeued", "trace.finalize_autoforward", "effect.autoforward"] do
    replace_present(payload, "event", &project_event(&1, profile))
  end

  defp project_payload("trace.transitions_selected", payload, profile) do
    # `event` is itself conditionally absent here, and its absence is the
    # eventless-round signal (wire-format.md, "Absence"). replace_present/3
    # is what keeps this from inventing one.
    replace_present(payload, "event", &project_event(&1, profile))
  end

  defp project_payload(type, payload, profile) when type in ["trace.done", "effect.done"] do
    replace_present(payload, "donedata", &project_position(&1, :donedata, profile))
  end

  defp project_payload("effect.budget_exhausted", payload, profile) do
    replace_present(payload, "pending_internal_events", fn events ->
      Enum.map(events, &project_event(&1, profile))
    end)
  end

  defp project_payload("effect.log", payload, profile) do
    replace_present(payload, "value", &project_position(&1, :log_value, profile))
  end

  defp project_payload("effect.invoke", payload, profile) do
    payload
    |> replace_present("params", &project_position(&1, :invoke_params, profile))
    |> replace_present("content", &project_position(&1, :invoke_content, profile))
  end

  defp project_payload(type, payload, profile)
       when type in ["effect.send", "effect.send_delayed"] do
    replace_present(payload, "data", &project_position(&1, :send_data, profile))
  end

  defp project_payload("session.unroutable", payload, profile) do
    # The wrapper carries the inner type under "kind" rather than on the
    # envelope, so this recurses on that instead of pattern-matching the outer
    # type. A projection keyed on the outer type alone would redact nothing
    # here, and the inner kind can in principle be session.datamodel.
    replace_present(payload, "effect", fn effect ->
      case Map.fetch(effect, "kind") do
        {:ok, kind} -> project_payload(kind, effect, profile)
        :error -> effect
      end
    end)
  end

  defp project_payload("session.start", payload, profile) do
    payload
    # `fixtures` is a datamodel bundle by construction (ADR-0003), so it is
    # replaced whole rather than descended into. A host that supplied none
    # still omits the key, as today, and the two states stay distinguishable.
    |> replace_present("fixtures", fn _fixtures -> @redacted end)
    |> project_source(profile)
    |> Map.put("projection", %{"mode" => "projected", "profile" => profile.name})
  end

  defp project_payload("session.terminated", payload, _profile) do
    # The one position where projection changes a field's JSON type, from
    # string to the sentinel object. It earns the exception: it is inspect/1
    # of an exit reason, so a crash inside a datamodel operation can carry
    # datamodel terms into it verbatim, and the spec already tells consumers
    # it is human-readable rather than structured data to branch on.
    replace_present(payload, "reason", fn _reason -> @redacted end)
  end

  defp project_payload(_type, payload, _profile), do: payload

  # -- Position helpers ------------------------------------------------------

  @spec project_event(map(), Profile.t()) :: map()
  defp project_event(event, profile) when is_map(event) do
    replace_present(event, "data", &project_position(&1, :event_data, profile))
  end

  defp project_event(event, _profile), do: event

  @spec project_position(term(), Profile.position(), Profile.t()) :: term()
  defp project_position(value, position, %Profile{allow_positions: allowed}) do
    if MapSet.member?(allowed, position), do: value, else: @redacted
  end

  @spec project_source(map(), Profile.t()) :: map()
  defp project_source(payload, %Profile{allow_source: true}), do: payload

  defp project_source(payload, %Profile{allow_source: false}) do
    replace_present(payload, "source", fn _source -> @redacted end)
  end

  @spec project_datamodel_snapshot(term(), Profile.t()) :: term()
  defp project_datamodel_snapshot(datamodel, profile) when is_map(datamodel) do
    Map.new(datamodel, fn {name, value} -> {name, project_located(value, [name], profile)} end)
  end

  defp project_datamodel_snapshot(datamodel, _profile), do: datamodel

  # -- Located (datamodel) projection ----------------------------------------

  # The three-case rule documented in the moduledoc. Order matters: a prefix
  # that already matches wins over one that would descend, so a profile
  # allowing both ["account"] and ["account", "currency"] allows the whole
  # subtree rather than descending into it.
  @spec project_located(term(), [Profile.segment()], Profile.t()) :: term()
  defp project_located(value, path, %Profile{allow_paths: allow_paths} = profile) do
    cond do
      allowed_whole?(allow_paths, path) -> value
      extends?(allow_paths, path) -> descend(value, path, profile)
      true -> @redacted
    end
  end

  @spec allowed_whole?([[Profile.segment()]], [Profile.segment()]) :: boolean()
  defp allowed_whole?(allow_paths, path) do
    Enum.any?(allow_paths, fn allowed ->
      length(allowed) <= length(path) and List.starts_with?(path, allowed)
    end)
  end

  @spec extends?([[Profile.segment()]], [Profile.segment()]) :: boolean()
  defp extends?(allow_paths, path) do
    Enum.any?(allow_paths, fn allowed ->
      length(allowed) > length(path) and List.starts_with?(allowed, path)
    end)
  end

  # A scalar cannot carry the allowed leaf, so it redacts whole rather than
  # passing through - the safe direction when the profile and the value shape
  # disagree.
  @spec descend(term(), [Profile.segment()], Profile.t()) :: term()
  defp descend(value, path, profile) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, inner} -> {key, project_located(inner, path ++ [key], profile)} end)
  end

  defp descend(value, path, profile) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map(fn {inner, index} -> project_located(inner, path ++ [index], profile) end)
  end

  defp descend(_value, _path, _profile), do: @redacted

  # -- Replace, never create -------------------------------------------------

  @spec replace_present(map(), String.t(), (term() -> term())) :: map()
  defp replace_present(payload, key, fun) do
    case Map.fetch(payload, key) do
      {:ok, value} -> Map.put(payload, key, fun.(value))
      :error -> payload
    end
  end

  # -- Validation ------------------------------------------------------------

  @spec validate_allow_paths(term()) :: :ok | {:error, term()}
  defp validate_allow_paths(paths) when is_list(paths) do
    if Enum.all?(paths, &valid_path?/1) do
      :ok
    else
      {:error, {:invalid_allow_paths, paths}}
    end
  end

  defp validate_allow_paths(other), do: {:error, {:invalid_allow_paths, other}}

  @spec valid_path?(term()) :: boolean()
  defp valid_path?(path) when is_list(path) and path != [] do
    Enum.all?(path, &(is_binary(&1) or is_integer(&1)))
  end

  defp valid_path?(_other), do: false

  @spec validate_allow_positions(term()) :: :ok | {:error, term()}
  defp validate_allow_positions(positions) when is_list(positions) do
    if Enum.all?(positions, &(&1 in @positions)) do
      :ok
    else
      {:error, {:invalid_allow_positions, positions}}
    end
  end

  defp validate_allow_positions(other), do: {:error, {:invalid_allow_positions, other}}

  @spec validate_allow_source(term()) :: :ok | {:error, term()}
  defp validate_allow_source(value) when is_boolean(value), do: :ok
  defp validate_allow_source(other), do: {:error, {:invalid_allow_source, other}}
end
