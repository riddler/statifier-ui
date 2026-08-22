defmodule StatifierUI.EventLog.Labels do
  @moduledoc """
  Turns the wire format's integer indexes into strings a human can read,
  using only the `session.start` tables already on the stream
  (`lib/statifier_ui/trace/manifest.ex:120-211`).

  A `t()` is a flat lookup built once, from `from_manifest/1` or
  `from_log/1`, and then consulted many times as an `EventLog` renders.
  Every resolver takes the `t()` first so a renderer can partially apply
  it (`&Labels.state(labels, &1)`) across a list of indexes.

  ## The late-attach degradation

  `empty/0` is not a stub - it is the late-attach case
  (`StatifierUI.Trace.Subscriber` emits no `session.start` when it joins a
  running session that already has one). With no manifest tables at all,
  every resolver falls back to its bare `"#<index>"` form, which is why
  every resolver's "not found" branch and `empty/0`'s "always not found"
  case are the same code path rather than two.

  ## Origins and owners

  `origin/2` and `owner/2` dispatch on the `"kind"` field of an origin or
  owner object (`docs/wire-format.md:625-660`) and delegate to the four
  index resolvers above. Both are total over the documented shapes: an
  unrecognized `"kind"` renders the kind string itself rather than
  raising, matching the format's additive-field rule - a client should
  degrade gracefully in front of a newer producer, not crash.
  """

  alias StatifierUI.EventLog
  alias StatifierUI.Trace.Message

  @type t :: %__MODULE__{
          states: %{optional(non_neg_integer()) => map()},
          transitions: %{optional(non_neg_integer()) => map()},
          contents: %{optional(non_neg_integer()) => map()},
          data: %{optional(non_neg_integer()) => map()}
        }

  defstruct states: %{}, transitions: %{}, contents: %{}, data: %{}

  @doc "The late-attach case: no tables at all, so every index resolves to its bare `\"#<index>\"` form."
  @spec empty() :: t()
  def empty, do: %__MODULE__{}

  @doc """
  Builds a `t()` from a `session.start` message's payload, keying each
  table by its own index field (`"index"`, `"t_index"`, `"c_index"`,
  `"d_index"`).
  """
  @spec from_manifest(Message.t()) :: t()
  def from_manifest(%Message{type: "session.start", payload: payload}) do
    %__MODULE__{
      states: index_by(payload["states"], "index"),
      transitions: index_by(payload["transitions"], "t_index"),
      contents: index_by(payload["contents"], "c_index"),
      data: index_by(payload["data"], "d_index")
    }
  end

  @doc """
  Finds the first `session.start` in `log`'s `session_messages` and
  delegates to `from_manifest/1`. Returns `empty/0` when the log carries
  none - the late-attach case.
  """
  @spec from_log(EventLog.t()) :: t()
  def from_log(%EventLog{session_messages: session_messages}) do
    case Enum.find(session_messages, &(&1.type == "session.start")) do
      nil -> empty()
      message -> from_manifest(message)
    end
  end

  @doc """
  Resolves a state `index` to its `"id"` when present, `"<scxml>"` for
  the synthesized root, or a bare `"#<index>"` for an anonymous state or
  an index this `t()` does not know about.
  """
  @spec state(t(), non_neg_integer()) :: String.t()
  def state(%__MODULE__{states: states}, index) do
    case Map.get(states, index) do
      %{"id" => id} -> id
      %{"kind" => "scxml"} -> "<scxml>"
      _ -> bare_index(index)
    end
  end

  @doc "Resolves each of `indexes` through `state/2`, in list order, joined with `\", \"`."
  @spec states(t(), [non_neg_integer()]) :: String.t()
  def states(%__MODULE__{} = labels, indexes) do
    Enum.map_join(indexes, ", ", &state(labels, &1))
  end

  @doc """
  Resolves a transition `index` to `"<events>: <source> -> <targets>"`.

  `events` is an array of arrays of strings - one dot-split token list
  per whitespace-separated event descriptor - so inner lists join with
  `"."` and the outer list joins with `" "`; an empty `events` list
  renders `"(eventless)"`. Targets join with `", "`; an empty target
  list renders `"(targetless)"`. An unknown index renders `"#<index>"`.
  """
  @spec transition(t(), non_neg_integer()) :: String.t()
  def transition(%__MODULE__{transitions: transitions} = labels, index) do
    case Map.get(transitions, index) do
      nil -> bare_index(index)
      entry -> render_transition(labels, entry)
    end
  end

  @doc """
  Resolves a content `index` to `"<kind>@<start_line>:<start_column>"`.
  An unknown index renders `"#<index>"`.
  """
  @spec content(t(), non_neg_integer()) :: String.t()
  def content(%__MODULE__{contents: contents}, index) do
    case Map.get(contents, index) do
      nil -> bare_index(index)
      entry -> render_content(entry)
    end
  end

  @doc ~S'Resolves a `<data>` `index` to its `"id"`, otherwise `"#<index>"`.'
  @spec data(t(), non_neg_integer()) :: String.t()
  def data(%__MODULE__{data: data}, index) do
    case Map.get(data, index) do
      %{"id" => id} -> id
      _ -> bare_index(index)
    end
  end

  @doc """
  Resolves an origin object (`docs/wire-format.md:625-645`) by dispatching
  on its `"kind"`. An unrecognized `"kind"` renders the kind string
  itself.
  """
  @spec origin(t(), map()) :: String.t()
  def origin(%__MODULE__{} = labels, %{"kind" => "content"} = origin) do
    "#{owner(labels, origin["owner"])}: #{content(labels, origin["c_index"])}"
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "state"} = origin) do
    state(labels, origin["state_index"])
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "transition"} = origin) do
    transition(labels, origin["t_index"])
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "data"} = origin) do
    data(labels, origin["d_index"])
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "donedata_param"} = origin) do
    "#{state(labels, origin["state_index"])} donedata param #{origin["param_index"]}"
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "global_script"} = origin) do
    content(labels, origin["index"])
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "invoke"} = origin) do
    "#{state(labels, origin["state_index"])} invoke##{origin["invoke_index"]}"
  end

  def origin(%__MODULE__{} = labels, %{"kind" => "finalize"} = origin) do
    "#{state(labels, origin["state_index"])} invoke##{origin["invoke_index"]} finalize"
  end

  def origin(%__MODULE__{}, %{"kind" => kind}), do: kind

  @doc """
  Resolves an owner object (`docs/wire-format.md:646-660`) by dispatching
  on its `"kind"`. An unrecognized `"kind"` renders the kind string
  itself.
  """
  @spec owner(t(), map()) :: String.t()
  def owner(%__MODULE__{} = labels, %{"kind" => "onentry"} = owner) do
    "#{state(labels, owner["state_index"])} onentry##{owner["ordinal"]}"
  end

  def owner(%__MODULE__{} = labels, %{"kind" => "onexit"} = owner) do
    "#{state(labels, owner["state_index"])} onexit##{owner["ordinal"]}"
  end

  def owner(%__MODULE__{} = labels, %{"kind" => "transition"} = owner) do
    transition(labels, owner["t_index"])
  end

  def owner(%__MODULE__{} = labels, %{"kind" => "finalize"} = owner) do
    "#{state(labels, owner["state_index"])} invoke##{owner["invoke_index"]} finalize"
  end

  def owner(%__MODULE__{} = labels, %{"kind" => "global_script"} = owner) do
    content(labels, owner["index"])
  end

  def owner(%__MODULE__{}, %{"kind" => kind}), do: kind

  # -- table building -----------------------------------------------------

  @spec index_by([map()], String.t()) :: %{optional(non_neg_integer()) => map()}
  defp index_by(entries, key) do
    Map.new(entries, &{&1[key], &1})
  end

  # -- rendering helpers ----------------------------------------------------

  @spec bare_index(non_neg_integer()) :: String.t()
  defp bare_index(index), do: "##{index}"

  @spec render_transition(t(), map()) :: String.t()
  defp render_transition(labels, entry) do
    events = render_events(entry["events"])
    source = state(labels, entry["source"])
    targets = render_targets(labels, entry["targets"])
    "#{events}: #{source} -> #{targets}"
  end

  @spec render_events([[String.t()]]) :: String.t()
  defp render_events([]), do: "(eventless)"

  defp render_events(events) do
    Enum.map_join(events, " ", &Enum.join(&1, "."))
  end

  @spec render_targets(t(), [non_neg_integer()]) :: String.t()
  defp render_targets(_labels, []), do: "(targetless)"

  defp render_targets(labels, targets) do
    Enum.map_join(targets, ", ", &state(labels, &1))
  end

  @spec render_content(map()) :: String.t()
  defp render_content(%{"kind" => kind, "location" => location}) do
    "#{kind}@#{location["start_line"]}:#{location["start_column"]}"
  end
end
