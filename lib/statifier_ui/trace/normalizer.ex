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
  `Send.data`, `SendDelayed.data`, `Invoke.params`, `Invoke.content`,
  `DatamodelChange.new_value`, `DatamodelChange.prior_value` - goes
  through `StatifierUI.Value.encode/1`; its `{:error, _}` is propagated,
  never rescued. Everything structural is reduced first (decision 6):
  `MapSet`s to sorted lists (`configuration/1`), atoms to `"kind"`-tagged
  objects (`origin/1`, `owner/1`). This ordering matters -
  `StatifierUI.Value.encode/1` rejects any term outside predicator's
  closed value domain with `{:error, {:unsupported_value, term}}`, so
  handing it a raw tuple or a bare atom would produce a wrong error
  (`:unsupported_value` instead of a normalizer-specific one) rather than
  the structural, purpose-built handling this module gives those shapes.
  A `%Statifier.Evaluator.Error{}` in `Event.data` gets the same
  structural treatment, one step further: it never reaches
  `StatifierUI.Value.encode/1` at all, because it is not a predicator
  value - it is reduced by `StatifierUI.Trace.Diagnostic.object/4` into
  the wire `error` object and lands on the event's `"error"` key instead
  of `"data"`. The two keys are alternatives, never siblings.
  An `error.execution` or `error.communication` event's data gets the same
  treatment for the same reason (ADR-0014): the engine's raise site puts an
  unconstrained reason term there, `StatifierUI.Value.encode/1` rejects the
  tagged tuples it is in practice, and the whole message used to be dropped
  rather than rendered. It is reduced by
  `StatifierUI.Trace.Diagnostic.reason_object/4` onto the same `"error"`
  key instead.

  ## Absence

  `_event.data` keeps ADR-0005's three-way rule unchanged: `:undefined`
  omits the key, `nil` is present as JSON `null`, `%{}` is present as `{}`
  (`put_defined/3`). `DatamodelChange.new_value` and
  `DatamodelChange.prior_value` follow the same three-way rule, because they
  share `_event.data`'s property: the engine spells "unbound" as
  `:undefined` there (ADR-0037), so `nil` genuinely means a stored null.
  Every other nullable field in this vocabulary has no
  engine-side way to distinguish "no value" from "a genuinely null value" -
  `Statifier.Effect.Log.value` and the two `donedata` fields default to
  plain `nil` for "nothing here", never `:undefined` - so `put_present/3`
  and `put_value/3` generalize the rule (decision 5) by treating `nil` and
  `:undefined` alike as absence for those fields, applied uniformly instead
  of remembered clause by clause.

  ## The retired third answer

  `normalize/2` used to have a third answer, `:skip`, for an engine trace
  effect the wire format deliberately did not carry - closed, named, and
  distinct from an unknown effect. It had exactly one member,
  `Statifier.Effect.Trace.CondsEvaluated`, skipped by `sui-9fs` because v1
  had no guard-evaluation message to map it onto. ADR-0018 added that
  message, `sui-e41` moved the effect onto the mapping clause below, and the
  answer retired with its last member: **nothing in this module returns
  `:skip`, and `normalize/2` no longer offers it.**

  It was retired rather than kept empty because the empty form is not
  writable here. A guard over an empty list warns that its clause cannot
  match, an unused constant warns on its own, and a contract offering a
  return no clause produces makes every caller's third arm dead code the
  analyzer refuses. The next trace effect ruled out of the vocabulary
  reintroduces the answer with the clause that produces it, which is the
  only form that stays honest.

  The fallthrough that answers `{:error, {:unknown_effect, _}}` is
  untouched, and deliberately so - a trace effect nobody has considered
  still refuses. That refusal is the mechanism the skip was always distinct
  from, and it is the half that has members.
  """

  alias Statifier.Effect.Autoforward
  alias Statifier.Effect.BudgetExhausted
  alias Statifier.Effect.Cancel
  alias Statifier.Effect.CancelInvoke
  alias Statifier.Effect.DatamodelChange
  alias Statifier.Effect.DatamodelInit
  alias Statifier.Effect.Done
  alias Statifier.Effect.Invoke
  alias Statifier.Effect.Log
  alias Statifier.Effect.Send
  alias Statifier.Effect.SendDelayed
  alias Statifier.Effect.Trace
  alias Statifier.Evaluator
  alias Statifier.Event
  alias Statifier.Event.Cause
  alias StatifierUI.Trace.Diagnostic
  alias StatifierUI.Trace.Message
  alias StatifierUI.Value

  @typedoc """
  What `normalize/2` needs beyond the effect itself: the emitting session
  and the `seq` to stamp, always required. `:machine` and `:source` are
  optional - present only when the caller (`StatifierUI.Trace.Subscriber`)
  can supply the compiled machine and the chart text, which is what lets
  `StatifierUI.Trace.Diagnostic.object/4` resolve an absolute `location`
  for an `%Evaluator.Error{}` event. Without them the `error` object still
  carries `kind`/`expression`/`span`; only `location`/`location_kind` are
  omitted. Optional rather than required on purpose: every existing test
  in this module constructs `ctx` as a two-key struct literal, and the
  moduledoc's "no process, no session, no `%Statifier.Machine{}`" claim
  stays true for the rest of the vocabulary.
  """
  @type ctx :: %{
          :session => String.t(),
          :seq => non_neg_integer(),
          optional(:machine) => Statifier.Machine.t(),
          optional(:source) => String.t()
        }

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
    "trace.conds_evaluated",
    "trace.exit_set",
    "trace.content_executed",
    "trace.entry_set",
    "trace.macrostep_stable",
    "trace.done",
    "trace.invoke_pass",
    "trace.finalize_autoforward",
    "effect.log",
    "effect.datamodel_change",
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
  vocabulary's single definition site in code. 25 entries: 10 `trace.*` (the
  nine Appendix D phase boundaries plus `trace.conds_evaluated`, the guard
  seam inside selection, from `Statifier.Effect.Trace.CondsEvaluated`), 10
  `effect.*` (the nine core effects plus `effect.datamodel_change`, from
  `Statifier.Effect.DatamodelChange`), and 5 `session.*` (the four
  lifecycle types plus `session.datamodel`, emitted once per session from
  `Statifier.Effect.DatamodelInit`). `docs/wire-format.md`'s type index
  table is the same 25, and `test/statifier_ui/trace/wire_format_spec_test.exs`
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

  There is no third answer. `normalize/2` returned `:skip` while one engine
  trace effect had no message to map onto; ADR-0018 gave it one, so every
  effect this module accepts now produces a message or an error. See this
  module's "The retired third answer" section.
  """
  @spec normalize(input(), ctx()) :: {:ok, Message.t()} | {:error, term()}
  def normalize({:effect, effect}, ctx), do: normalize(effect, ctx)

  def normalize({:halted, reason}, ctx) when reason in [:done, :cancelled, :budget_exhausted] do
    build(ctx, "session.halted", nil, nil, nil, %{"reason" => Atom.to_string(reason)})
  end

  def normalize({:unroutable, effect}, ctx) do
    with {:ok, {type, macrostep, microstep, round, payload}} <- decompose(effect, ctx) do
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
    with {:ok, {type, macrostep, microstep, round, payload}} <- decompose(effect, ctx) do
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

  @spec decompose(Statifier.Effect.t(), ctx()) ::
          {:ok, decomposed()} | {:error, term()}
  defp decompose({:trace, payload}, ctx), do: trace_message(payload, ctx)
  defp decompose({:log, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:done, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:budget_exhausted, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:invoke, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:cancel_invoke, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:autoforward, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:send, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:send_delayed, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:cancel, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:datamodel_change, payload}, ctx), do: core_message(payload, ctx)
  defp decompose({:datamodel_init, payload}, _ctx), do: datamodel_message(payload)
  defp decompose({tag, _payload}, _ctx), do: {:error, {:unknown_effect, tag}}
  defp decompose(other, _ctx), do: {:error, {:unknown_effect, other}}

  # -- The ten trace.* payloads ----------------------------------------------

  @spec trace_message(struct(), ctx()) :: {:ok, decomposed()} | {:error, term()}
  defp trace_message(%Trace.EventDequeued{} = p, ctx) do
    with {:ok, event_obj} <- event(p.event, ctx) do
      payload = %{"event" => event_obj, "from" => Atom.to_string(p.from)}
      {:ok, {"trace.event_dequeued", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.TransitionsSelected{} = p, ctx) do
    base = %{"t_indexes" => indexes(p.t_indexes)}

    with {:ok, payload} <- put_event(base, p.event, ctx) do
      {:ok, {"trace.transitions_selected", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.ExitSet{} = p, _ctx) do
    payload = %{"indexes" => indexes(p.indexes)}
    {:ok, {"trace.exit_set", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.ContentExecuted{} = p, _ctx) do
    with {:ok, owner_obj} <- owner(p.owner) do
      payload = %{"owner" => owner_obj, "c_indexes" => indexes(p.c_indexes)}
      {:ok, {"trace.content_executed", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.EntrySet{} = p, _ctx) do
    payload = %{"indexes" => indexes(p.indexes)}
    {:ok, {"trace.entry_set", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.MacrostepStable{} = p, _ctx) do
    payload = %{"configuration" => configuration(p.configuration)}
    {:ok, {"trace.macrostep_stable", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.Done{} = p, _ctx) do
    base = %{"configuration" => configuration(p.configuration)}

    with {:ok, payload} <- put_value(base, "donedata", p.donedata) do
      {:ok, {"trace.done", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.InvokePass{} = p, _ctx) do
    payload = %{"state_indexes" => indexes(p.state_indexes), "invoke_ids" => p.invoke_ids}
    {:ok, {"trace.invoke_pass", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(%Trace.FinalizeAutoforward{} = p, ctx) do
    with {:ok, event_obj} <- event(p.event, ctx) do
      payload = %{"event" => event_obj, "finalized" => p.finalized, "forwarded" => p.forwarded}
      {:ok, {"trace.finalize_autoforward", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp trace_message(%Trace.CondsEvaluated{} = p, ctx) do
    payload = %{"evaluations" => Enum.map(p.evaluations, &evaluation(&1, ctx))}
    {:ok, {"trace.conds_evaluated", p.macrostep, p.microstep, p.round, payload}}
  end

  defp trace_message(payload, _ctx),
    do: {:error, {:unknown_effect, {:trace, payload.__struct__}}}

  # One `trace.conds_evaluated` entry, ADR-0018 decisions 2 and 3.
  #
  # `outcome` is the engine atom's own name, lowercased as written, and a
  # closed discriminator - it is never derived from whether `reason` is
  # present, so the two stay independently checkable the way the record says
  # a consumer may test either.
  #
  # `reason` goes through the same `Diagnostic.reason_object/4` an
  # `error.execution` event's data goes through, with the entry's own
  # `{:transition, t_index}` origin. That is deliberate rather than
  # convenient: the engine produces **two** shapes here -
  # `{:non_boolean_cond, value}` and `%Statifier.Evaluator.Error{}` - and
  # `reason_object/4` is already the function that sorts an unconstrained
  # term into ADR-0014's two classes. Rendering only one of them, or adding a
  # second diagnostic surface for the other, is the mistake the record names.
  @spec evaluation(Trace.CondsEvaluated.evaluation(), ctx()) :: map()
  defp evaluation(%{t_index: t_index, outcome: outcome, reason: reason}, ctx) do
    %{"t_index" => t_index, "outcome" => Atom.to_string(outcome)}
    |> put_reason(reason, t_index, ctx)
  end

  # `nil` is absence, not a null: the engine spells "no failure here" as a
  # plain `nil` on every non-error outcome, with no `:undefined` to tell a
  # genuine null from it, so this follows `put_present/3`'s rule rather than
  # `_event.data`'s three-way one (ADR-0018 decision 2).
  @spec put_reason(map(), term(), non_neg_integer(), ctx()) :: map()
  defp put_reason(base, nil, _t_index, _ctx), do: base

  defp put_reason(base, reason, t_index, ctx) do
    object =
      Diagnostic.reason_object(
        reason,
        {:transition, t_index},
        Map.get(ctx, :machine),
        Map.get(ctx, :source)
      )

    Map.put(base, "reason", object)
  end

  # -- The ten effect.* payloads ----------------------------------------------

  @spec core_message(struct(), ctx()) :: {:ok, decomposed()} | {:error, term()}
  defp core_message(%DatamodelChange{} = p, _ctx) do
    # `location_path` is emitted structurally, not through
    # `StatifierUI.Value.encode/1`: its segments are only strings (object
    # keys) and integers (array indexes), both JSON-native, and the path is
    # an identity like `c_index`, not a value.
    base =
      %{"location_path" => p.location_path, "location_source" => p.location_source}
      |> put_present("d_index", p.d_index)
      |> put_present("c_index", p.c_index)

    with {:ok, base} <- put_owner(base, p.owner),
         {:ok, base} <- put_defined(base, "new_value", p.new_value),
         {:ok, base} <- put_defined(base, "prior_value", p.prior_value) do
      {:ok, {"effect.datamodel_change", p.macrostep, p.microstep, p.round, base}}
    end
  end

  defp core_message(%Log{} = p, _ctx) do
    base = put_present(%{}, "label", p.label)

    with {:ok, base} <- put_owner(base, p.owner),
         {:ok, base} <- put_value(base, "value", p.value) do
      base = put_present(base, "c_index", p.c_index)
      {:ok, {"effect.log", p.macrostep, p.microstep, p.round, base}}
    end
  end

  defp core_message(%Done{} = p, _ctx) do
    base = %{"configuration" => configuration(p.configuration)}

    with {:ok, payload} <- put_value(base, "donedata", p.donedata) do
      {:ok, {"effect.done", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp core_message(%BudgetExhausted{} = p, ctx) do
    with {:ok, pending} <- event_list(p.pending_internal_events, ctx) do
      payload = %{
        "configuration" => configuration(p.configuration),
        "budget" => budget(p.budget),
        "pending_internal_events" => pending
      }

      {:ok, {"effect.budget_exhausted", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp core_message(%Invoke{} = p, _ctx) do
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
      {:ok, {"effect.invoke", p.macrostep, p.microstep, p.round, base}}
    end
  end

  defp core_message(%CancelInvoke{} = p, _ctx) do
    payload = %{"invoke_id" => p.invoke_id, "state_index" => p.state_index}
    {:ok, {"effect.cancel_invoke", p.macrostep, p.microstep, p.round, payload}}
  end

  defp core_message(%Autoforward{} = p, ctx) do
    with {:ok, event_obj} <- event(p.event, ctx) do
      payload = %{
        "invoke_id" => p.invoke_id,
        "state_index" => p.state_index,
        "event" => event_obj
      }

      {:ok, {"effect.autoforward", p.macrostep, p.microstep, p.round, payload}}
    end
  end

  defp core_message(%Send{} = p, _ctx) do
    base =
      %{"event" => p.event, "send_id" => p.send_id, "id_from_author" => p.id_from_author?}
      |> put_present("target", p.target)
      |> put_present("send_type", p.type)

    with {:ok, base} <- put_owner(base, p.owner),
         {:ok, base} <- put_value(base, "data", p.data) do
      base = put_present(base, "c_index", p.c_index)
      {:ok, {"effect.send", p.macrostep, p.microstep, p.round, base}}
    end
  end

  defp core_message(%SendDelayed{} = p, _ctx) do
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
      {:ok, {"effect.send_delayed", p.macrostep, p.microstep, p.round, base}}
    end
  end

  defp core_message(%Cancel{} = p, _ctx) do
    base = put_present(%{"send_id" => p.send_id}, "c_index", p.c_index)

    with {:ok, base} <- put_owner(base, p.owner) do
      {:ok, {"effect.cancel", p.macrostep, p.microstep, p.round, base}}
    end
  end

  # -- session.datamodel -------------------------------------------------------

  # The engine emits exactly one DatamodelInit per initialize/2 - first in
  # the stream, unconditionally, even under `trace: false` (st-1xwh). It
  # lands on the type `docs/wire-format.md` reserved for st-oef3, so the
  # vocabulary does not grow and ADR-0005's version stays at 1. Like every
  # other `session.*` message the envelope counters stay nil, even though
  # the payload struct carries them.
  @spec datamodel_message(struct()) :: {:ok, decomposed()} | {:error, term()}
  defp datamodel_message(%DatamodelInit{} = p) do
    with {:ok, encoded} <- Value.encode(p.datamodel) do
      {:ok, {"session.datamodel", nil, nil, nil, %{"datamodel" => encoded}}}
    end
  end

  @spec budget(pos_integer() | :infinity) :: pos_integer() | String.t()
  defp budget(:infinity), do: "infinity"
  defp budget(n) when is_integer(n), do: n

  @spec event_list([Event.t()], ctx()) :: {:ok, [map()]} | {:error, term()}
  defp event_list(events, ctx) do
    events
    |> Enum.reduce_while({:ok, []}, fn ev, {:ok, acc} ->
      case event(ev, ctx) do
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

  @spec event(Event.t(), ctx()) :: {:ok, map()} | {:error, term()}
  defp event(%Event{} = ev, ctx) do
    base = %{"name" => ev.name, "type" => Atom.to_string(ev.type)}

    with {:ok, base} <- put_event_data(base, ev, ctx),
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

  # A `%Statifier.Evaluator.Error{}` is not a predicator value, so it never
  # goes through `StatifierUI.Value.encode/1` - which rejects it with
  # `{:error, {:unsupported_value, _}}` and fails the whole message, as it
  # does today. It is reduced structurally instead, the same move `origin/1`
  # and `owner/1` make for atoms and tuples, and it lands on its own
  # `"error"` key rather than in the `"data"` value position: the two are
  # alternatives, so this clause never calls `put_defined/3` at all.
  @spec put_event_data(map(), Event.t(), ctx()) :: {:ok, map()} | {:error, term()}
  defp put_event_data(base, %Event{data: %Evaluator.Error{} = error} = ev, ctx) do
    object =
      Diagnostic.object(
        error,
        origin_of(ev.cause),
        Map.get(ctx, :machine),
        Map.get(ctx, :source)
      )

    {:ok, Map.put(base, "error", object)}
  end

  # ADR-0014's reason arm. `Statifier.Interpreter.Content.raise_execution_error/4`
  # puts an unconstrained `reason` term in these two events' `data`, and
  # `StatifierUI.Value.encode/1` rejects the tagged tuples it is in practice
  # - which failed the whole message, so the subscriber dropped it and the
  # failure never rendered at all. It is reduced structurally instead, onto
  # the same `"error"` key the clause above uses.
  #
  # The clause is selected by the event's `name` and not by whether the term
  # encodes: ADR-0014's per-variant table is the two names above and nothing
  # else, and a bare string or a list is a perfectly good `data` value on
  # every other event. Both names take identical rows - a consumer branches
  # on `class` and `kind`, never on which `error.*` event carried them.
  #
  # `:undefined` is excluded because it is this format's own spelling of
  # absence (ADR-0005, ADR-0037), not a reason term: rendering it as
  # `kind: "undefined"` would assert a failure the run never named. The
  # engine's raise site always supplies a reason, so the exclusion is a
  # guard on an unreachable shape rather than a case with traffic in it.
  defp put_event_data(base, %Event{name: name, data: data} = ev, ctx)
       when name in ["error.execution", "error.communication"] and data != :undefined do
    object =
      Diagnostic.reason_object(
        ev.data,
        origin_of(ev.cause),
        Map.get(ctx, :machine),
        Map.get(ctx, :source)
      )

    {:ok, Map.put(base, "error", object)}
  end

  defp put_event_data(base, %Event{} = ev, _ctx), do: put_defined(base, "data", ev.data)

  # `cause` is nil on an external event, and an event the platform raised
  # always has one - but an `%Evaluator.Error{}` arriving without a cause is
  # not a reason to fail the message, so the origin is simply absent and
  # `Diagnostic.object/4` falls back to emitting no `location`.
  @spec origin_of(Cause.t() | nil) :: Cause.origin() | nil
  defp origin_of(%Cause{origin: origin}), do: origin
  defp origin_of(nil), do: nil

  @spec put_event(map(), Event.t() | nil, ctx()) :: {:ok, map()} | {:error, term()}
  defp put_event(map, nil, _ctx), do: {:ok, map}

  defp put_event(map, %Event{} = ev, ctx) do
    with {:ok, event_obj} <- event(ev, ctx) do
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

  @spec owner(
          Statifier.Machine.Content.owner()
          | Trace.ContentExecuted.owner()
          | DatamodelChange.owner()
        ) ::
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

  defp owner({:invoke, state_index, invoke_index}) do
    {:ok, %{"kind" => "invoke", "state_index" => state_index, "invoke_index" => invoke_index}}
  end

  @spec put_owner(map(), Statifier.Machine.Content.owner() | DatamodelChange.owner() | nil) ::
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

  # The three-way rule (decision 5, unchanged): `:undefined` omits the key,
  # everything else - including `nil` - goes through
  # `StatifierUI.Value.encode/1` and is kept, even when the encoded result is
  # JSON `null`. Applies where the engine genuinely distinguishes unbound
  # (`:undefined`) from a stored null (`nil`): `_event.data`, and
  # `DatamodelChange`'s `new_value`/`prior_value`.
  @spec put_defined(map(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  defp put_defined(map, _key, :undefined), do: {:ok, map}

  defp put_defined(map, key, value) do
    with {:ok, encoded} <- Value.encode(value) do
      {:ok, Map.put(map, key, encoded)}
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
