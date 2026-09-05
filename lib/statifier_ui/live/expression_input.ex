if Code.ensure_loaded?(Phoenix.Component) do
  defmodule StatifierUI.Live.ExpressionInput do
    @moduledoc """
    An expression field with completion: predicator's grammar and the host's
    declared datamodel paths, offered at the caret.

    This is the affordance statifier_blocks ADR-0005 decision 15 defers here -
    "Rich expression editing is statifier-ui's" - and it is written to drop
    straight into that package's `expression_component` seam:

        <StatifierBlocks.Editor.editor
          ...
          expression_component={&StatifierUI.Live.ExpressionInput.expression_input/1}
          path_candidates={StatifierBlocks.Datamodel.candidates(document, datamodel)}
        />

    Nothing here depends on statifier_blocks, and nothing here knows what a
    block is. The seam hands this component a five-key map - `:field`, `:id`,
    `:name`, `:value`, `:candidates` - and `:field` is the one key it
    deliberately ignores: reading it would mean knowing that package's view
    model, and ADR-0004's dependency arrow points the other way. Any host with
    an expression to edit can call it the same way.

    ## The assigns arrive as a bare map

    The seam calls the override as a plain one-argument function rather than
    through a HEEx component tag, so `attr` defaults never run. Every assign
    outside those five keys is defaulted here, in `normalize/1`, which is what
    makes the same function usable both ways - `<.expression_input .../>` in a
    template and `component.(%{...})` from the seam.

    ## Edits round-trip through the host's own form

    The rendered `<input>` carries the `name` it was handed and nothing else:
    no `phx-change`, no `phx-target`, no event of its own. In the sb editor
    that input sits inside `<form phx-change="config-change">`, so an edit is
    already the host's event, arriving with every other field. The hook keeps
    that true - after it writes a completion in, it dispatches a bubbling
    `input` event, so a keyboard-driven completion and a typed character are
    the same event to the host.

    ## Two modes, and the source text is the only representation

    The field has a **picklist mode** beside its text mode. On every render the
    source is classified by `StatifierUI.Expression.simple/2`: inside the
    picklist-renderable subset it draws one row of dropdowns per clause -
    field, operator, value - with a connective toggle and an add-clause button;
    outside it it draws the text input. Source that does not parse is a third
    answer rather than the second: the text input plus the parse error's own
    position, per ADR-0007's picklist amendment. It never refuses a source
    string and never rewrites one.

    **Every control writes source text, and only source text.** There is no
    structured model held anywhere: each `<option>`'s value *is* the complete
    expression source that choosing it produces, written by
    `Predicator.Simple.to_source/1` through `StatifierUI.Expression.source/2`,
    and picking one copies that string into the same named `<input>` the text
    mode edits. The two controls that have to compose rather than choose - a
    free-text value and a multi-select list - are handed a source *template*
    with the value's own spelling standing in it, plus the quoting, escaping
    and list punctuation the writer uses, all measured off
    `StatifierUI.Expression.value_source/2` rather than written out in
    JavaScript. Nothing in the browser knows how predicator spells anything.

    That is the load-bearing property. A picklist that kept clause rows as its
    own state would be the second source of truth ADR-0007 rules out for the
    diagram, arrived at through a form instead of a canvas.

    ## Switching modes

    The switch to text is always offered; the switch to picklists is offered
    only while the current text is inside the subset - an author is never
    invited into a mode that cannot draw what they have written. The choice is
    the viewer's and lives in the hook, so a re-render from the host does not
    drag an author back out of the mode they picked. The server decides only
    the *default*, which is picklists when the source is inside the subset.

    Picklist mode needs the `StatifierUIExpressionPicklist` hook, because a
    control that writes source text has to write it into the input; a host
    that registers no hook gets the text field alone, the same degradation the
    completion popup makes.

    ## Operator labels are display, the source is not

    A dropdown shows `is one of` where the writer spells `IN`. The label is a
    display string; the value stored is always the writer's own spelling,
    untouched. Since the re-pin to a predicator carrying
    `Predicator.Vocabulary`'s human labels (px-84i), operator labels are the
    grammar's own phrases, delivered by `StatifierUI.Expression.operators/1` as
    the `:label` beside the writer's `:lexeme` - so this module no longer makes
    them. `display_label/1` still lowercases a word-shaped lexeme, but the
    grammar's phrases are already display-cased - the only word-shaped one,
    `contains`, is already lowercase - so it is a no-op for operator labels.
    It is still called, on every operator option this module renders; what it
    should become now that it changes nothing, and whether its own `@doc`
    below should still describe casing `IN` down to `in`, are sui-ne0's
    questions rather than this module's.

    ## Two affordances, and the second one is optional

    Without JavaScript the field is a text input bound to a `<datalist>` of the
    word-shaped completions - the same affordance sb's plain control gives for
    paths, widened to the grammar. With `assets/js/expression_input.js`
    registered as the `StatifierUIExpressionInput` hook (ADR-0009: the
    JavaScript ships as source and the host's bundler compiles it), the hook
    drops the datalist and offers a caret-aware list instead: the token under
    the cursor is the prefix, arrow keys move, Enter or Tab inserts.

    A host that registers no hook loses the popup and keeps the field. A
    predicator without `Predicator.Vocabulary` loses the grammar entries and
    keeps the declared paths. Both states are stamped on the element rather
    than inferred - `data-hook` and `data-vocabulary` - so a page that offers
    nothing says which of the two reasons it is.

    ## What it stamps

    Per ADR-0007's data-attribute contract, the rendered structure is the
    testable surface:

    | Attribute | On | Meaning |
    |---|---|---|
    | `data-completions` | the input | the full completion list as JSON, the hook's whole input |
    | `data-completion-count` | the input | how many were offered |
    | `data-vocabulary` | the input | whether the grammar half resolved |
    | `data-candidates` | the input | how many declared paths were supplied |
    | `data-expression-source` | the input | marks the one element holding the source |
    | `data-mode` | the wrapper | `picklist` or `text`, the mode rendered |
    | `data-subset` | the wrapper | `inside`, `outside`, or `error` |
    | `data-error-position` | the diagnostic | `line:column` of a parse failure |
    | `data-clause-count` | the wrapper | how many clause rows were drawn |
    | `data-clause-index` | a clause row | its position, from zero |
    | `data-role` | a picklist control | `path`, `operator`, `value`, `connective` |
    | `data-action` | a button | `add-clause`, `remove-clause`, `switch-text`, `switch-picklist` |
    """

    use Phoenix.Component

    alias StatifierUI.Expression

    @hook "StatifierUIExpressionInput"
    @picklist_hook "StatifierUIExpressionPicklist"

    # A stand-in value, written through the same writer every real value goes
    # through, so a source template arrives with the hole already quoted,
    # bracketed and escaped exactly as a value of that kind would be. The
    # browser substitutes text into a gap predicator itself punched, which is
    # why no quoting rule is repeated in JavaScript.
    @sentinel "SUIVALUESENTINEL"
    @sentinel_integer 4_294_967_291
    @list_probe_a "SUILISTPROBEA"
    @list_probe_b "SUILISTPROBEB"

    attr(:id, :string, required: true, doc: "DOM id of the input itself.")
    attr(:name, :string, required: true, doc: "form field name; the host's form owns the event.")
    attr(:value, :string, default: "", doc: "the expression source.")

    attr(:candidates, :list,
      default: [],
      doc: "declared datamodel paths, from the host. Offered ahead of the grammar."
    )

    attr(:value_candidates, :map,
      default: %{},
      doc:
        "values the host offers per clause path, as `%{path => [candidate]}`. " <>
          "Only the host knows its own value sets; a path with no entry gets a free-text control."
    )

    attr(:mode, :atom,
      default: :auto,
      values: [:auto, :text, :picklist],
      doc:
        "which mode to render first. `:auto` picks picklists when the source is inside the subset."
    )

    attr(:hook, :string,
      default: @hook,
      doc: "`phx-hook` name; `nil` renders the datalist-only field."
    )

    attr(:picklist_hook, :string,
      default: nil,
      doc:
        "`phx-hook` name for the picklist. Defaults to the shipped hook, or to `nil` when " <>
          "`:hook` is `nil` - a host registering no hooks has none of this package's JavaScript."
    )

    attr(:placeholder, :string, default: "an expression")
    attr(:class, :string, default: nil)

    attr(:vocabulary_opts, :list,
      default: [],
      doc: "passed to `Predicator.Vocabulary.functions/1` - a host's own providers."
    )

    attr(:field, :any, default: nil, doc: "accepted from the sb seam and never read.")

    @doc """
    The field: the picklist rows, the text input, and the switch between them.

    See the module doc for the seam this is written against, for why every
    control writes source text, and for what the rendered element stamps.
    """
    @spec expression_input(map()) :: Phoenix.LiveView.Rendered.t()
    def expression_input(assigns) do
      assigns = normalize(assigns)

      ~H"""
      <div
        class={["statifier-ui-expression", @class]}
        id={@id <> "-expression"}
        phx-hook={@picklist_hook}
        data-mode={@mode}
        data-subset={@subset}
        data-clause-count={length(@clauses)}
      >
        <div
          :if={@picklist?}
          class="statifier-ui-expression-picklist"
          role="group"
          aria-label="expression clauses"
          hidden={@mode != :picklist}
        >
          <div
            :for={clause <- @clauses}
            class="statifier-ui-expression-clause"
            data-clause-index={clause.index}
          >
            <select
              class="statifier-ui-expression-path"
              data-role="path"
              aria-label={"field, clause #{clause.index + 1}"}
            >
              <option :for={option <- clause.path_options} value={option.source} selected={option.selected}>
                {option.label}
              </option>
            </select>
            <select
              class="statifier-ui-expression-operator"
              data-role="operator"
              aria-label={"operator, clause #{clause.index + 1}"}
            >
              <option
                :for={option <- clause.op_options}
                value={option.source}
                selected={option.selected}
                title={option.detail}
              >
                {option.label}
              </option>
            </select>
            <select
              :if={clause.value.kind == :select}
              class="statifier-ui-expression-value"
              data-role="value"
              data-value-kind="select"
              aria-label={"value, clause #{clause.index + 1}"}
            >
              <option
                :for={option <- clause.value.options}
                value={option.source}
                selected={option.selected}
              >
                {option.label}
              </option>
            </select>
            <select
              :if={clause.value.kind == :multiselect}
              multiple
              class="statifier-ui-expression-value"
              data-role="value"
              data-value-kind="multiselect"
              data-source-template={clause.value.template}
              data-sentinel={clause.value.sentinel}
              data-list-open={clause.value.open}
              data-list-separator={clause.value.separator}
              data-list-close={clause.value.close}
              aria-label={"values, clause #{clause.index + 1}"}
            >
              <option
                :for={option <- clause.value.options}
                value={option.fragment}
                selected={option.selected}
              >
                {option.label}
              </option>
            </select>
            <input
              :if={clause.value.kind == :text}
              type="text"
              class="statifier-ui-expression-value"
              data-role="value"
              data-value-kind="text"
              data-source-template={clause.value.template}
              data-sentinel={clause.value.sentinel}
              data-wrap-prefix={clause.value.prefix}
              data-wrap-suffix={clause.value.suffix}
              data-escapes={clause.value.escapes}
              value={clause.value.text}
              spellcheck="false"
              autocomplete="off"
              aria-label={"value, clause #{clause.index + 1}"}
            />
            <span
              :if={clause.value.kind == :readonly}
              class="statifier-ui-expression-value"
              data-role="value"
              data-value-kind="readonly"
            >
              {clause.value.text}
            </span>
            <button
              :if={clause.remove_source}
              type="button"
              class="statifier-ui-expression-remove"
              data-action="remove-clause"
              data-source={clause.remove_source}
              aria-label={"remove clause #{clause.index + 1}"}
            >
              remove
            </button>
          </div>
          <div class="statifier-ui-expression-clause-controls">
            <select
              :if={@connective_options != []}
              class="statifier-ui-expression-connective"
              data-role="connective"
              aria-label="how the clauses join"
            >
              <option
                :for={option <- @connective_options}
                value={option.source}
                selected={option.selected}
              >
                {option.label}
              </option>
            </select>
            <button
              :if={@add_source}
              type="button"
              class="statifier-ui-expression-add"
              data-action="add-clause"
              data-source={@add_source}
            >
              add clause
            </button>
          </div>
        </div>
        <div class="statifier-ui-expression-text" hidden={@mode == :picklist}>
          <input
            type="text"
            class="statifier-ui-expression-input"
            id={@id}
            name={@name}
            value={@value}
            list={@list_id}
            placeholder={@placeholder}
            spellcheck="false"
            autocomplete="off"
            phx-hook={@hook}
            data-expression-source="true"
            data-completions={@completions_json}
            data-completion-count={length(@completions)}
            data-candidates={length(@candidates)}
            data-vocabulary={to_string(@vocabulary?)}
          />
          <p
            :if={@error}
            class="statifier-ui-expression-error"
            role="alert"
            data-error-position={@error.at}
          >
            {@error.message} (line {@error.line}, column {@error.column})
          </p>
          <datalist id={@list_id}>
            <option :for={completion <- @datalist} value={completion.insert}>
              {completion.detail}
            </option>
          </datalist>
        </div>
        <div :if={@picklist_hook} class="statifier-ui-expression-modes">
          <button
            type="button"
            class="statifier-ui-expression-switch"
            data-action="switch-text"
            aria-pressed={to_string(@mode == :text)}
          >
            switch to text
          </button>
          <button
            :if={@picklist?}
            type="button"
            class="statifier-ui-expression-switch"
            data-action="switch-picklist"
            aria-pressed={to_string(@mode == :picklist)}
          >
            switch to picklists
          </button>
        </div>
      </div>
      """
    end

    # The seam calls this function with a bare map, so the defaults `attr`
    # would have supplied are applied here instead. `Map.put_new/3` and not
    # `assign_new/3`: an assigns map that never went through a component tag
    # has no `__changed__` for the latter to consult.
    @spec normalize(map()) :: map()
    defp normalize(assigns) do
      assigns
      |> Map.put_new(:value, "")
      |> Map.put_new(:candidates, [])
      |> Map.put_new(:value_candidates, %{})
      |> Map.put_new(:mode, :auto)
      |> Map.put_new(:hook, @hook)
      |> put_picklist_hook()
      |> Map.put_new(:placeholder, "an expression")
      |> Map.put_new(:class, nil)
      |> Map.put_new(:vocabulary_opts, [])
      |> Map.put_new(:field, nil)
      |> put_completions()
      |> put_picklist()
    end

    # A host that registers no hook has none of this package's JavaScript in
    # its bundle, so it gets neither the completion popup nor a picklist whose
    # controls would have nothing to write with. The two are still separate
    # attributes: a host may name one and silence the other.
    @spec put_picklist_hook(map()) :: map()
    defp put_picklist_hook(assigns) do
      default = if assigns.hook, do: @picklist_hook

      Map.put(assigns, :picklist_hook, Map.get(assigns, :picklist_hook) || default)
    end

    @spec put_completions(map()) :: map()
    defp put_completions(assigns) do
      completions = Expression.completions(assigns.candidates, assigns.vocabulary_opts)

      assigns
      |> Map.put(:completions, completions)
      |> Map.put(:datalist, Expression.datalist(completions))
      |> Map.put(:completions_json, encode(completions))
      |> Map.put(:vocabulary?, Expression.vocabulary_available?())
      |> Map.put(:list_id, assigns.id <> "-completions")
      |> Map.put(:value, to_string(assigns.value || ""))
    end

    # The whole picklist is derived here, on every render, from the source
    # string alone. Nothing survives between renders, which is the point: the
    # rows are a view of `@value` and there is nowhere else for a condition to
    # be stored.
    @spec put_picklist(map()) :: map()
    defp put_picklist(assigns) do
      {subset, rows, connective, error} = classify(assigns)
      canonical = source(rows, connective)
      picklist? = assigns.picklist_hook != nil and canonical != nil
      paths = Enum.uniq(assigns.candidates)

      assigns
      |> Map.put(:subset, subset)
      |> Map.put(:error, error)
      |> Map.put(:picklist?, picklist?)
      |> Map.put(:mode, mode(assigns.mode, picklist?))
      |> Map.put(
        :clauses,
        if(picklist?, do: clauses(rows, connective, canonical, paths), else: [])
      )
      |> Map.put(
        :connective_options,
        if(picklist?, do: connective_options(rows, connective, canonical), else: [])
      )
      |> Map.put(:add_source, picklist? && add_source(rows, connective, paths))
    end

    @spec classify(map()) ::
            {String.t(), [Expression.row()], Expression.connective(), map() | nil}
    defp classify(assigns) do
      case Expression.simple(assigns.value, value_candidates: assigns.value_candidates) do
        {:ok, rows, connective} -> {"inside", rows, connective, nil}
        :outside -> {"outside", [], nil, nil}
        {:error, error} -> {"error", [], nil, diagnostic(error)}
      end
    end

    # ADR-0007's picklist amendment: source that does not parse is a third
    # answer, and it gets the text input *plus the parse error's position*.
    # The error comes from predicator through an availability seam, so it is
    # read defensively - a diagnostic that raised while reporting a diagnostic
    # would be worse than the missing position.
    @spec diagnostic(term()) :: map() | nil
    defp diagnostic(error) do
      case {Map.get(error, :message), Map.get(error, :position)} do
        {message, {line, column}} when is_binary(message) ->
          %{message: message, line: line, column: column, at: "#{line}:#{column}"}

        _other ->
          nil
      end
    end

    @spec mode(atom(), boolean()) :: :picklist | :text
    defp mode(_requested, false), do: :text
    defp mode(:text, true), do: :text
    defp mode(_requested, true), do: :picklist

    @spec source([term()], Expression.connective()) :: String.t() | nil
    defp source(rows, connective) do
      case Expression.source(rows, connective) do
        {:ok, written} -> written
        :error -> nil
      end
    end

    @spec fragment(atom(), term()) :: String.t() | nil
    defp fragment(op, value) do
      case Expression.value_source(op, value) do
        {:ok, written} -> written
        :error -> nil
      end
    end

    @spec clauses([Expression.row()], Expression.connective(), String.t(), [String.t()]) :: [
            map()
          ]
    defp clauses(rows, connective, canonical, paths) do
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        %{
          index: index,
          path_options: path_options(rows, connective, canonical, index, row, paths),
          op_options: op_options(rows, connective, canonical, index, row),
          value: value_control(rows, connective, canonical, index, row),
          remove_source: remove_source(rows, connective, index)
        }
      end)
    end

    # Every option's value is the whole expression the choice produces, so
    # picking one is a copy rather than a composition, and an option is
    # selected when the string it carries is the string already there.
    @spec swap([Expression.row()], Expression.connective(), non_neg_integer(), (map() -> map())) ::
            String.t() | nil
    defp swap(rows, connective, index, change) do
      rows |> List.update_at(index, change) |> source(connective)
    end

    @spec path_options(
            [Expression.row()],
            Expression.connective(),
            String.t(),
            non_neg_integer(),
            Expression.row(),
            [String.t()]
          ) :: [map()]
    defp path_options(rows, connective, canonical, index, row, paths) do
      names = if row.path in paths, do: paths, else: [row.path | paths]

      Enum.flat_map(names, fn name ->
        with {:ok, segments} <- Expression.segments(name),
             written when is_binary(written) <-
               swap(rows, connective, index, &%{&1 | segments: segments}) do
          [%{label: name, source: written, selected: written == canonical}]
        else
          _other -> []
        end
      end)
    end

    @spec op_options(
            [Expression.row()],
            Expression.connective(),
            String.t(),
            non_neg_integer(),
            Expression.row()
          ) :: [map()]
    defp op_options(rows, connective, canonical, index, row) do
      Enum.flat_map(row.operators, fn operator ->
        case swap(rows, connective, index, &%{&1 | op: operator.op}) do
          nil ->
            []

          written ->
            [
              %{
                label: display_label(operator.label),
                detail: operator.detail,
                source: written,
                selected: written == canonical
              }
            ]
        end
      end)
    end

    @doc """
    The display spelling of a source lexeme.

    The one place a label is cased. `Predicator.Simple.to_source/1` writes
    `IN` and `CONTAINS` because that is what the grammar's decompiler writes,
    and that spelling is what gets stored; an author reading a dropdown is
    better served by `in`. The two concerns never meet: this touches labels
    only, and every `value` attribute in the rendered picklist is the writer's
    own untouched output.

    ## Examples

        iex> StatifierUI.Live.ExpressionInput.display_label("IN")
        "in"

        iex> StatifierUI.Live.ExpressionInput.display_label(">=")
        ">="

    """
    @spec display_label(String.t()) :: String.t()
    def display_label(label) do
      if label =~ ~r/\A[A-Za-z]+\z/, do: String.downcase(label), else: label
    end

    @spec value_control(
            [Expression.row()],
            Expression.connective(),
            String.t(),
            non_neg_integer(),
            Expression.row()
          ) :: map()
    defp value_control(rows, connective, canonical, index, row) do
      cond do
        list_kind?(row.value_kind) and row.candidates != [] ->
          multiselect(rows, connective, index, row)

        list_kind?(row.value_kind) ->
          readonly(row)

        row.candidates != [] ->
          value_select(rows, connective, canonical, index, row, row.candidates)

        row.value_kind == :boolean ->
          value_select(rows, connective, canonical, index, row, boolean_candidates())

        true ->
          text_control(rows, connective, index, row)
      end
    end

    @spec value_select(
            [Expression.row()],
            Expression.connective(),
            String.t(),
            non_neg_integer(),
            Expression.row(),
            [map()]
          ) :: map()
    defp value_select(rows, connective, canonical, index, row, candidates) do
      options =
        Enum.flat_map(candidates, fn candidate ->
          with {:ok, term} <- term(row.value_kind, style(row), candidate.value),
               written when is_binary(written) <-
                 swap(rows, connective, index, &%{&1 | value: term}) do
            [%{label: candidate.label, source: written, selected: written == canonical}]
          else
            _other -> []
          end
        end)

      %{kind: :select, options: keep_current(options, canonical, row)}
    end

    # An author's own value is never dropped from the list because the host
    # did not declare it. The field renders what is there and offers the rest.
    @spec keep_current([map()], String.t(), Expression.row()) :: [map()]
    defp keep_current(options, canonical, row) do
      if Enum.any?(options, & &1.selected) do
        options
      else
        [%{label: row.value_source, source: canonical, selected: true} | options]
      end
    end

    @spec multiselect(
            [Expression.row()],
            Expression.connective(),
            non_neg_integer(),
            Expression.row()
          ) :: map()
    defp multiselect(rows, connective, index, row) do
      style = style(row)
      hole = {:list, [{:string, @sentinel, style}]}
      template = swap(rows, connective, index, &%{&1 | value: hole})
      sentinel = fragment(:in, hole)
      punctuation = list_punctuation(style)
      chosen = chosen_fragments(row)

      options =
        Enum.flat_map(row.candidates, fn candidate ->
          with {:ok, term} <- term(row.value_kind, style, candidate.value),
               written when is_binary(written) <- fragment(:equal_equal, term) do
            [%{label: candidate.label, fragment: written, selected: written in chosen}]
          else
            _other -> []
          end
        end)

      if usable?(template, sentinel) and punctuation do
        Map.merge(punctuation, %{
          kind: :multiselect,
          options: options,
          template: template,
          sentinel: sentinel
        })
      else
        readonly(row)
      end
    end

    @spec chosen_fragments(Expression.row()) :: [String.t()]
    defp chosen_fragments(%{value: {:list, members}}) do
      Enum.flat_map(members, fn member ->
        case fragment(:equal_equal, member) do
          nil -> []
          written -> [written]
        end
      end)
    end

    defp chosen_fragments(_row), do: []

    # How the writer punctuates a list, measured rather than assumed: two
    # probe members are rendered inside a list and on their own, and what
    # surrounds and separates them is the punctuation.
    @spec list_punctuation(atom()) :: map() | nil
    defp list_punctuation(style) do
      first = {:string, @list_probe_a, style}
      second = {:string, @list_probe_b, style}

      with rendered when is_binary(rendered) <- fragment(:in, {:list, [first, second]}),
           head when is_binary(head) <- fragment(:equal_equal, first),
           tail when is_binary(tail) <- fragment(:equal_equal, second),
           [open, rest] <- String.split(rendered, head, parts: 2),
           [separator, close] <- String.split(rest, tail, parts: 2) do
        %{open: open, separator: separator, close: close}
      else
        _other -> nil
      end
    end

    @spec text_control(
            [Expression.row()],
            Expression.connective(),
            non_neg_integer(),
            Expression.row()
          ) :: map()
    defp text_control(rows, connective, index, row) do
      style = style(row)
      hole = hole(row.value_kind, style)
      template = swap(rows, connective, index, &%{&1 | value: hole})
      sentinel = fragment(row.op, hole)
      {prefix, suffix} = wrapper(row.value_kind, style)

      if usable?(template, sentinel) do
        %{
          kind: :text,
          text: text_value(row),
          template: template,
          sentinel: sentinel,
          prefix: prefix,
          suffix: suffix,
          escapes: JSON.encode!(escapes(row.value_kind, style, prefix, suffix))
        }
      else
        readonly(row)
      end
    end

    @spec usable?(String.t() | nil, String.t() | nil) :: boolean()
    defp usable?(template, sentinel) do
      is_binary(template) and is_binary(sentinel) and String.contains?(template, sentinel)
    end

    @spec readonly(Expression.row()) :: map()
    defp readonly(row), do: %{kind: :readonly, text: row.value_source}

    @spec hole(Expression.value_kind(), atom()) :: term()
    defp hole(:string, style), do: {:string, @sentinel, style}
    defp hole(_kind, _style), do: {:integer, @sentinel_integer}

    # What surrounds a typed value in the source: the quotes a string is
    # written with, read off an empty one, and nothing at all for a kind the
    # writer spells bare.
    @spec wrapper(Expression.value_kind(), atom()) :: {String.t(), String.t()}
    defp wrapper(:string, style) do
      case fragment(:equal_equal, {:string, "", style}) do
        <<prefix::binary-size(1), suffix::binary-size(1)>> -> {prefix, suffix}
        _other -> {"", ""}
      end
    end

    defp wrapper(_kind, _style), do: {"", ""}

    # The characters the writer escapes inside a string, and how, learned by
    # rendering each one on its own and reading back what came out.
    @spec escapes(Expression.value_kind(), atom(), String.t(), String.t()) :: [[String.t()]]
    defp escapes(:string, style, prefix, suffix) when prefix != "" do
      Enum.flat_map(["\\", "'", "\""], fn character ->
        with rendered when is_binary(rendered) <-
               fragment(:equal_equal, {:string, character, style}),
             true <-
               String.starts_with?(rendered, prefix) and String.ends_with?(rendered, suffix),
             inner <- unwrap(rendered, prefix, suffix),
             true <- inner != character do
          [[character, inner]]
        else
          _other -> []
        end
      end)
    end

    defp escapes(_kind, _style, _prefix, _suffix), do: []

    @spec unwrap(String.t(), String.t(), String.t()) :: String.t()
    defp unwrap(rendered, prefix, suffix) do
      rendered
      |> String.replace_prefix(prefix, "")
      |> String.replace_suffix(suffix, "")
    end

    @spec text_value(Expression.row()) :: String.t()
    defp text_value(%{value: {:string, value, _style}}), do: value
    defp text_value(row), do: row.value_source

    @spec style(Expression.row()) :: atom()
    defp style(%{value: {:string, _value, style}}), do: style
    defp style(%{value: {:list, [{:string, _value, style} | _rest]}}), do: style
    defp style(_row), do: :single

    @spec list_kind?(Expression.value_kind()) :: boolean()
    defp list_kind?({:list, _member}), do: true
    defp list_kind?(_kind), do: false

    @spec boolean_candidates() :: [map()]
    defp boolean_candidates do
      [%{label: "true", value: true}, %{label: "false", value: false}]
    end

    # The structural form of a value a host declared as a bare term. The row
    # type documents these tuples as `Predicator.Simple`'s own, kept so a
    # renderer can hand an edited row straight back to it.
    @spec term(Expression.value_kind(), atom(), term()) :: {:ok, term()} | :error
    defp term({:list, member}, style, value), do: term(member || :string, style, value)
    defp term(:string, style, value) when is_binary(value), do: {:ok, {:string, value, style}}
    defp term(:boolean, _style, value) when is_boolean(value), do: {:ok, {:boolean, value}}

    defp term(:integer, _style, value) when is_integer(value) and value >= 0,
      do: {:ok, {:integer, value}}

    defp term(:integer, _style, value) when is_binary(value) do
      case Integer.parse(value) do
        {parsed, ""} when parsed >= 0 -> {:ok, {:integer, parsed}}
        _other -> :error
      end
    end

    defp term(_kind, _style, _value), do: :error

    @spec connective_options([Expression.row()], Expression.connective(), String.t()) :: [map()]
    defp connective_options(rows, _connective, _canonical) when length(rows) < 2, do: []

    defp connective_options(rows, _connective, canonical) do
      Enum.flat_map([:and, :or], fn joiner ->
        case source(rows, joiner) do
          nil ->
            []

          written ->
            [%{label: to_string(joiner), source: written, selected: written == canonical}]
        end
      end)
    end

    # Adding a clause is one more source string, not a row appended to a
    # model: the seed clause is written into the expression and the next
    # render reads the row back out of it.
    @spec add_source([Expression.row()], Expression.connective(), [String.t()]) ::
            String.t() | nil
    defp add_source(rows, connective, paths) do
      seed = List.first(paths) || (List.first(rows) || %{}) |> Map.get(:path)

      with name when is_binary(name) <- seed,
           {:ok, segments} <- Expression.segments(name) do
        source(rows ++ [{segments, :equal_equal, {:string, "", :single}}], connective || :and)
      else
        _other -> nil
      end
    end

    @spec remove_source([Expression.row()], Expression.connective(), non_neg_integer()) ::
            String.t() | nil
    defp remove_source(rows, _connective, _index) when length(rows) < 2, do: nil

    defp remove_source(rows, connective, index) do
      rest = List.delete_at(rows, index)

      source(rest, if(length(rest) < 2, do: nil, else: connective))
    end

    @spec encode([Expression.completion()]) :: String.t()
    defp encode(completions) do
      completions
      |> Enum.map(fn completion ->
        %{
          "label" => completion.label,
          "insert" => completion.insert,
          "kind" => completion.kind,
          "detail" => completion.detail
        }
      end)
      |> JSON.encode!()
    end

    @doc """
    The hook name a host registers for the completion popup:
    `"StatifierUIExpressionInput"`.

    It is the name `assets/js/index.js` exports and the name this component
    renders as `phx-hook`, returned as a function so a host's `app.js` and a
    test can name the same string without copying it.

    ## Examples

        iex> StatifierUI.Live.ExpressionInput.hook_name()
        "StatifierUIExpressionInput"

    """
    @spec hook_name() :: String.t()
    def hook_name, do: @hook

    @doc """
    The hook name a host registers for the picklist:
    `"StatifierUIExpressionPicklist"`.

    The second of the two hooks `assets/js/index.js` exports. It is what
    copies a chosen option's source string into the field and dispatches the
    `input` event the host's form is already listening for.

    ## Examples

        iex> StatifierUI.Live.ExpressionInput.picklist_hook_name()
        "StatifierUIExpressionPicklist"

    """
    @spec picklist_hook_name() :: String.t()
    def picklist_hook_name, do: @picklist_hook
  end
