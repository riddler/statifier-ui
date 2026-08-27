defmodule StatifierUI.Fixtures.Lint do
  @moduledoc """
  ADR-0006's two lint findings for a fixture bundle: an expression whose
  source text matches no compiled guard, and an `expect` key naming no
  dataset. Both are warnings, never errors - this module has no
  `{:error, _}` return path anywhere in its public API.

  Guard matching is **byte equality on source text only**. A `t_index` never
  appears as a matching key, only as an output pointer for a consumer that
  wants to annotate a transition: `t_index` values are document-order
  positions that shift under any edit above the transition (a state
  inserted earlier in the document, for example), so matching by index
  would silently pin the wrong guard the moment the chart changes shape.
  Matching by source text survives exactly that kind of edit, which is why
  ADR-0006 fixes it as the identity.

  An unmatched expression is a warning, not an error, because a
  free-standing expression with no corresponding guard is a legal state of
  the contract - ADR-0006 does not require every expression to mirror a
  guard. The warning exists for the near-miss case: an expression authored
  against a guard that has since drifted (reformatted, requoted, or
  otherwise edited), where matching is exact and a near match does not
  count. That case is exactly the one a bare "no match" message hides, so
  the finding's message carries the expression's own source text: a drift
  of one space or one quote style is invisible until the two strings can be
  read against each other, and the reader has the chart's guards in front
  of them already.

  Reads a compiled `%Statifier.Machine{}` only for its transitions' guard
  source text (`Statifier.Machine.Transition.cond`, the `{:compiled, _,
  source}` shape `t:Statifier.Machine.expr/0` documents). Nothing here calls
  `Predicator` - it reads source strings, it does not evaluate them - and
  nothing here modifies the engine (ADR-0002).
  """

  alias Statifier.Machine
  alias StatifierUI.Fixtures

  @doc """
  Expression names matched to the `t_index` of every transition whose guard
  source text is byte-equal to the expression's source.

  A `{:static, _}` guard and a transition with no `cond` at all (`nil`)
  carry no author-written expression text, so both are skipped without
  error. An expression can match more than one guard; all matching
  `t_index` values are returned, sorted.

  The `t_index` values in the result are an output - a pointer for a
  consumer (a truth table, a guard annotation) that wants to point back at
  the transition - never an input to the match. See the moduledoc for why
  matching by index would be wrong.
  """
  @spec guard_matches(Fixtures.t(), Machine.t()) ::
          %{optional(Fixtures.expression_name()) => [non_neg_integer()]}
  def guard_matches(%Fixtures{} = fixtures, %Machine{} = machine) do
    guard_sources = guard_sources(machine)

    fixtures
    |> Fixtures.expression_names()
    |> Enum.map(fn name ->
      {:ok, expression} = Fixtures.expression(fixtures, name)
      source = Map.get(expression, "source")

      matches =
        guard_sources
        |> Enum.filter(fn {_t_index, guard_source} -> guard_source == source end)
        |> Enum.map(fn {t_index, _guard_source} -> t_index end)
        |> Enum.sort()

      {name, matches}
    end)
    |> Map.new()
  end

  @doc """
  A warning per expression whose source text is byte-equal to no guard in
  `machine`.

  See the moduledoc for why this is a warning: an unmatched expression is a
  legal, free-standing fixture, and the finding exists to surface the
  near-miss case where an author expected a match and a text drift (however
  small) broke it.
  """
  @spec unmatched_expressions(Fixtures.t(), Machine.t()) :: [Fixtures.diagnostic()]
  def unmatched_expressions(%Fixtures{} = fixtures, %Machine{} = machine) do
    matches = guard_matches(fixtures, machine)

    fixtures
    |> Fixtures.expression_names()
    |> Enum.filter(fn name -> matches[name] == [] end)
    |> Enum.map(fn name ->
      {:ok, expression} = Fixtures.expression(fixtures, name)

      diagnostic(
        :unmatched_expression,
        "expression #{inspect(name)} matches no guard by source text: " <>
          "#{inspect(Map.get(expression, "source"))}",
        [name]
      )
    end)
  end

  @doc """
  A warning per `expect` key naming no dataset in `fixtures`.

  Needs no machine: this is a fact about the bundle alone, so it is callable
  on a bundle by itself.
  """
  @spec dangling_expect_keys(Fixtures.t()) :: [Fixtures.diagnostic()]
  def dangling_expect_keys(%Fixtures{} = fixtures) do
    dataset_names = MapSet.new(Fixtures.dataset_names(fixtures))

    for name <- Fixtures.expression_names(fixtures),
        {:ok, expression} = Fixtures.expression(fixtures, name),
        expect = Map.get(expression, "expect", %{}),
        dataset_name <- Map.keys(expect),
        dataset_name not in dataset_names do
      diagnostic(
        :dangling_expect_dataset,
        "expression #{inspect(name)} states an expectation for unknown dataset #{inspect(dataset_name)}",
        [name, "expect", dataset_name]
      )
    end
  end

  @doc """
  Every lint finding for `fixtures`, sorted by `path` for stable,
  byte-comparable output (ADR-0005's canonical-order habit).

  `machine` of `nil` runs only the machine-free check
  (`dangling_expect_keys/1`); given a `%Statifier.Machine{}`, both checks
  run.
  """
  @spec lint(Fixtures.t(), Machine.t() | nil) :: [Fixtures.diagnostic()]
  def lint(%Fixtures{} = fixtures, nil) do
    fixtures
    |> dangling_expect_keys()
    |> Enum.sort_by(& &1.path)
  end

  def lint(%Fixtures{} = fixtures, %Machine{} = machine) do
    (unmatched_expressions(fixtures, machine) ++ dangling_expect_keys(fixtures))
    |> Enum.sort_by(& &1.path)
  end

  # {:compiled, _compiled, source} carries author-written guard text;
  # {:static, _} is a literal with no source to match, and nil means the
  # transition wrote no `cond` at all - both are skipped.
  @spec guard_sources(Machine.t()) :: [{non_neg_integer(), String.t()}]
  defp guard_sources(%Machine{transitions: transitions}) do
    transitions
    |> Tuple.to_list()
    |> Enum.flat_map(fn transition ->
      case transition.cond do
        {:compiled, _compiled, source} -> [{transition.t_index, source}]
        {:static, _term} -> []
        nil -> []
      end
    end)
  end

  @spec diagnostic(atom(), String.t(), [String.t()]) :: Fixtures.diagnostic()
  defp diagnostic(kind, message, path) do
    %{kind: kind, message: message, path: path, source: nil}
  end
end
