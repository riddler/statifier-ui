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
    """

    use Phoenix.Component

    alias StatifierUI.Expression

    @hook "StatifierUIExpressionInput"

    attr(:id, :string, required: true, doc: "DOM id of the input itself.")
    attr(:name, :string, required: true, doc: "form field name; the host's form owns the event.")
    attr(:value, :string, default: "", doc: "the expression source.")

    attr(:candidates, :list,
      default: [],
      doc: "declared datamodel paths, from the host. Offered ahead of the grammar."
    )

    attr(:hook, :string,
      default: @hook,
      doc: "`phx-hook` name; `nil` renders the datalist-only field."
    )

    attr(:placeholder, :string, default: "an expression")
    attr(:class, :string, default: nil)

    attr(:vocabulary_opts, :list,
      default: [],
      doc: "passed to `Predicator.Vocabulary.functions/1` - a host's own providers."
    )

    attr(:field, :any, default: nil, doc: "accepted from the sb seam and never read.")

    @doc """
    The field: an input, its completion data, and the no-JavaScript datalist.

    See the module doc for the seam this is written against and for what the
    rendered element stamps.
    """
    @spec expression_input(map()) :: Phoenix.LiveView.Rendered.t()
    def expression_input(assigns) do
      assigns = normalize(assigns)

      ~H"""
      <div class={["statifier-ui-expression", @class]} id={@id <> "-expression"}>
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
          data-completions={@completions_json}
          data-completion-count={length(@completions)}
          data-candidates={length(@candidates)}
          data-vocabulary={to_string(@vocabulary?)}
        />
        <datalist id={@list_id}>
          <option :for={completion <- @datalist} value={completion.insert}>
            {completion.detail}
          </option>
        </datalist>
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
      |> Map.put_new(:hook, @hook)
      |> Map.put_new(:placeholder, "an expression")
      |> Map.put_new(:class, nil)
      |> Map.put_new(:vocabulary_opts, [])
      |> Map.put_new(:field, nil)
      |> put_completions()
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
  end
end
