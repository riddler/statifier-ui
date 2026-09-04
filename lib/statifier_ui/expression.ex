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

  ## The picklist half

  `simple/2` answers a second question about a source string: not "what could
  be typed next" but "can a row of dropdowns draw this at all". It reads
  `Predicator.Simple` (px-84i), the upstream module that names the
  picklist-renderable subset, and returns the clause rows a renderer walks.

  The three answers `Predicator.Simple.from_source/1` keeps apart are kept
  apart here too, because an editor needs all three: source inside the subset,
  a valid expression outside it, and text that is not an expression at all.
  Collapsing the middle one into an error would tell an author their working
  condition is broken.

  `Predicator.Simple` degrades exactly as `Predicator.Vocabulary` does, through
  `Application.get_env(:statifier_ui, :predicator_simple, Predicator.Simple)`
  and a `Code.ensure_loaded?/1` guard. A host on an older predicator gets
  `:outside` for every source string, which is the answer that makes the
  component fall back to its plain text input.

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

  @typedoc """
  The connective joining a picklist's clause rows.

  `nil` for a single row, which is joined to nothing - the same invariant
  `Predicator.Simple` carries.
  """
  @type connective :: :and | :or | nil

  @typedoc """
  What kind of value a clause row holds, which is what decides its operator
  list and its value control.

  A list carries the kind of its members, or `nil` when it is empty.
  """
  @type value_kind ::
          :integer
          | :boolean
          | :string
          | :date
          | :datetime
          | :duration
          | :relative_date
          | {:list, value_kind() | nil}

  @typedoc """
  One entry in an operator dropdown: the atom to build a clause with, the
  source spelling `Predicator.Simple.to_source/1` writes for it, and the
  grammar's own one-line description when `Predicator.Vocabulary` is resolvable.
  """
  @type operator :: %{op: atom(), label: String.t(), detail: String.t() | nil}

  @typedoc "One offer in a value dropdown, as the host declared it."
  @type candidate :: %{label: String.t(), value: term()}

  @typedoc """
  One row of the picklist: everything a renderer needs to draw a
  field / operator / value line, and nothing it would have to compute itself.

  `:segments` and `:value` are `Predicator.Simple`'s own structural forms, kept
  so a renderer can hand an edited row straight back to
  `Predicator.Simple.to_ast/1`; `:path`, `:op_label`, and `:value_source` are
  the same three things spelled the way the source spells them.
  """
  @type row :: %{
          path: String.t(),
          segments: [tuple()],
          op: atom(),
          op_label: String.t(),
          value: term(),
          value_kind: value_kind(),
          value_source: String.t(),
          operators: [operator()],
          candidates: [candidate()]
        }

  @default_vocabulary Predicator.Vocabulary
  @default_simple Predicator.Simple

  # Which operators a value of each kind can carry. This is the one thing here
  # that is decided locally rather than read from predicator: the grammar knows
  # every operator, but not which of them a picklist should offer beside an
  # integer as opposed to a date. `Predicator.Simple.operators/1` (px-84i's
  # second half) will own this table upstream; when it lands, `operators/1`
  # below should delegate to it and this attribute should go.
  #
  # `:in` appears only for a list, because its right-hand side is a list, and
  # `:contains` only beside a scalar, because its left-hand side is the
  # collection.
  @ordered_ops %{
    string: [:equal_equal, :ne, :strict_eq, :strict_ne, :contains],
    integer: [:equal_equal, :ne, :gt, :gte, :lt, :lte],
    boolean: [:equal_equal, :ne],
    date: [:equal_equal, :ne, :gt, :gte, :lt, :lte],
    datetime: [:equal_equal, :ne, :gt, :gte, :lt, :lte],
    duration: [:equal_equal, :ne, :gt, :gte, :lt, :lte],
    relative_date: [:equal_equal, :ne, :gt, :gte, :lt, :lte]
  }

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

  @doc """
  Classifies a source string against the picklist-renderable subset.

  Three answers, and they are three different questions:

  - `{:ok, rows, connective}` - inside the subset. `rows` is one `t:row/0` per
    clause and `connective` is `nil` for a single row, `:and` or `:or` for two
    or more.
  - `:outside` - a valid expression a picklist cannot draw. Offer the text
    editor; this is not an error.
  - `{:error, error}` - the source does not parse, carrying predicator's own
    parse error with the position of the failure.

  `opts` takes `:value_candidates` - a map from a clause's `:path` to the
  values a host offers for it, as `t:candidate/0` maps or bare strings. Only
  the host knows its own value sets, so nothing is inferred here; a path with
  no entry gets an empty list and the renderer falls back to a free-text value
  control.

  When the resolved predicator has no `Predicator.Simple`, every source string
  answers `:outside`. That is a degraded answer rather than a wrong one: the
  component renders the text input it would render for an unsupported
  expression.

  ## Examples

      iex> {:ok, [row], nil} = StatifierUI.Expression.simple("plan == 'pro'")
      iex> {row.path, row.op, row.value_source}
      {"plan", :equal_equal, "'pro'"}

      iex> {:ok, rows, connective} = StatifierUI.Expression.simple("status == 'active' AND amount >= 500")
      iex> {length(rows), connective}
      {2, :and}

      iex> StatifierUI.Expression.simple("status == 'active' AND (amount >= 500 OR plan == 'pro')")
      :outside

      iex> {:error, error} = StatifierUI.Expression.simple("amount >= >=")
      iex> error.position
      {1, 11}

      iex> {:ok, [row], nil} =
      ...>   StatifierUI.Expression.simple("step in ['payment', 'review']",
      ...>     value_candidates: %{"step" => ["payment", "review", "confirmation"]}
      ...>   )
      iex> {row.value_kind, Enum.map(row.candidates, & &1.value)}
      {{:list, :string}, ["payment", "review", "confirmation"]}

  """
  @spec simple(String.t(), keyword()) ::
          {:ok, [row()], connective()} | :outside | {:error, term()}
  def simple(source, opts \\ []) when is_binary(source) do
    if simple_available?() do
      classify(simple_module(), source, Keyword.get(opts, :value_candidates, %{}))
    else
      :outside
    end
  end

  @doc """
  The operators a picklist offers beside a value of the given kind.

  The atom is what a clause is built with and the label is the spelling
  `Predicator.Simple.to_source/1` writes for it, so an author who picks an
  operator sees the same text the expression will carry. `:detail` is the
  grammar's own one-line description, or `nil` when `Predicator.Vocabulary` is
  not resolvable.

  Empty when `Predicator.Simple` is absent, for the same reason `simple/2`
  answers `:outside`: there is nothing truthful to offer.

  ## Examples

      iex> StatifierUI.Expression.operators(:boolean) |> Enum.map(& &1.op)
      [:equal_equal, :ne]

      iex> StatifierUI.Expression.operators({:list, :string}) |> Enum.map(& &1.label)
      ["IN"]

      iex> StatifierUI.Expression.operators(:integer) |> Enum.map(& &1.label)
      ["==", "!=", ">", ">=", "<", "<="]

  """
  @spec operators(value_kind()) :: [operator()]
  def operators(value_kind) do
    if simple_available?() do
      module = simple_module()
      Enum.map(ops_for(value_kind), &operator(module, &1))
    else
      []
    end
  end

  @doc """
  The values a host offers for one clause path, normalized.

  `candidates` is `simple/2`'s `:value_candidates` map. An entry may be a
  `t:candidate/0` map or a bare string, because a declared path list is
  usually already a list of strings and making a caller wrap each one buys
  nothing.

  `simple/2` folds this into every row it returns. It is public because a
  renderer adding a *new* row has a path with no clause behind it yet, and
  still needs its value list.

  ## Examples

      iex> StatifierUI.Expression.value_candidates(%{"step" => ["payment", "review"]}, "step")
      [%{label: "payment", value: "payment"}, %{label: "review", value: "review"}]

      iex> StatifierUI.Expression.value_candidates(%{}, "plan")
      []

  """
  @spec value_candidates(%{optional(String.t()) => [candidate() | String.t()]}, String.t()) ::
          [candidate()]
  def value_candidates(candidates, path) when is_map(candidates) do
    candidates |> Map.get(path, []) |> Enum.map(&candidate/1)
  end

  @doc """
  Whether the resolved predicator exposes `Predicator.Simple`.

  The counterpart to `vocabulary_available?/0`, and the same distinction: a
  component stamps it so a host can tell "this expression is outside the
  subset" from "this predicator cannot answer the question".

  ## Examples

      iex> is_boolean(StatifierUI.Expression.simple_available?())
      true

  """
  @spec simple_available?() :: boolean()
  def simple_available? do
    module = simple_module()

    Code.ensure_loaded?(module) and
      function_exported?(module, :from_source, 1) and
      function_exported?(module, :to_source, 1)
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

  # Resolved at call time for the reason vocabulary_module/0 is: the host's
  # predicator, not this package's, decides whether the module is there.
  @spec simple_module() :: module()
  defp simple_module do
    Application.get_env(:statifier_ui, :predicator_simple, @default_simple)
  end

  @spec classify(module(), String.t(), map()) ::
          {:ok, [row()], connective()} | :outside | {:error, term()}
  defp classify(module, source, candidates) do
    case module.from_source(source) do
      {:ok, %{connective: connective, clauses: clauses}} ->
        {:ok, Enum.map(clauses, &row(module, &1, candidates)), connective}

      :outside ->
        :outside

      {:error, error} ->
        {:error, error}
    end
  end

  @spec row(module(), {[tuple()], atom(), term()}, map()) :: row()
  defp row(module, {segments, op, value}, candidates) do
    path = path_source(module, segments)
    kind = value_kind(value)

    %{
      path: path,
      segments: segments,
      op: op,
      op_label: operator_label(module, op),
      value: value,
      value_kind: kind,
      value_source: value_source(module, op, value),
      operators: Enum.map(ops_for(kind), &operator(module, &1)),
      candidates: value_candidates(candidates, path)
    }
  end

  # Every spelling below is asked of `Predicator.Simple.to_source/1` rather
  # than written out here, so a picklist never shows text the writer would not
  # produce. That is the same rule the completion half follows for lexemes: one
  # copy of the grammar, and it lives in predicator.
  @spec clause_source(module(), {[tuple()], atom(), term()}) :: String.t()
  defp clause_source(module, clause) do
    module |> struct(connective: nil, clauses: [clause]) |> module.to_source()
  end

  @spec operator_label(module(), atom()) :: String.t()
  defp operator_label(module, op) do
    [_root, label | _rest] =
      module
      |> clause_source({[{:root, "x"}], op, probe_value(op)})
      |> String.split(" ", parts: 3)

    label
  end

  # `:in` is the one operator whose right-hand side must be a list, so the
  # probe clause it is spelled through carries one.
  @spec probe_value(atom()) :: term()
  defp probe_value(:in), do: {:list, [{:integer, 0}]}
  defp probe_value(_op), do: {:integer, 0}

  @spec path_source(module(), [tuple()]) :: String.t()
  defp path_source(module, segments) do
    suffix = " " <> operator_label(module, :equal_equal) <> " 0"

    module
    |> clause_source({segments, :equal_equal, {:integer, 0}})
    |> String.replace_suffix(suffix, "")
  end

  @spec value_source(module(), atom(), term()) :: String.t()
  defp value_source(module, op, value) do
    prefix = "x " <> operator_label(module, op) <> " "

    module
    |> clause_source({[{:root, "x"}], op, value})
    |> String.replace_prefix(prefix, "")
  end

  @spec operator(module(), atom()) :: operator()
  defp operator(module, op) do
    label = operator_label(module, op)
    %{op: op, label: label, detail: lexeme_detail(label)}
  end

  @spec lexeme_detail(String.t()) :: String.t() | nil
  defp lexeme_detail(lexeme) do
    if vocabulary_available?() do
      case Enum.find(vocabulary_module().tokens(), &(&1.lexeme == lexeme)) do
        nil -> nil
        entry -> entry.doc
      end
    end
  end

  @spec ops_for(value_kind()) :: [atom()]
  defp ops_for({:list, _member_kind}), do: [:in]
  defp ops_for(kind), do: Map.get(@ordered_ops, kind, [])

  @spec value_kind(term()) :: value_kind()
  defp value_kind({:list, []}), do: {:list, nil}
  defp value_kind({:list, [first | _rest]}), do: {:list, value_kind(first)}
  defp value_kind({:integer, _value}), do: :integer
  defp value_kind({:boolean, _value}), do: :boolean
  defp value_kind({:string, _value, _style}), do: :string
  defp value_kind({:date, _value}), do: :date
  defp value_kind({:datetime, _value}), do: :datetime
  defp value_kind({:duration, _units}), do: :duration
  defp value_kind({:relative_date, _units, _direction}), do: :relative_date

  @spec candidate(candidate() | String.t()) :: candidate()
  defp candidate(%{label: label, value: value}), do: %{label: label, value: value}
  defp candidate(value) when is_binary(value), do: %{label: value, value: value}

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