else
  defmodule StatifierUI.Live.ExpressionInput do
    @moduledoc """
    Stub: the expression field needs the optional `:phoenix_live_view`
    dependency (ADR-0004).

    The completion source behind it does not - `StatifierUI.Expression` is pure
    and always compiled, so a host without LiveView can still ask what an
    expression field would offer and render it its own way.
    """

    @missing "needs the optional :phoenix_live_view dependency - add " <>
               "{:phoenix_live_view, \"~> 1.0\"} to your deps and recompile, or read the " <>
               "completions from StatifierUI.Expression directly"

    @doc "Raises: the expression field needs `:phoenix_live_view`."
    @spec expression_input(map()) :: no_return()
    def expression_input(_assigns),
      do:
        raise(
          RuntimeError,
          "StatifierUI.Live.ExpressionInput.expression_input/1 " <> @missing
        )

    @doc "The hook name a host registers for the completion popup."
    @spec hook_name() :: String.t()
    def hook_name, do: "StatifierUIExpressionInput"

    @doc "The hook name a host registers for the picklist."
    @spec picklist_hook_name() :: String.t()
    def picklist_hook_name, do: "StatifierUIExpressionPicklist"

    @doc "The display spelling of a source lexeme."
    @spec display_label(String.t()) :: String.t()
    def display_label(label) when is_binary(label) do
      if label =~ ~r/\A[A-Za-z]+\z/, do: String.downcase(label), else: label
    end
  end
end
