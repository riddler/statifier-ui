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

    The two switches sit in a `statifier-ui-expression-modes` container, and
    that container is the one element in this package that carries a style of
    its own: an inline `display: inline-flex; gap: 0.5rem`. HEEx drops the
    whitespace between two adjacent elements, so on a host page with no
    stylesheet the two buttons abutted and read as one run-together phrase
    (sui-aln). The default is layout only - no colour, no font, no token to
    reconcile with a host's palette, so the theming contract in
    `docs/ops-embedding.md` still holds. A host restyles the container through
    the class as usual; because the default is an attribute it wins on
    specificity, so a rule that replaces `display` or `gap` rather than adding
    to them needs `!important`.

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
    them, and no longer cases one either: every operator option it renders
    carries the grammar's `:label` verbatim, so one spelling of a display
    phrase exists in the system and it is the vocabulary's. The
    `display_label/1` that used to lowercase a word-shaped lexeme is gone with
    the job it did (sui-ne0). Its one caller was `op_options/5` here; the
    grammar's phrases are already display-cased, and every one of them is
    either multi-word or already lowercase, so it returned every label it
    could be handed unchanged.

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
    | `data-declared-kind` | a clause row | the kind the host declared for its path (`integer`, `list:string`, `one-of`, ...), absent when none |
    | `data-advisory` | an advisory row | `value-kind` or `operator`, why it is shown |
    | `data-severity` | an advisory row | `info` - an advisory never blocks |

    ## What a declaration does and does not do

    A `:path_types` entry decides three things: which operators the row offers
    (asked of `StatifierUI.Expression.operators/1`, the same grammar call an
    observed kind goes through), which control is drawn, when the value's
    own shape agrees with the declaration, and what literal a *new* row is
    seeded with. It never rewrites the author's source: the operator the source
    carries is always offered even when the declared kind's list would drop it,
    the value in the source is always kept and selected, and a scalar value is
    never handed a list control (or the reverse). When the declaration and the
    source disagree, an advisory row renders beside the clause and nothing
    about the source changes.

    Seeding is the one place a declaration writes rather than describes, and it
    writes only where there was nothing: the row the "add clause" button
    creates. A row seeded with `''` on a path declared a number would arrive
    carrying an advisory about itself, which is a declaration telling an author
    off for the shape it chose (sui-loj). So a declared number seeds `0`, a
    boolean `true`, a date today, a datetime midnight today, a duration `1d`, a
    `{:one_of, _}` its first value, and a list declaration seeds a `CONTAINS`
    clause holding one member. A path with no declaration - and a `{:list, nil}`
    that names no member kind - keeps the empty string this component always
    seeded.

    ## Two ways to declare, and the map wins

    A host that has a datamodel *document* may hand it over as `:document`
    instead of projecting it itself: the component asks
    `StatifierDatamodel.Index.path_types/1` for the same `path -> kind` map
    that record defines, and uses it wherever a `:path_types` map was not
    supplied. A non-empty `:path_types` wins whole, because a host that
    supplies both has said the more specific thing.

    The projection's vocabulary *is* this component's `:path_types` vocabulary,
    so nothing is translated between them - which is why
    `t:StatifierUI.Expression.declared_kind/0` admits `:number`, the tag that
    projection answers for a document's `integer` and `decimal` alike.
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
    # The seed a row starts life with when nothing narrower is declared: the
    # empty single-quoted string, which is what every fresh clause held before
    # a declaration could shape one.
    @string_seed {:string, "", :single}

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

    attr(:path_types, :map,
      default: %{},
      doc:
        "kinds the host declares per clause path, as `%{path => kind | {:list, kind} | " <>
          "{:one_of, values}}`. A declared kind decides the operator list and the value " <>
          "control; it never rewrites the author's source."
    )

    attr(:document, :map,
      default: nil,
      doc:
        "a decoded datamodel document. Its `StatifierDatamodel.Index.path_types/1` " <>
          "projection supplies `:path_types` when the host declares none directly; " <>
          "a non-empty `:path_types` wins over it."
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
            data-declared-kind={clause.declared_kind}
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
            <p
              :for={advisory <- clause.advisories}
              class="statifier-ui-expression-advisory"
              role="status"
              data-advisory={advisory_reason(advisory.reason)}
              data-severity={advisory.severity}
            >
              {advisory.message}
            </p>
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
        <div
          :if={@picklist_hook}
          class="statifier-ui-expression-modes"
          style="display: inline-flex; gap: 0.5rem"
        >
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
      |> Map.put_new(:path_types, %{})
      |> Map.put_new(:document, nil)
      |> put_path_types()
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

    # A host may declare its paths' kinds directly, hand over the datamodel
    # document they were declared in, or both. The document is projected
    # through `StatifierDatamodel.Index.path_types/1` rather than read here:
    # sd owns the document's shape, and a second reading of it in this package
    # would be the drifting copy the completion source already refuses for the
    # grammar. The projection's vocabulary IS the `:path_types` vocabulary -
    # `t:StatifierUI.Expression.declared_kind/0` admits its `:number` - so
    # nothing is translated on the way in.
    #
    # A non-empty `:path_types` wins whole: a host that supplies both has said
    # the more specific thing, and merging the two per path would leave it
    # unable to say "these paths and no others" about a document that declares
    # more. An empty map is not a statement, so it falls through to the
    # document.
    @spec put_path_types(map()) :: map()
    defp put_path_types(%{path_types: declared} = assigns) when declared != %{}, do: assigns

    defp put_path_types(assigns) do
      Map.put(assigns, :path_types, document_path_types(assigns.document))
    end

    @spec document_path_types(term()) :: map()
    defp document_path_types(nil), do: %{}

    defp document_path_types(document) do
      document |> StatifierDatamodel.Index.index() |> StatifierDatamodel.Index.path_types()
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
      |> Map.put(
        :add_source,
        picklist? && add_source(rows, connective, paths, assigns.path_types)
      )
    end

    @spec classify(map()) ::
            {String.t(), [Expression.row()], Expression.connective(), map() | nil}
    defp classify(assigns) do
      case Expression.simple(assigns.value,
             value_candidates: assigns.value_candidates,
             path_types: assigns.path_types
           ) do
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
          remove_source: remove_source(rows, connective, index),
          declared_kind: declared_kind_attribute(row.declared_kind),
          advisories: row.advisories
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
                label: operator.label,
                detail: operator.detail,
                source: written,
                selected: written == canonical
              }
            ]
        end
      end)
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
        list_kind?(row.control_kind) and row.candidates != [] ->
          multiselect(rows, connective, index, row)

        list_kind?(row.control_kind) ->
          readonly(row)

        row.candidates != [] ->
          value_select(rows, connective, canonical, index, row, row.candidates)

        row.control_kind == :boolean ->
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
          with {:ok, term} <- term(option_kind(row), style(row), candidate.value),
               written when is_binary(written) <-
                 swap(rows, connective, index, &%{&1 | value: term}) do
            [%{label: candidate.label, source: written, selected: written == canonical}]
          else
            _other -> []
          end
        end)

      %{kind: :select, options: keep_current(options, canonical, row)}
    end

    # A `{:one_of, _}` row's control kind is the kind of the value it happens
    # to hold, because the declaration says only that it is one of the list. A
    # list mixing the grammar's two numeric literals is therefore read through
    # whichever of the two the author's own value is, and every option of the
    # other spelling drops out. The options of such a select are the
    # declaration's own and both literals are spellable, so the numeric kinds
    # are asked as `:number` while the list is built. Only the list widens -
    # `control_kind` is untouched, so no control changes shape and no data
    # attribute moves (sui-9ik).
    @spec option_kind(Expression.row()) :: Expression.value_kind()
    defp option_kind(%{declared_kind: {:one_of, _values}, control_kind: kind}), do: widen(kind)
    defp option_kind(row), do: row.control_kind

    @spec widen(Expression.value_kind()) :: Expression.value_kind()
    defp widen({:list, member}), do: {:list, widen(member)}
    defp widen(kind) when kind in [:integer, :float], do: :number
    defp widen(kind), do: kind

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
          with {:ok, term} <- term(option_kind(row), style, candidate.value),
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

    # These four measure how the current value is spelled, not what kind the
    # host declared for its path - a hole, a wrapper, an escape table, and the
    # text shown all describe the value that is actually there, so they read
    # `row.value_kind` even where the control cascade above reads
    # `row.control_kind`.
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

    # The declaration as one word, because an attribute is a string: a list
    # says what it is a list of, and a one_of says only that it is one - the
    # values themselves are already the options of the select beside it.
    @spec declared_kind_attribute(Expression.declared_kind() | nil) :: String.t() | nil
    defp declared_kind_attribute(nil), do: nil
    defp declared_kind_attribute({:one_of, _values}), do: "one-of"
    defp declared_kind_attribute({:list, nil}), do: "list"
    defp declared_kind_attribute({:list, member}), do: "list:" <> to_string(member)
    defp declared_kind_attribute(kind), do: to_string(kind)

    # The atom is the module's word and the attribute is the DOM's. Spelling
    # the two apart here keeps `data-advisory` in the same hyphenated
    # vocabulary as `data-value-kind` and `data-error-position`.
    @spec advisory_reason(:value_kind | :operator) :: String.t()
    defp advisory_reason(:value_kind), do: "value-kind"
    defp advisory_reason(:operator), do: "operator"

    @spec boolean_candidates() :: [map()]
    defp boolean_candidates do
      [%{label: "true", value: true}, %{label: "false", value: false}]
    end

    # The structural form of a value a host declared as a bare term. The row
    # type documents these tuples as `Predicator.Simple`'s own, kept so a
    # renderer can hand an edited row straight back to it.
    @spec term(Expression.value_kind(), atom(), term()) :: {:ok, term()} | :error
    defp term({:list, member}, style, value), do: term(member || :string, style, value)

    # A relative date has no bare-term spelling to build from - `30d ago` is a
    # tuple in the subset's own vocabulary - so a candidate carrying one is
    # already in the form a clause holds. This is the only pre-built value the
    # component accepts, and it is accepted for exactly that reason.
    defp term(_kind, _style, {:relative_date, _units, _direction} = value), do: {:ok, value}

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

    # `:float` is not a declaration the datamodel projection ever writes - its
    # kinds stop at `:number` - but it is a kind a row is genuinely in, because
    # `control_kind/2` hands a `{:one_of, _}` row the kind of the value it
    # actually holds, and a host enumerating floats gets `:float` there. Without
    # this clause every option of such a select failed to spell itself and the
    # list rendered with the author's own value alone (sui-p2g).
    defp term(:float, _style, value) when is_float(value), do: {:ok, {:float, value}}

    # The datamodel projection's `:number` covers both of the grammar's numeric
    # literals, so a candidate offered beside such a path is spelled as
    # whichever of the two it is.
    defp term(:number, _style, value) when is_float(value), do: {:ok, {:float, value}}
    defp term(:number, style, value), do: term(:integer, style, value)

    # A row observed as `:float` is still beside a list whose other entries may
    # be the grammar's integer literal, so `:float` delegates the rest exactly
    # as `:number` does. Nothing else reaches this clause: the datamodel
    # projection never writes `:float`, so the only kind widened here is one an
    # observed value produced (sui-9ik).
    defp term(:float, style, value), do: term(:integer, style, value)

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
    @spec add_source([Expression.row()], Expression.connective(), [String.t()], map()) ::
            String.t() | nil
    defp add_source(rows, connective, paths, path_types) do
      seed = List.first(paths) || (List.first(rows) || %{}) |> Map.get(:path)

      with name when is_binary(name) <- seed,
           {:ok, segments} <- Expression.segments(name) do
        {op, value} = seed_clause(Map.get(path_types, name))

        source(rows ++ [{segments, op, value}], connective || :and)
      else
        _other -> nil
      end
    end

    # The seed clause for a declared kind: the operator and the literal a
    # fresh row starts life holding.
    #
    # The rule is one sentence - *a new row must not be born carrying an
    # advisory about itself* (sui-loj). A row seeded with `''` on a path the
    # host declared a number is wrong the instant it is drawn, and the author
    # is told so by the very declaration that should have shaped it. So every
    # kind whose literal this component can write gets its own seed, and the
    # operator is chosen with it: `CONTAINS` for a list declaration, because
    # it is the one operator whose expected kind on a declared list is a
    # member of it (`IN` expects a list *of* the declaration), and `==` for
    # every scalar, which `Predicator.Simple.operators/1` offers beside all of
    # them.
    #
    # The seeds are the emptiest value of each kind that can still be spelled:
    # zero, `true`, the empty string, today, midnight today, one day. A seed is
    # a starting point an author overwrites, not a guess at their data.
    #
    # THE FALLBACK: an unrecognised declaration, and a `{:list, nil}` whose
    # declaration names no member kind, keep today's `== ''` seed. There is no
    # advisory-free seed for a member kind the host did not name, and inventing
    # one would be this module guessing at a declaration rather than reading
    # it. A path with no declaration at all takes the same branch, which is why
    # an undeclared editor renders exactly what it rendered before.
    @spec seed_clause(Expression.declared_kind() | nil) :: {atom(), term()}
    defp seed_clause({:one_of, values}) do
      case one_of_seed(values) do
        {:ok, value} -> {:equal_equal, value}
        :error -> {:equal_equal, @string_seed}
      end
    end

    defp seed_clause({:list, member}) when member != nil do
      {_op, value} = seed_clause(member)

      {:contains, value}
    end

    # `:number` is the datamodel projection's tag for both `integer` and
    # `decimal`; an integer literal is the one both can be compared against
    # without the value advisory reading them apart.
    defp seed_clause(kind) when kind in [:integer, :number], do: {:equal_equal, {:integer, 0}}
    defp seed_clause(:float), do: {:equal_equal, {:float, 0.0}}
    defp seed_clause(:boolean), do: {:equal_equal, {:boolean, true}}
    defp seed_clause(:date), do: {:equal_equal, {:date, Date.utc_today()}}

    defp seed_clause(:datetime),
      do: {:equal_equal, {:datetime, DateTime.new!(Date.utc_today(), ~T[00:00:00])}}

    defp seed_clause(:duration), do: {:equal_equal, {:duration, [{1, "d"}]}}
    defp seed_clause(:relative_date), do: {:equal_equal, {:relative_date, [{1, "d"}], :ago}}
    defp seed_clause(_unseedable), do: {:equal_equal, @string_seed}

    # A `{:one_of, _}` row is seeded with the host's own first value, so the
    # select beside it opens with an option selected rather than with a value
    # the enumeration does not contain. A value that has no literal spelling -
    # a negative integer, a tuple, a struct - falls back with the rest.
    @spec one_of_seed([term()]) :: {:ok, term()} | :error
    defp one_of_seed([first | _rest]), do: first |> candidate_value() |> seed_scalar()
    defp one_of_seed(_empty), do: :error

    @spec candidate_value(term()) :: term()
    defp candidate_value(%{value: value}), do: value
    defp candidate_value(value), do: value

    @spec seed_scalar(term()) :: {:ok, term()} | :error
    defp seed_scalar(value) when is_binary(value), do: {:ok, {:string, value, :single}}
    defp seed_scalar(value) when is_boolean(value), do: {:ok, {:boolean, value}}
    defp seed_scalar(value) when is_integer(value) and value >= 0, do: {:ok, {:integer, value}}
    defp seed_scalar(value) when is_float(value), do: {:ok, {:float, value}}
    defp seed_scalar(_unspellable), do: :error

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
  end
end
