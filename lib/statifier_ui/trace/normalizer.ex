defmodule StatifierUI.Trace.Normalizer do
  @moduledoc """
  The pure mapping from `Statifier.Effect.t()` (and the session's own
  lifecycle messages) to `StatifierUI.Trace.Message.t()`, matching
  `docs/wire-format.md` field for field. No process, no session, no
  `%Statifier.Machine{}` - the whole vocabulary is testable from a struct
  literal.

  ## Value handling

  Anything from the engine that occupies a *value* position -
  `Event.data`, `Log.value`, `Trace.Done.donedata`, `Effect.Done.donedata`,
  `Send.data`, `SendDelayed.data`, `Invoke.params`, `Invoke.content` - goes
  through `StatifierUI.Value.encode/1`; its `{:error, _}` is propagated,
  never rescued. Everything structural is reduced first (decision 6):
  `MapSet`s to sorted lists (`configuration/1`), atoms to `"kind"`-tagged
  objects (`origin/1`, `owner/1`). This ordering matters -
  `StatifierUI.Value.encode/1` passes an unknown term through unchanged, so
  handing it a raw tuple would produce silent garbage rather than an error.

  ## Absence

  `_event.data` keeps ADR-0005's three-way rule unchanged: `:undefined`
  omits the key, `nil` is present as JSON `null`, `%{}` is present as `{}`
  (`put_event_data/2`). Every other nullable field in this vocabulary has no
  engine-side way to distinguish "no value" from "a genuinely null value" -
  `Statifier.Effect.Log.value` and the two `donedata` fields default to
  plain `nil` for "nothing here", never `:undefined` - so `put_present/3`
  and `put_value/3` generalize the rule (decision 5) by treating `nil` and
  `:undefined` alike as absence for those fields, applied uniformly instead
  of remembered clause by clause.
  """

  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias StatifierUI.Trace.Message
  alias StatifierUI.Value

  @typedoc "What `normalize/2` needs beyond the effect itself: the emitting session and the `seq` to stamp."
  @type ctx :: %{session: String.t(), seq: non_neg_integer()}

  @typedoc """
  Everything `normalize/2` accepts: a bare effect, the `{:effect, _}`
  wrapper the session sends its subscribers, and the two lifecycle
  messages. The outer `{:statifier, session_id, _}` envelope is never
  accepted here - unwrapping it is the subscriber's job, and keeping it out
  is what makes this module testable from a struct literal.
  """
  @type input ::
          Statifier.Effect.t()
          | {:effect, Statifier.Effect.t()}
          | {:halted, :done | :cancelled | :budget_exhausted}
          | {:unroutable, Statifier.Effect.t()}

  @types [
    "trace.event_dequeued",
    "trace.transitions_selected",
    "trace.exit_set",
    "trace.content_executed",
    "trace.entry_set",
    "trace.macrostep_stable",
    "trace.done",
    "trace.invoke_pass",
    "trace.finalize_autoforward",
    "effect.log",
    "effect.done",
    "effect.budget_exhausted",
    "effect.invoke",
    "effect.cancel_invoke",
    "effect.autoforward",
    "effect.send",
    "effect.send_delayed",
    "effect.cancel",
    "session.start",
    "session.halted",
    "session.terminated",
    "session.unroutable",
    "session.datamodel"
  ]

  @doc """
  The closed, sorted list of every `type` string this format defines - the
  vocabulary's single definition site in code. 23 entries: 9 `trace.*`, 9
  `effect.*`, and 5 `session.*` (the four lifecycle types plus the reserved,
  not-yet-emitted `session.datamodel`). `docs/wire-format.md`'s type index
  table is the same 23, and `test/statifier_ui/trace/wire_format_spec_test.exs`
  asserts the two sets are equal.
  """
  @spec types() :: [String.t()]
  def types, do: Enum.sort(@types)

  @doc """
  Normalizes one `input()` into a `%Message{}` stamped with `ctx`'s
  `session` and `seq`.

  Returns `{:error, {:unknown_effect, tag}}` for a tag this module does not
  know, rather than skipping it - a new engine effect appearing silently is
  exactly what ADR-0005's Consequences warn a drift test must catch. It is
  the caller's job to decide what to do with the error.
  """
  @spec normalize(input(), ctx()) :: {:ok, Message.t()} | {:error, term()}
  def normalize({:effect, effect}, ctx), do: normalize(effect, ctx)

  def normalize({:halted, reason}, ctx) when reason in [:done, :cancelled, :budget_exhausted] do
    build(ctx, "session.halted", nil, nil, nil, %{"reason" => Atom.to_string(reason)})
  end

  def normalize({:unroutable, effect}, ctx) do
    with {:ok, {type, macrostep, microstep, round, payload}} <- decompose(effect) do
      wrapped =
        payload
        |> Map.put("kind", type)
        |> put_present("macrostep", macrostep)
        |> put_present("microstep", microstep)
        |> put_present("round", round)

      build(ctx, "session.unroutable", nil, nil, nil, %{"effect" => wrapped})
    end
  end

  def normalize(effect, ctx) do
    with {:ok, {type, macrostep, microstep, round, payload}} <- decompose(effect) do
      build(ctx, type, macrostep, microstep, round, payload)
    end
  end

  @spec build(
          ctx(),
          String.t(),
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          non_neg_integer() | nil,
          map()
        ) :: {:ok, Message.t()} | {:error, term()}
  defp build(ctx, type, macrostep, microstep, round, payload) do
    %Message{
      type: type,
      session: ctx.session,
      seq: ctx.seq,
      macrostep: macrostep,
      microstep: microstep,
      round: round,
      payload: payload
    }
    |> Message.validate()
  end

  # -- Dispatch -------------------------------------------------------------

  @typep decomposed ::
           {String.t(), non_neg_integer() | nil, non_neg_integer() | nil, non_neg_integer() | nil,
            map()}

  @spec decompose(Statifier.Effect.t()) :: {:ok, decomposed()} | {:error, term()}
  defp decompose({:trace, payload}), do: trace_message(payload)
  defp decompose({:log, payload}), do: core_message(payload)
  defp decompose({:done, payload}), do: core_message(payload)
  defp decompose({:budget_exhausted, payload}), do: core_message(payload)
  defp decompose({:invoke, payload}), do: core_message(payload)
  defp decompose({:cancel_invoke, payload}), do: core_message(payload)
  defp decompose({:autoforward, payload}), do: core_message(payload)
  defp decompose({:send, payload}), do: core_message(payload)
  defp decompose({:send_delayed, payload}), do: core_message(payload)
  defp decompose({:cancel, payload}), do: core_message(payload)
  defp decompose({tag, _payload}), do: {:error, {:unknown_effect, tag}}
  defp decompose(other), do: {:error, {:unknown_effect, other}}

  # -- The nine trace.* payloads ---------------------------------------------

  @spec trace_message(struct()) :: {:ok, decomposed()} | {:error, term()}
  defp trace_message(%Trace.EventDequeued{} = p) do
    with {:ok, event_obj} <- event(p.event) do
      payload = %{"event" => event_obj, "from" => Atom.to_string(p.from)}
      {:ok, {"trace.event_dequeued", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.TransitionsSelected{} = p) do
    base = %{"t_indexes" => indexes(p.t_indexes)}

    with {:ok, payload} <- put_event(base, p.event) do
      {:ok, {"trace.transitions_selected", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.ExitSet{} = p) do
    payload = %{"indexes" => indexes(p.indexes)}
    {:ok, {"trace.exit_set", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.ContentExecuted{} = p) do
    with {:ok, owner_obj} <- owner(p.owner) do
      payload = %{"owner" => owner_obj, "c_indexes" => indexes(p.c_indexes)}
      {:ok, {"trace.content_executed", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.EntrySet{} = p) do
    payload = %{"indexes" => indexes(p.indexes)}
    {:ok, {"trace.entry_set", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.MacrostepStable{} = p) do
    payload = %{"configuration" => configuration(p.configuration)}
    {:ok, {"trace.macrostep_stable", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.Done{} = p) do
    base = %{"configuration" => configuration(p.configuration)}

    with {:ok, payload} <- put_value(base, "donedata", p.donedata) do
      {:ok, {"trace.done", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.InvokePass{} = p) do
    payload = %{"state_indexes" => indexes(p.state_indexes), "invoke_ids" => p.invoke_ids}
    {:ok, {"trace.invoke_pass", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.FinalizeAutoforward{} = p) do
    with {:ok, event_obj} <- event(p.event) do
      payload = %{"event" => event_obj, "finalized" => p.finalized, "forwarded" => p.forwarded}
      {:ok, {"trace.finalize_autoforward", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(payload), do: {:error, {:unknown_effect, {:trace, payload.__struct__}}}

  # -- The nine effect.* payloads --------------------------------------------

  @spec core_message(struct()) :: {:ok, decomposed()} | {:error, term()}
  defp core_message(%Log{} = p) do
    base = put_present(%{}, "label", p.label)

    with {:ok, base} <- put_owner(base, p.owner),
         {:ok, base} <- put_value(base, "value", p.value) do
      base = put_present(base, "c_index", p.c_index)
      {:ok, {"effect.log", p.macrostep, p.microstep, nil, base}}
    end
  end

  defp core_message(%Done{} = p) do
    base = %{"configuration" => configuration(p.configuration)}

    with {:ok, payload} <- put_value(base, "donedata", p.donedata) do
      {:ok, {"effect.done", p.macrostep, p.microstep, nil, payload}}
    end
  end

  defp core_message(%BudgetExhausted{} = p) do
    with {:ok, pending} <- event_list(p.pending_internal_events) do
      payload = %{
        "configuration" => configuration(p.configuration),
        "budget" => budget(p.budget),
        "pending_internal_events" => pending
      }

      {:ok, {"effect.budget_exhausted", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp core_message(%Invoke{} = p) do
    base =
      %{
        "invoke_id" => p.invoke_id,
        "state_index" => p.state_index,
        "invoke_index" => p.invoke_index
      }
      |> put_present("invoke_type", p.type)
      |> put_present("src", p.src)
      |> put_present("autoforward", p.autoforward)

    with {:ok, base} <- put_value(base, "params", p.params),
         {:ok, base} <- put_value(base, "content", p.content) do
      {:ok, {"effect.invoke", p.macrostep, p.microstep, nil, base}}
    end
  end

  defp core_message(%CancelInvoke{} = p) do
    payload = %{"invoke_id" => p.invoke_id, "state_index" => p.state_index}
    {:ok, {"effect.cancel_invoke", p.macrostep, p.microstep, nil, payload}}
  end

  defp core_message(%Autoforward{} = p) do
    with {:ok, event_obj} <- event(p.event) do
      payload = %{
        "invoke_id" => p.invoke_id,
        "state_index" => p.state_index,
        "event" => event_obj
      }

      {:ok, {"effect.autoforward", p.macrostep, p.microstep, nil, payload}}
    end
  end

  defp core_message(%Send{} = p) do
    base =
      %{"event" => p.event, "send_id" => p.send_id, "id_from_author" => p.id_from_author?}
      |> put_present("target", p.target)
      |> put_present("send_type", p.type)

    with {:ok, base} <- put_owner(base, p.owner),
         {:ok, base} <- put_value(base, "data", p.data) do
      base = put_present(base, "c_index", p.c_index)
      {:ok, {"effect.send", p.macrostep, p.microstep, nil, base}}
    end
  end

  defp core_message(%SendDelayed{} = p) do
    base =
      %{
        "event" => p.event,
        "send_id" => p.send_id,
        "id_from_author" => p.id_from_author?,
        "delay_ms" => p.delay_ms
      }
      |> put_present("target", p.target)
      |> put_present("send_type", p.type)

    with {:ok, base} <- put_owner(base, p.owner),
         {:ok, base} <- put_value(base, "data", p.data) do
      base = put_present(base, "c_index", p.c_index)
      {:ok, {"effect.send_delayed", p.macrostep, p.microstep, nil, base}}
    end
  end

  defp core_message(%Cancel{} = p) do
    base = put_present(%{"send_id" => p.send_id}, "c_index", p.c_index)

    with {:ok, base} <- put_owner(base, p.owner) do
      {:ok, {"effect.cancel", p.macrostep, p.microstep, nil, base}}
    end
  end

  @spec budget(pos_integer() | :infinity) :: pos_integer() | String.t()
  defp budget(:infinity), do: "infinity"
  defp budget(n) when is_integer(n), do: n

  @spec event_list([Event.t()]) :: {:ok, [map()]} | {:error, term()}
  defp event_list(events) do
    events
    |> Enum.reduce_while({:ok, []}, fn ev, {:ok, acc} ->
      case event(ev) do
        {:ok, obj} -> {:cont, {:ok, [obj | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _reason} = error -> error
    end
  end

  # -- Shared object builders -------------------------------------------------

  @spec event(Event.t()) :: {:ok, map()} | {:error, term()}
  defp event(%Event{} = ev) do
    base = %{"name" => ev.name, "type" => Atom.to_string(ev.type)}

    with {:ok, base} <- put_event_data(base, ev.data),
         {:ok, base} <- put_cause(base, ev.cause) do
      base =
        base
        |> put_present("invokeid", ev.invokeid)
        |> put_present("origin", ev.origin)
        |> put_present("origintype", ev.origintype)
        |> put_present("sendid", ev.sendid)

      {:ok, base}
    end
  end

  @spec put_event(map(), Event.t() | nil) :: {:ok, map()} | {:error, term()}
  defp put_event(map, nil), do: {:ok, map}

  defp put_event(map, %Event{} = ev) do
    with {:ok, event_obj} <- event(ev) do
      {:ok, Map.put(map, "event", event_obj)}
    end
  end

  @spec put_cause(map(), Cause.t() | nil) :: {:ok, map()} | {:error, term()}
  defp put_cause(map, nil), do: {:ok, map}

  defp put_cause(map, %Cause{} = cause_struct) do
    with {:ok, cause_obj} <- cause(cause_struct) do
      {:ok, Map.put(map, "cause", cause_obj)}
    end
  end

  @spec cause(Cause.t()) :: {:ok, map()} | {:error, term()}
  defp cause(%Cause{} = cause_struct) do
    with {:ok, origin_obj} <- origin(cause_struct.origin) do
      {:ok,
       %{
         "origin" => origin_obj,
         "macrostep" => cause_struct.macrostep,
         "microstep" => cause_struct.microstep,
         "round" => cause_struct.round
       }}
    end
  end

  @spec origin(Cause.origin()) :: {:ok, map()} | {:error, term()}
  defp origin({:content, c_index, owner_tuple}) do
    with {:ok, owner_obj} <- owner(owner_tuple) do
      {:ok, %{"kind" => "content", "c_index" => c_index, "owner" => owner_obj}}
    end
  end

  defp origin({:state, state_index}) do
    {:ok, %{"kind" => "state", "state_index" => state_index}}
  end

  defp origin({:transition, t_index}) do
    {:ok, %{"kind" => "transition", "t_index" => t_index}}
  end

  defp origin({:data, d_index}) do
    {:ok, %{"kind" => "data", "d_index" => d_index}}
  end

  defp origin({:donedata_param, state_index, param_index}) do
    {:ok,
     %{"kind" => "donedata_param", "state_index" => state_index, "param_index" => param_index}}
  end

  defp origin({:global_script, index}) do
    {:ok, %{"kind" => "global_script", "index" => index}}
  end

  defp origin({:invoke, state_index, invoke_index}) do
    {:ok, %{"kind" => "invoke", "state_index" => state_index, "invoke_index" => invoke_index}}
  end

  defp origin({:finalize, state_index, invoke_index}) do
    {:ok, %{"kind" => "finalize", "state_index" => state_index, "invoke_index" => invoke_index}}
  end

  @spec owner(Statifier.Machine.Content.owner() | Trace.ContentExecuted.owner()) ::
          {:ok, map()} | {:error, term()}
  defp owner({:onentry, state_index, ordinal}) do
    {:ok, %{"kind" => "onentry", "state_index" => state_index, "ordinal" => ordinal}}
  end

  defp owner({:onexit, state_index, ordinal}) do
    {:ok, %{"kind" => "onexit", "state_index" => state_index, "ordinal" => ordinal}}
  end

  defp owner({:transition, t_index}) do
    {:ok, %{"kind" => "transition", "t_index" => t_index}}
  end

  defp owner({:finalize, state_index, invoke_index}) do
    {:ok, %{"kind" => "finalize", "state_index" => state_index, "invoke_index" => invoke_index}}
  end

  defp owner({:global_script, index}) do
    {:ok, %{"kind" => "global_script", "index" => index}}
  end

  @spec put_owner(map(), Statifier.Machine.Content.owner() | nil) ::
          {:ok, map()} | {:error, term()}
  defp put_owner(map, nil), do: {:ok, map}

  defp put_owner(map, owner_tuple) do
    with {:ok, owner_obj} <- owner(owner_tuple) do
      {:ok, Map.put(map, "owner", owner_obj)}
    end
  end

  # A genuine set - a `MapSet` in the engine - serializes as an array sorted
  # ascending. Applies to `configuration` wherever it appears.
  @spec configuration(MapSet.t(non_neg_integer())) :: [non_neg_integer()]
  defp configuration(set), do: set |> MapSet.to_list() |> Enum.sort()

  # A sequence the engine already orders (exit/entry sets, content indexes,
  # invoke-pass state indexes) keeps that order - decision 4, made
  # mechanical by naming the identity function rather than sorting inline at
  # each call site.
  @spec indexes([non_neg_integer()]) :: [non_neg_integer()]
  defp indexes(list), do: list

  # -- Absence ----------------------------------------------------------------

  # `_event.data`'s three-way rule (decision 5, unchanged): `:undefined`
  # omits the key, everything else - including `nil` - goes through
  # `StatifierUI.Value.encode/1` and is kept, even when the encoded result is
  # JSON `null`.
  @spec put_event_data(map(), term()) :: {:ok, map()} | {:error, term()}
  defp put_event_data(map, :undefined), do: {:ok, map}

  defp put_event_data(map, data) do
    with {:ok, encoded} <- Value.encode(data) do
      {:ok, Map.put(map, "data", encoded)}
    end
  end

  # Every other value-position field: the engine has no `:undefined` for
  # these (`Log.value`, both `donedata` fields default to plain `nil`) or,
  # where it does (`Send`/`SendDelayed`'s `data`, `Invoke`'s `params`/
  # `content`), this format's generalized absence rule (decision 5) treats
  # `nil` and `:undefined` alike as "nothing here" rather than "present and
  # null" - applied uniformly instead of remembered clause by clause.
  @spec put_value(map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  defp put_value(map, _key, nil), do: {:ok, map}
  defp put_value(map, _key, :undefined), do: {:ok, map}

  defp put_value(map, key, value) do
    with {:ok, encoded} <- Value.encode(value) do
      {:ok, Map.put(map, key, encoded)}
    end
  end

  # Raw (non-value) optional fields - identifiers, flags, already-tagged
  # objects - where `nil` (and, defensively, `:undefined`) means absent and
  # no `StatifierUI.Value.encode/1` call is needed.
  @spec put_present(map(), String.t(), term()) :: map()
  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, :undefined), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
