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

  `Predicator.Simple` is resolved the way `Predicator.Vocabulary` is, through
  `Application.get_env(:statifier_ui, :predicator_simple, Predicator.Simple)`,
  but the guard on it is wider than a `Code.ensure_loaded?/1`:
  `simple_available?/0` also requires the resolved module to export
  `from_source/1`, `to_source/1`, `operators/1` and `value_kind/1`. A host on
  an older predicator - or one that points that key at a module missing any of
  the four - gets `:outside` for every source string, an empty operator list, and
  `:error` from the three writing functions, which is the answer that makes
  the component fall back to its plain text input.

  ## Shape

  Every completion is a map with four keys:

  - `:label` - what a completion list shows (`"len(...)"`, `"contains"`)
  - `:insert` - the text written into the source at the caret
  - `:kind` - `"path"`, `"function"`, or the px category of a lexeme
    (`"comparison"`, `"logical"`, ...), which is what a list groups by
  - `:detail` - one line of prose, or `nil` when the source carries none

  ## Examples

      iex> StatifierUI.Expression.completions(["card.brand"])
      ...> |> Enum.find(&(&1.insert == "card.brand"))
      %{label: "card.brand", insert: "card.brand", kind: "path", detail: "declared path"}

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

  These are the shapes a clause value takes, which is not the vocabulary
  `Predicator.Vocabulary.value_kinds/0` names: it has one `:number` where
  this has `:integer` and `:float`, and no `:relative_date` at all.
  `operators/1` translates between the two, and nothing else needs to.
  """
  @type value_kind ::
          :integer
          | :float
          | :boolean
          | :string
          | :date
          | :datetime
          | :duration
          | :relative_date
          | {:list, value_kind() | nil}

  @typedoc """
  One entry in an operator dropdown, as `Predicator.Simple.operators/1`
  answers it.

  `:op` is the atom a clause is built with and `:lexeme` is the source
  spelling `Predicator.Simple.to_source/1` writes for it - the two halves
  that have to agree, and the reason a picklist can offer an operator
  without spelling one itself. `:label` is the grammar's own display phrase
  (`"is at least"` for `">="`), a UI string that is never stored, and
  `:detail` its one-line description, or `nil` when `Predicator.Vocabulary`
  is not resolvable.
  """
  @type operator :: %{
          op: atom(),
          lexeme: String.t(),
          label: String.t(),
          detail: String.t() | nil
        }

  @typedoc "One offer in a value dropdown, as the host declared it."
  @type candidate :: %{label: String.t(), value: term()}

  @typedoc """
  One row of the picklist: everything a renderer needs to draw a
  field / operator / value line, and nothing it would have to compute itself.

  `:segments` and `:value` are `Predicator.Simple`'s own structural forms, kept
  so a renderer can hand an edited row straight back to
  `Predicator.Simple.to_ast/1`; `:path`, `:op_label`, and `:value_source` are
  the same three things spelled the way the source spells them.

  `:op_label` is therefore a source spelling, which is the one place in this
  module where "label" means the opposite of what it means next door: on
  `t:operator/0` `:label` is the grammar's display phrase and `:lexeme` is the
  spelling. A dropdown draws `t:operator/0`'s `:label`; `:op_label` is what
  the expression carries.
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

  When `simple_available?/0` is false - the resolved predicator has no
  `Predicator.Simple`, or the module the `:predicator_simple` key points at
  does not export all four of `from_source/1`, `to_source/1`, `operators/1`
  and `value_kind/1` - every source string answers `:outside`. That is a degraded
  answer rather than a wrong one: the component renders the text input it
  would render for an unsupported expression.

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
  The operators a picklist offers beside a value of the given kind, read from
  `Predicator.Simple.operators/1`.

  Eligibility is the grammar's answer, not this module's: which operators are
  worth offering beside a date as opposed to a number is decided by the
  `:value_kinds` predicator stamps on its own operator entries, so an operator
  the lexer would reject - or one the grammar does not admit for this kind of
  value - cannot be offered here. Until px-84i landed that function there was
  a table here instead, and ADR-0007's 2026-09-04 amendment - accepted
  2026-09-05 - named it as the one local exception; delegating closes it.

  `:op` builds the clause, `:lexeme` is the spelling the expression will
  carry, `:label` is the display phrase, and `:detail` is the grammar's
  one-line description, or `nil` when `Predicator.Vocabulary` is not
  resolvable.

  Empty when `simple_available?/0` is false, for the same reason `simple/2`
  answers `:outside`: there is nothing truthful to offer. An atom the `@spec`
  does not admit is handed to upstream unchanged rather than rejected here, so
  one that happens to name a `Predicator.Vocabulary` kind - `:number`,
  `:list` - gets the grammar's answer for that kind, and any other atom raises
  there. The raise is upstream's own stance and the right one: an empty list
  would say "no operators here" about a kind that does not exist.

  ## Examples

      iex> StatifierUI.Expression.operators(:boolean) |> Enum.map(& &1.op)
      [:equal_equal, :strict_eq, :ne, :strict_ne, :contains]

      iex> StatifierUI.Expression.operators({:list, :string}) |> Enum.map(& &1.lexeme)
      ["IN"]

      iex> StatifierUI.Expression.operators(:integer) |> Enum.find(&(&1.op == :gte))
      %{op: :gte, lexeme: ">=", label: "is at least", detail: "Greater than or equal to"}

  """
  @spec operators(value_kind()) :: [operator()]
  def operators(value_kind) do
    if simple_available?() do
      value_kind
      |> vocabulary_kind()
      |> simple_module().operators()
      |> Enum.map(&operator/1)
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
  Whether the resolved predicator exposes a usable `Predicator.Simple`.

  The counterpart to `vocabulary_available?/0`, and the same distinction: a
  component stamps it so a host can tell "this expression is outside the
  subset" from "this predicator cannot answer the question".

  Usable is four exports, not one loaded module: `from_source/1`,
  `to_source/1`, `operators/1` and `value_kind/1` all have to be there. Under
  the `~> 9.4` requirement that is inert, since every admitted predicator
  carries all four; it is a host overriding `:predicator_simple` that the
  condition measures, and a stub exporting three of the four reads as
  unavailable - which is why the fourth joined the guard when this module
  started asking upstream what kind a value is. Every
  function this guard gates then degrades together: `simple/2` to `:outside`,
  `operators/1` to `[]`, and `source/2`, `value_source/2` and `segments/1` to
  `:error`. A picklist is lost silently, so a host stubbing this module is
  stubbing the whole surface.

  ## Examples

      iex> is_boolean(StatifierUI.Expression.simple_available?())
      true

  """
  @spec simple_available?() :: boolean()
  def simple_available? do
    module = simple_module()

    Code.ensure_loaded?(module) and
      function_exported?(module, :from_source, 1) and
      function_exported?(module, :to_source, 1) and
      function_exported?(module, :operators, 1) and
      function_exported?(module, :value_kind, 1)
  end

  @doc """
  Writes a source string back from the rows `simple/2` returned.

  The write half of the same round trip: `simple/2` reads source into rows and
  this reads rows back into source, both through `Predicator.Simple`, so a
  picklist never has to spell an operator, a quote, or a connective itself.
  That is what makes the rendered dropdowns a *view* of the source text rather
  than a second representation of the condition - a renderer edits a row's
  `:segments`, `:op`, or `:value`, asks for the source, and stores the string
  it gets back.

  `:error` when `Predicator.Simple` is not resolvable, or when `rows` is
  empty: there is no source string to write, and inventing one would be the
  duplication this module exists to avoid.

  ## Examples

      iex> {:ok, rows, connective} =
      ...>   StatifierUI.Expression.simple("status == 'active' AND amount >= 500")
      iex> StatifierUI.Expression.source(rows, connective)
      {:ok, "status == 'active' AND amount >= 500"}

      iex> {:ok, [row], nil} = StatifierUI.Expression.simple("plan == 'pro'")
      iex> StatifierUI.Expression.source([%{row | value: {:string, "free", :single}}], nil)
      {:ok, "plan == 'free'"}

      iex> StatifierUI.Expression.source([], nil)
      :error

  """
  @spec source([row() | {[tuple()], atom(), term()}], connective()) ::
          {:ok, String.t()} | :error
  def source([], _connective), do: :error

  def source(rows, connective) do
    if simple_available?() do
      module = simple_module()
      clauses = Enum.map(rows, &clause/1)

      {:ok, module |> struct(connective: connective, clauses: clauses) |> module.to_source()}
    else
      :error
    end
  end

  @doc """
  The source text one clause value is written as, on its own.

  `source/2` covers every edit a renderer makes to a whole expression. This
  covers the one case it cannot: a control that has to *compose* a value - a
  free-text field that types into a quoted string, a multi-select that builds
  a list - needs the spellings of the pieces, and asking for them here keeps
  them coming from `Predicator.Simple.to_source/1` rather than from a quoting
  rule written a second time in JavaScript.

  `op` is the operator the value sits beside, because `:in` is the one
  operator whose right-hand side is a list.

  ## Examples

      iex> StatifierUI.Expression.value_source(:equal_equal, {:string, "pro", :single})
      {:ok, "'pro'"}

      iex> StatifierUI.Expression.value_source(:gte, {:integer, 500})
      {:ok, "500"}

      iex> StatifierUI.Expression.value_source(:in, {:list, [{:string, "payment", :single}]})
      {:ok, "['payment']"}

  """
  @spec value_source(atom(), term()) :: {:ok, String.t()} | :error
  def value_source(op, value) do
    if simple_available?() do
      {:ok, value_source(simple_module(), op, value)}
    else
      :error
    end
  end

  @doc """
  The path segments a declared datamodel path parses to.

  A picklist's field dropdown offers the paths a host declared, as strings.
  Swapping a clause onto one of them needs that path in the structural form a
  clause carries, and the only honest way to get there is predicator's own
  parser - a path split on dots here would read `account['tags']` wrong and
  would be a second parser besides.

  `:error` for a string that is not a path, and for every string when
  `Predicator.Simple` is not resolvable.

  ## Examples

      iex> StatifierUI.Expression.segments("card.brand")
      {:ok, [root: "card", property: "brand"]}

      iex> StatifierUI.Expression.segments("amount >= 500")
      :error

  """
  @spec segments(String.t()) :: {:ok, [tuple()]} | :error
  def segments(path) when is_binary(path) do
    if simple_available?() do
      module = simple_module()
      probe = path <> " " <> operator_label(module, :equal_equal) <> " 0"

      case module.from_source(probe) do
        {:ok, %{clauses: [{segments, _op, _value}]}} -> {:ok, segments}
        _other -> :error
      end
    else
      :error
    end
  end

  @spec clause(row() | {[tuple()], atom(), term()}) :: {[tuple()], atom(), term()}
  defp clause(%{segments: segments, op: op, value: value}), do: {segments, op, value}
  defp clause({_segments, _op, _value} = clause), do: clause

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
      operators: kind |> vocabulary_kind() |> module.operators() |> Enum.map(&operator/1),
      candidates: value_candidates(candidates, path)
    }
  end

  # Every spelling below is asked of predicator rather than written out here,
  # so a picklist never shows text the writer would not produce: a path and a
  # value through `Predicator.Simple.to_source/1`, an operator through the
  # `:lexeme` its `operators/1` entry carries, which upstream holds to being
  # the spelling `to_source/1` renders. That is the same rule the completion
  # half follows for lexemes: one copy of the grammar, and it lives in
  # predicator.
  @spec clause_source(module(), {[tuple()], atom(), term()}) :: String.t()
  defp clause_source(module, clause) do
    module |> struct(connective: nil, clauses: [clause]) |> module.to_source()
  end

  # One lookup, not a round-trip: the entry already carries the spelling, so
  # rendering a probe clause only to split it back apart would be asking the
  # writer a question the vocabulary has already answered.
  @spec operator_label(module(), atom()) :: String.t()
  defp operator_label(module, op) do
    %{lexeme: lexeme} =
      op
      |> probe_kind()
      |> module.operators()
      |> Enum.find(&(&1.op == op))

    lexeme
  end

  # `:in` is the one operator whose right-hand side must be a list, so the list
  # kind is the one that offers it; every other operator in the subset is
  # offered for numbers, which is the kind the probe clause used to carry.
  @spec probe_kind(atom()) :: atom()
  defp probe_kind(:in), do: :list
  defp probe_kind(_op), do: :number

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

  @spec operator(%{
          :op => atom(),
          :lexeme => String.t(),
          :label => String.t(),
          optional(atom()) => term()
        }) :: operator()
  defp operator(%{op: op, lexeme: lexeme, label: label}) do
    %{op: op, lexeme: lexeme, label: label, detail: lexeme_detail(lexeme)}
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

  # The two vocabularies name the same kinds differently, so asking upstream
  # its own question needs its own word for the kind. This is a translation,
  # not a second eligibility table - it names no operator, and adding one here
  # would be the duplication delegating removed.
  #
  # `:integer` and `:float` are both `:number`, which is the kind predicator's
  # evaluator orders. `:relative_date` has no vocabulary kind of its own, and
  # which one it borrows is upstream's answer rather than this module's: a
  # relative date resolves to a `DateTime.t()` there, so `value_kind/1` reads
  # a relative-date value as `:datetime`. Asking it with a probe value keeps
  # the pairing on the side that decides it - the local table said `:date`,
  # and `:date` and `:datetime` carry the same operators, so what changes here
  # is where the answer comes from, not what it is.
  @relative_date_probe {:relative_date, [{1, "d"}], :ago}

  @spec vocabulary_kind(value_kind()) :: atom()
  defp vocabulary_kind({:list, _member_kind}), do: :list
  defp vocabulary_kind(:integer), do: :number
  defp vocabulary_kind(:float), do: :number
  defp vocabulary_kind(:relative_date), do: simple_module().value_kind(@relative_date_probe)
  defp vocabulary_kind(kind), do: kind

  # Only the tags this module reads more finely than the grammar does are
  # written out: a list carries its member kind so a renderer can pick the
  # member's control, and `:integer`, `:float` and `:relative_date` are the
  # three distinctions `t:value_kind/0` keeps that `Predicator.Vocabulary` does
  # not make. Every other tag is upstream's own answer, asked rather than
  # restated, so a scalar the grammar gains does not need a row here to be
  # read.
  @spec value_kind(term()) :: value_kind()
  defp value_kind({:list, []}), do: {:list, nil}
  defp value_kind({:list, [first | _rest]}), do: {:list, value_kind(first)}
  defp value_kind({:integer, _value}), do: :integer
  defp value_kind({:float, _value}), do: :float
  defp value_kind({:relative_date, _units, _direction}), do: :relative_date
  defp value_kind(value), do: simple_module().value_kind(value)

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
