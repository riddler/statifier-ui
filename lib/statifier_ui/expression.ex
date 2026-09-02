defmodule StatifierUI.Expression do
  @moduledoc """
  The completion source behind the expression-editing component: predicator's
  own grammar vocabulary, plus the datamodel paths a host declares.

  This module is pure and touches no LiveView, the same split
  `StatifierUI.Live.State` gives the ops panes. `StatifierUI.Live.ExpressionInput`
  renders what `completions/2` returns; everything about *what* an author can
  be offered is decided here, where it is testable without a browser and
  without Phoenix.

  ## Two sources, and only two

  A completion is either a **declared datamodel path** - supplied by the caller,
  because only the host knows its own datamodel - or a **lexeme of the
  predicator grammar**, read from `Predicator.Vocabulary` (px-15q). Nothing is
  invented here. An operator this module offered that the lexer does not accept
  would be a second, drifting copy of the grammar, which is precisely the
  duplication `Predicator.Vocabulary` was published to prevent.

  ## The grammar half degrades

  `Predicator.Vocabulary` is newer than the predicator releases this package
  can resolve, so its absence is a supported state rather than a broken one: a
  host on an older predicator gets its declared paths and no grammar entries,
  and the component renders a plain input with a path list. The module is
  reached through `Application.get_env(:statifier_ui, :predicator_vocabulary,
  Predicator.Vocabulary)` and guarded with `Code.ensure_loaded?/1`, so nothing
  raises and nothing warns at compile time.

  ## Shape

  Every completion is a map with four keys:

  - `:label` - what a completion list shows (`"len(...)"`, `"contains"`)
  - `:insert` - the text written into the source at the caret
  - `:kind` - `"path"`, `"function"`, or the px category of a lexeme
    (`"comparison"`, `"logical"`, ...), which is what a list groups by
  - `:detail` - one line of prose, or `nil` when the source carries none

  ## Examples

      iex> StatifierUI.Expression.completions(["order.total"])
      ...> |> Enum.find(&(&1.insert == "order.total"))
      %{label: "order.total", insert: "order.total", kind: "path", detail: "declared path"}

  """

  @typedoc "One offer: what to show, what to write, how to group it."
  @type completion :: %{
          label: String.t(),
          insert: String.t(),
          kind: String.t(),
          detail: String.t() | nil
        }

  @default_vocabulary Predicator.Vocabulary

  @doc """
  Every completion available to an expression field: the declared paths first,
  then the grammar.

  `candidates` is the declared datamodel path list - what
  `StatifierBlocks.Datamodel.candidates/3` returns, arriving through the
  `expression_component` seam as `:candidates`. Paths lead because they are the
  ones an author cannot look up.

  `opts` is passed through to `Predicator.Vocabulary.functions/1`, so a host
  with its own `Predicator.FunctionProvider` modules offers exactly the
  functions its own contexts will accept.

  ## Examples

      iex> StatifierUI.Expression.completions() |> Enum.any?(&(&1.insert == ">="))
      true

      iex> StatifierUI.Expression.completions([], builtins: false)
      ...> |> Enum.any?(&(&1.kind == "function"))
      false

  """
  @spec completions([String.t()], keyword()) :: [completion()]
  def completions(candidates \\ [], opts \\ []) do
    Enum.map(candidates, &path_completion/1) ++ grammar(opts)
  end

  @doc """
  The subset a native `<datalist>` can usefully offer: the word-shaped
  completions.

  A `<datalist>` filters its options against the whole field value, and it
  cannot insert at a caret. Offering `"::"` or `"("` through one is noise, so
  the no-JavaScript affordance carries paths, keywords, and function names and
  leaves the symbol operators to the hook.

  ## Examples

      iex> StatifierUI.Expression.completions() |> StatifierUI.Expression.datalist()
      ...> |> Enum.any?(&(&1.insert == "::"))
      false

  """
  @spec datalist([completion()]) :: [completion()]
  def datalist(completions) do
    Enum.filter(completions, &word_shaped?/1)
  end

  @doc """
  Whether the resolved predicator exposes `Predicator.Vocabulary`.

  The component stamps this on the rendered input so a host - or a test - can
  tell "no grammar completions offered" from "grammar completions offered and
  none matched".

  ## Examples

      iex> is_boolean(StatifierUI.Expression.vocabulary_available?())
      true

  """
  @spec vocabulary_available?() :: boolean()
  def vocabulary_available? do
    module = vocabulary_module()

    Code.ensure_loaded?(module) and
      function_exported?(module, :tokens, 0) and
      function_exported?(module, :functions, 1)
  end

  @spec grammar(keyword()) :: [completion()]
  defp grammar(opts) do
    if vocabulary_available?() do
      module = vocabulary_module()

      Enum.map(module.tokens(), &token_completion/1) ++
        Enum.map(module.functions(opts), &function_completion/1)
    else
      []
    end
  end

  # Resolved at call time rather than at compile time: the point is to survive
  # a host whose predicator is older than the module, and a compile-time alias
  # would have decided that question on this package's own dependency tree.
  @spec vocabulary_module() :: module()
  defp vocabulary_module do
    Application.get_env(:statifier_ui, :predicator_vocabulary, @default_vocabulary)
  end

  @spec path_completion(String.t()) :: completion()
  defp path_completion(path) do
    %{label: path, insert: path, kind: "path", detail: "declared path"}
  end

  @spec token_completion(map()) :: completion()
  defp token_completion(entry) do
    %{
      label: entry.display,
      insert: entry.lexeme,
      kind: to_string(entry.category),
      detail: entry.doc
    }
  end

  # A function's insert carries the opening paren: completing `len` to `len(`
  # leaves the caret where the argument goes, and the display already says the
  # call is a call.
  @spec function_completion(map()) :: completion()
  defp function_completion(entry) do
    %{
      label: entry.display,
      insert: entry.lexeme <> "(",
      kind: "function",
      detail: arity_detail(entry.arity)
    }
  end

  @spec arity_detail(non_neg_integer() | [non_neg_integer()]) :: String.t()
  defp arity_detail(arity) when is_integer(arity), do: "#{arity}-argument function"

  defp arity_detail(arities) when is_list(arities) do
    "function of #{Enum.map_join(Enum.sort(arities), " or ", &to_string/1)} arguments"
  end

  @spec word_shaped?(completion()) :: boolean()
  defp word_shaped?(%{insert: insert}), do: insert =~ ~r/\A[A-Za-z_]/
end
