defmodule SimpleWithoutDurationUnits do
  @moduledoc false
  # A predicator that can classify and write but predates `duration_units/0`.
  # It exports exactly the four functions `simple_available?/0` guards on, so
  # the picklist stays available and only the offered relative dates go - the
  # degradation `relative_date_candidates/0` holds one function narrower than
  # the module-wide guard.

  defdelegate from_source(source), to: Predicator.Simple
  defdelegate to_source(simple), to: Predicator.Simple
  defdelegate operators(kind), to: Predicator.Simple
  defdelegate value_kind(value), to: Predicator.Simple
end

defmodule StatifierUI.ExpressionTest do
  # Not async: the degraded-source tests swap an application env key that the
  # completion source reads at call time.
  use ExUnit.Case, async: false

  doctest StatifierUI.Expression

  alias StatifierUI.Expression

  describe "the grammar half" do
    test "reads predicator's own vocabulary rather than a second copy of it" do
      insertions = Expression.completions() |> Enum.map(& &1.insert)

      # One from each shape the vocabulary enumerates: a symbol operator, a
      # word operator, a literal word, and a duration unit.
      for lexeme <- [">=", "contains", "true", "d"] do
        assert lexeme in insertions,
               "#{inspect(lexeme)} is in Predicator.Vocabulary and was not offered"
      end
    end

    test "offers both cases of the word operators, because the grammar accepts both" do
      insertions = Expression.completions() |> Enum.map(& &1.insert)

      assert "and" in insertions
      assert "AND" in insertions
    end

    test "carries the px category through as the completion kind" do
      gte = Expression.completions() |> Enum.find(&(&1.insert == ">="))

      assert gte.kind == "comparison"
      assert is_binary(gte.detail)
    end

    test "a function completes to an open call, and says its arity" do
      len = Expression.completions() |> Enum.find(&(&1.label == "len(...)"))

      assert len.insert == "len("
      assert len.kind == "function"
      assert len.detail == "1-argument function"
    end

    test "function resolution honours the caller's provider options" do
      refute Expression.completions([], builtins: false)
             |> Enum.any?(&(&1.kind == "function"))
    end

    test "vocabulary_available? is true against the resolved predicator" do
      assert Expression.vocabulary_available?()
    end
  end

  describe "declared paths" do
    test "lead the list - they are the entries an author cannot look up" do
      [first, second | _rest] =
        Expression.completions(["authorization.amount_cents", "card.brand"])

      assert first == %{
               label: "authorization.amount_cents",
               insert: "authorization.amount_cents",
               kind: "path",
               detail: "declared path"
             }

      assert second.insert == "card.brand"
    end

    test "no candidates is a shorter list, not a different one" do
      assert Expression.completions() == Expression.completions([])
    end
  end

  describe "the degraded source (no Predicator.Vocabulary)" do
    setup do
      Application.put_env(:statifier_ui, :predicator_vocabulary, NotAVocabulary)
      on_exit(fn -> Application.delete_env(:statifier_ui, :predicator_vocabulary) end)
    end

    test "keeps the declared paths and drops the grammar" do
      assert Expression.completions(["authorization.amount_cents"]) == [
               %{
                 label: "authorization.amount_cents",
                 insert: "authorization.amount_cents",
                 kind: "path",
                 detail: "declared path"
               }
             ]
    end

    test "says so rather than looking like a grammar with nothing in it" do
      refute Expression.vocabulary_available?()
      assert Expression.completions() == []
    end
  end

  describe "datalist/1" do
    test "keeps what a native datalist can filter on" do
      kept = Expression.completions(["authorization.amount_cents"]) |> Expression.datalist()
      insertions = Enum.map(kept, & &1.insert)

      assert "authorization.amount_cents" in insertions
      assert "contains" in insertions
      assert "len(" in insertions
    end

    test "drops the symbol operators, which a datalist cannot help with" do
      insertions =
        Expression.completions() |> Expression.datalist() |> Enum.map(& &1.insert)

      for symbol <- [">=", "::", "(", "+"] do
        refute symbol in insertions,
               "#{inspect(symbol)} cannot be prefix-matched in a datalist and was offered"
      end
    end
  end

  describe "the picklist half: what is in the subset" do
    test "a single clause carries no connective" do
      assert {:ok, [row], nil} = Expression.simple("status == 'active'")

      assert row.path == "status"
      assert row.op == :equal_equal
      assert row.value_kind == :string
      assert row.value == {:string, "active", :single}
    end

    test "clauses joined by one connective carry it" do
      assert {:ok, rows, :and} = Expression.simple("status == 'active' AND amount >= 500")
      assert Enum.map(rows, & &1.path) == ["status", "amount"]
      assert Enum.map(rows, & &1.op) == [:equal_equal, :gte]

      assert {:ok, _rows, :or} = Expression.simple("plan == 'pro' OR amount >= 500")
    end

    test "a membership clause reads as a list value" do
      assert {:ok, [row], nil} = Expression.simple("step in ['payment', 'review']")

      assert row.op == :in
      assert row.value_kind == {:list, :string}
      assert row.value == {:list, [{:string, "payment", :single}, {:string, "review", :single}]}
    end

    test "a dotted path and a bracket path both come back as one field" do
      assert {:ok, [dotted], nil} = Expression.simple("card.brand == 'visa'")
      assert dotted.path == "card.brand"
      assert dotted.segments == [root: "card", property: "brand"]

      assert {:ok, [bracketed], nil} = Expression.simple("account['tags'] contains 'vip'")
      assert bracketed.path == "account['tags']"
      assert bracketed.segments == [root: "account", key: "tags"]
    end

    test "a relative date is a value like any other, so a form can offer a window control" do
      assert {:ok, [row], nil} = Expression.simple("signup.created_at < 30d ago")

      assert row.value_kind == :relative_date
      assert row.value == {:relative_date, [{30, "d"}], :ago}
      assert row.value_source == "30d ago"
    end
  end

  describe "the picklist half: what is outside it, and what is not an expression" do
    test "a valid expression a picklist cannot draw is :outside, not an error" do
      for source <- [
            "status == 'active' AND (amount >= 500 OR plan == 'pro')",
            "NOT plan == 'pro'",
            "status == 'active' AND amount >= 500 OR plan == 'pro'",
            "amount + 1 >= 500",
            "len(step) > 0",
            "500 <= amount"
          ] do
        assert Expression.simple(source) == :outside,
               "#{source} is outside the subset and did not answer :outside"
      end
    end

    test "source that does not parse stays an error, so the caller can underline it" do
      assert {:error, error} = Expression.simple("amount >= >=")
      assert error.position == {1, 11}
    end
  end

  describe "value candidates" do
    test "a row carries the values its host declared for that path" do
      assert {:ok, [row], nil} =
               Expression.simple("step in ['payment', 'review']",
                 value_candidates: %{"step" => ["payment", "review", "confirmation"]}
               )

      assert Enum.map(row.candidates, & &1.label) == ["payment", "review", "confirmation"]
    end

    test "a candidate may name a label distinct from the value it writes" do
      assert {:ok, [row], nil} =
               Expression.simple("plan == 'pro'",
                 value_candidates: %{"plan" => [%{label: "Pro", value: "pro"}]}
               )

      assert row.candidates == [%{label: "Pro", value: "pro"}]
    end

    test "a path the host declared nothing for gets an empty list, never a guess" do
      assert {:ok, [row], nil} = Expression.simple("amount >= 500")
      assert row.candidates == []

      assert Expression.value_candidates(%{"step" => ["payment"]}, "plan") == []
    end
  end

  describe "operator lists" do
    test "each value kind offers only the operators the grammar admits beside it" do
      assert Enum.map(Expression.operators(:boolean), & &1.op) ==
               Enum.map(Predicator.Simple.operators(:boolean), & &1.op)

      assert :contains in Enum.map(Expression.operators(:string), & &1.op)
      assert :gte in Enum.map(Expression.operators(:integer), & &1.op)

      refute :gte in Enum.map(Expression.operators(:boolean), & &1.op),
             "a boolean is not ordered, so ordered comparison is not offered beside one"
    end

    # `t:StatifierUI.Expression.value_kind/0` is the shape of a clause value and
    # `Predicator.Vocabulary.value_kinds/0` is the grammar's own vocabulary. They
    # are not the same list, and these say the translation between them is right
    # rather than plausible.
    test "the kinds this module names ask the grammar's own question" do
      numbers = Enum.map(Predicator.Simple.operators(:number), & &1.op)

      assert Enum.map(Expression.operators(:integer), & &1.op) == numbers
      assert Enum.map(Expression.operators(:float), & &1.op) == numbers

      assert Expression.operators(:relative_date) == Expression.operators(:date)
      assert Expression.operators({:list, :string}) == Expression.operators({:list, nil})
    end

    # A relative date has no vocabulary kind of its own, so it borrows one, and
    # which one it borrows is now predicator's answer rather than a row here.
    # The answer moved from `:date` to `:datetime`; these say the move is inert
    # by holding the two operator lists identical, entry for entry, not merely
    # equal in their `:op` atoms.
    test "a relative date borrows the kind predicator resolves it to" do
      assert Predicator.Simple.value_kind({:relative_date, [{1, "d"}], :ago}) == :datetime

      assert Predicator.Simple.operators(:datetime) == Predicator.Simple.operators(:date)
      assert Expression.operators(:relative_date) == Expression.operators(:datetime)
    end

    test "membership belongs to the list side and containment to the scalar side" do
      assert Enum.map(Expression.operators({:list, :string}), & &1.op) == [:in]
      refute :in in Enum.map(Expression.operators(:string), & &1.op)
      refute :contains in Enum.map(Expression.operators({:list, :string}), & &1.op)
    end

    test "an empty list still has a kind, so a row for one still renders" do
      assert {:ok, [row], nil} = Expression.simple("step in []")
      assert row.value_kind == {:list, nil}
      assert Enum.map(row.operators, & &1.op) == [:in]
    end

    test "an operator carries its spelling, its display phrase, and its description" do
      gte = Expression.operators(:integer) |> Enum.find(&(&1.op == :gte))

      assert gte.lexeme == ">="
      assert gte.label == "is at least"
      assert gte.detail == "Greater than or equal to"
    end
  end

  # `t:StatifierUI.Expression.value_kind/0` names three things more finely than
  # `Predicator.Vocabulary` does - `:integer` and `:float` where the grammar has
  # one `:number`, and `:relative_date`, which it does not name at all - and a
  # list carries its member kind. Everything else is
  # `Predicator.Simple.value_kind/1`'s own answer rather than a table in this
  # package, and these enumerate the subset's tags so a scalar the grammar
  # renames cannot drift past unnoticed.
  describe "what kind a value is" do
    @finer %{
      {:integer, 5} => :integer,
      {:float, 1.5} => :float,
      {:relative_date, [{30, "d"}], :ago} => :relative_date
    }

    @scalar_sources [
      "x == 'a'",
      "x == 5",
      "x == 1.5",
      "x == true",
      "x == #2026-01-01#",
      "x == #2026-01-01T10:00:00Z#",
      "x == 3d",
      "x == 30d ago"
    ]

    test "every scalar tag reads as the kind predicator reports for it" do
      for source <- @scalar_sources do
        assert {:ok, [row], nil} = Expression.simple(source),
               "#{source} did not read back into the subset"

        expected = Map.get(@finer, row.value, Predicator.Simple.value_kind(row.value))

        assert row.value_kind == expected,
               "#{source} read as #{inspect(row.value_kind)}, not #{inspect(expected)}"
      end
    end

    test "the tag list above is the whole scalar side of the subset" do
      tags =
        for source <- @scalar_sources do
          {:ok, [row], nil} = Expression.simple(source)
          elem(row.value, 0)
        end

      assert Enum.sort(tags) ==
               [:boolean, :date, :datetime, :duration, :float, :integer, :relative_date, :string]
    end

    test "a list is its member's kind, and predicator sees only the list" do
      assert {:ok, [members], nil} = Expression.simple("x in ['a']")
      assert members.value_kind == {:list, :string}
      assert Predicator.Simple.value_kind(members.value) == :list

      assert {:ok, [empty], nil} = Expression.simple("x in []")
      assert empty.value_kind == {:list, nil}
      assert Predicator.Simple.value_kind(empty.value) == :list
    end
  end

  # These three hold the spellings this module hands a renderer against the
  # parser that has to read them back. Nothing here writes source text of its
  # own - every spelling is asked of `Predicator.Simple.to_source/1` - and
  # these tests are what say that asking worked.
  describe "the picklist half round-trips its own spellings" do
    # Every kind `value_kind/1` can produce, so an operator offered beside a kind
    # this module never asks about is still an operator the lexer has to accept.
    @kinds [
      :string,
      :integer,
      :float,
      :boolean,
      :date,
      :datetime,
      :duration,
      :relative_date,
      {:list, :string},
      {:list, nil}
    ]

    test "sui never offers an operator the lexer would reject" do
      offered =
        for kind <- @kinds, operator <- Expression.operators(kind), do: {kind, operator}

      refute offered == [], "the kind list offered nothing, so this asserts nothing"

      for {kind, operator} <- offered do
        value = if match?({:list, _member}, kind), do: "[1]", else: "1"
        source = "amount " <> operator.lexeme <> " " <> value

        assert {:ok, [row], nil} = Expression.simple(source),
               "#{source} did not read back into the subset"

        assert row.op == operator.op,
               "#{operator.lexeme} was offered for #{inspect(operator.op)} and parsed as #{inspect(row.op)}"
      end
    end

    # The label a row carries is read off the operator's vocabulary entry
    # (sui-55g); it used to be split out of a clause rendered by the writer.
    # This holds the two derivations against each other for every operator the
    # vocabulary offers, so the swap stays a swap rather than a change of
    # spelling nobody asked for.
    test "a row is labelled with the spelling the writer would render" do
      labelled =
        for kind <- @kinds, operator <- Expression.operators(kind), do: {kind, operator}

      refute labelled == [], "the kind list offered nothing, so this asserts nothing"

      for {kind, operator} <- labelled do
        value = if match?({:list, _member}, kind), do: "[1]", else: "1"
        source = "amount " <> operator.lexeme <> " " <> value
        written = written_spelling(operator.op)

        assert {:ok, [row], nil} = Expression.simple(source)

        assert row.op_label == written,
               "#{inspect(operator.op)} is labelled #{inspect(row.op_label)}, written #{inspect(written)}"
      end
    end

    test "every path parses back to the segments it was rendered from" do
      for path <- ["status", "card.brand", "account['tags']", "signup.created_at"] do
        assert {:ok, [row], nil} = Expression.simple(path <> " == 'active'")
        assert row.path == path

        assert {:ok, [again], nil} = Expression.simple(row.path <> " == 'active'")
        assert again.segments == row.segments
      end
    end

    test "every value_source parses back to the value it was rendered from" do
      for source <- [
            "status == 'active'",
            "amount >= 500",
            "plan == true",
            "step in ['payment', 'review']",
            "signup.created_at < 30d ago",
            "account['tags'] contains 'vip'"
          ] do
        assert {:ok, [row], nil} = Expression.simple(source)

        assert {:ok, [again], nil} =
                 Expression.simple("amount " <> row.op_label <> " " <> row.value_source),
               "#{row.value_source} did not read back into the subset"

        assert again.value == row.value
      end
    end
  end

  describe "the write half: source/2, value_source/2, segments/1" do
    test "rows written back are the source they were read from" do
      for source <- [
            "plan == 'pro'",
            "status == 'active' AND amount >= 500",
            "step IN ['payment', 'review']",
            "status == 'active' OR plan == 'pro'"
          ] do
        assert {:ok, rows, connective} = Expression.simple(source)
        assert Expression.source(rows, connective) == {:ok, source}
      end
    end

    # The writer has one spelling per operator, so reading `in` and writing it
    # back gives `IN`. That is not a rewrite of the author's text: nothing
    # stores this string until an author edits something, and the component
    # renders `@value` untouched either way.
    test "the writer's spelling is canonical, and may differ from what was typed" do
      assert {:ok, rows, connective} = Expression.simple("step in ['payment']")
      assert Expression.source(rows, connective) == {:ok, "step IN ['payment']"}

      assert {:ok, rows, connective} = Expression.simple("plan=='pro'")
      assert Expression.source(rows, connective) == {:ok, "plan == 'pro'"}
    end

    test "an edited row is written without the editor spelling anything itself" do
      assert {:ok, [row], nil} = Expression.simple("plan == 'pro'")

      assert Expression.source([%{row | op: :ne}], nil) == {:ok, "plan != 'pro'"}

      assert {:ok, segments} = Expression.segments("card.brand")
      assert Expression.source([%{row | segments: segments}], nil) == {:ok, "card.brand == 'pro'"}
    end

    test "a clause tuple is accepted as well as a row, which is what adding one needs" do
      assert {:ok, [row], nil} = Expression.simple("plan == 'pro'")
      assert {:ok, segments} = Expression.segments("status")
      added = [row, {segments, :equal_equal, {:string, "active", :single}}]

      assert Expression.source(added, :and) == {:ok, "plan == 'pro' AND status == 'active'"}
    end

    test "no rows is no source, rather than an invented one" do
      assert Expression.source([], nil) == :error
      assert Expression.source([], :and) == :error
    end

    test "value_source/2 spells one value the way the writer spells it" do
      assert Expression.value_source(:equal_equal, {:string, "pro", :single}) == {:ok, "'pro'"}
      assert Expression.value_source(:equal_equal, {:string, "pro", :double}) == {:ok, ~s("pro")}
      assert Expression.value_source(:gte, {:integer, 500}) == {:ok, "500"}
      assert Expression.value_source(:equal_equal, {:boolean, true}) == {:ok, "true"}

      assert Expression.value_source(:in, {:list, [{:string, "payment", :single}]}) ==
               {:ok, "['payment']"}
    end

    test "a value written on its own parses back to the value it came from" do
      assert {:ok, [row], nil} = Expression.simple("step in ['payment', 'review']")
      assert {:ok, written} = Expression.value_source(:in, row.value)
      assert {:ok, [again], nil} = Expression.simple("step in " <> written)
      assert again.value == row.value
    end

    test "segments/1 reads a declared path with predicator's own parser" do
      assert Expression.segments("status") == {:ok, [root: "status"]}
      assert Expression.segments("card.brand") == {:ok, [root: "card", property: "brand"]}
      assert Expression.segments("account['tags']") == {:ok, [root: "account", key: "tags"]}
    end

    test "segments/1 refuses a string that is not a path" do
      for source <- ["amount >= 500", "len(plan)", "", "'pro'"] do
        assert Expression.segments(source) == :error
      end
    end
  end

  describe "declared path kinds" do
    test "a declared kind decides the operator list, and the grammar still answers it" do
      {:ok, [row], nil} = Expression.simple("plan == 'pro'", path_types: %{"plan" => :boolean})

      assert Enum.map(row.operators, & &1.op) == Enum.map(Expression.operators(:boolean), & &1.op)
      refute :gt in Enum.map(row.operators, & &1.op)
    end

    test "an integer declaration offers exactly the integer operators" do
      {:ok, [row], nil} = Expression.simple("plan == 'pro'", path_types: %{"plan" => :integer})

      assert Enum.map(row.operators, & &1.op) == Enum.map(Expression.operators(:integer), & &1.op)
    end

    test "a list declaration offers the list operators only" do
      {:ok, [row], nil} =
        Expression.simple("step in ['payment']", path_types: %{"step" => {:list, :string}})

      assert Enum.map(row.operators, & &1.op) == [:in]
    end

    test "the operator the source carries is offered even when the declaration would drop it" do
      {:ok, [row], nil} =
        Expression.simple("plan CONTAINS 'pro'", path_types: %{"plan" => {:list, :string}})

      assert Enum.map(row.operators, & &1.op) == [:in, :contains]
    end

    test "a kept CONTAINS raises no operator advisory" do
      {:ok, [row], nil} =
        Expression.simple("plan CONTAINS 'pro'", path_types: %{"plan" => {:list, :string}})

      assert row.advisories == []
    end

    test "a kept IN raises no operator advisory - it holds its collection on the right" do
      {:ok, [row], nil} =
        Expression.simple("step in ['payment']", path_types: %{"step" => :string})

      assert :in in Enum.map(row.operators, & &1.op)
      assert row.advisories == []
    end

    test "IN and CONTAINS are read through the operator, not against it" do
      {:ok, [in_row], nil} =
        Expression.simple("step IN ['payment']", path_types: %{"step" => :string})

      {:ok, [contains_row], nil} =
        Expression.simple("plan CONTAINS 'pro'", path_types: %{"plan" => {:list, :string}})

      refute Enum.any?(in_row.advisories, &(&1.reason == :value_kind))
      refute Enum.any?(contains_row.advisories, &(&1.reason == :value_kind))
    end

    test "an operator outside a declared kind is kept, and says so" do
      {:ok, [row], nil} = Expression.simple("plan > 'pro'", path_types: %{"plan" => :boolean})

      assert :gt in Enum.map(row.operators, & &1.op)
      assert Enum.any?(row.advisories, &(&1.reason == :operator and &1.severity == :info))
    end

    test "a one_of declaration asks the grammar for the kind of its own values" do
      integers = %{"amount" => {:one_of, [1, 2]}}
      strings = %{"amount" => {:one_of, ["a"]}}
      empty = %{"amount" => {:one_of, []}}

      assert ops("amount == 1", integers) == Enum.map(Expression.operators(:integer), & &1.op)
      assert ops("amount == 1", strings) == Enum.map(Expression.operators(:string), & &1.op)
      assert ops("amount == 1", empty) == Enum.map(Expression.operators(:string), & &1.op)
    end

    test "a one_of declaration fills the candidate list when value_candidates has no entry" do
      {:ok, [row], nil} =
        Expression.simple("status == 'active'",
          path_types: %{"status" => {:one_of, ["active", "pending"]}}
        )

      assert Enum.map(row.candidates, & &1.value) == ["active", "pending"]
    end

    test "value_candidates win over a one_of declaration for the same path" do
      {:ok, [row], nil} =
        Expression.simple("status == 'active'",
          value_candidates: %{"status" => ["active", "settled"]},
          path_types: %{"status" => {:one_of, ["pending"]}}
        )

      assert Enum.map(row.candidates, & &1.value) == ["active", "settled"]
    end

    test "a one_of value that is not a string is still labelled rather than raising" do
      {:ok, [row], nil} =
        Expression.simple("amount == 1", path_types: %{"amount" => {:one_of, [1, 2]}})

      assert Enum.map(row.candidates, & &1.label) == ["1", "2"]
    end

    test "a date declaration offers the relative-date set" do
      {:ok, [row], nil} =
        Expression.simple("created_at == 1", path_types: %{"created_at" => :date})

      assert row.candidates == Expression.relative_date_candidates()
      assert row.candidates != []
    end

    test "every offered relative date uses a unit the grammar knows" do
      known = Predicator.Simple.duration_units()

      for %{value: {:relative_date, units, _direction} = value} <-
            Expression.relative_date_candidates() do
        assert Enum.all?(units, fn {_amount, unit} -> unit in known end)
        assert {:ok, _written} = Expression.value_source(:equal_equal, value)
      end
    end

    test "a value that disagrees with its declaration raises an advisory, not an error" do
      assert {:ok, [row], nil} =
               Expression.simple("amount >= 500", path_types: %{"amount" => :string})

      assert [%{severity: :info, reason: :value_kind}] = row.advisories
    end

    test "an integer and a float do not disagree, because the grammar has one number kind" do
      {:ok, [row], nil} = Expression.simple("amount >= 500", path_types: %{"amount" => :float})

      assert row.advisories == []
    end

    test "a list value is not given a scalar declaration's control kind" do
      {:ok, [row], nil} =
        Expression.simple("plan == 'pro'", path_types: %{"plan" => {:list, :string}})

      assert row.control_kind == :string
      assert Enum.any?(row.advisories, &(&1.reason == :value_kind))
    end

    test "a list value is never given a scalar declaration's control kind" do
      {:ok, [row], nil} =
        Expression.simple("step in ['payment']", path_types: %{"step" => :string})

      assert row.control_kind == {:list, :string}
    end

    test "a declared kind that agrees with the source raises nothing" do
      {:ok, [row], nil} = Expression.simple("plan == 'pro'", path_types: %{"plan" => :string})

      assert row.declared_kind == :string
      assert row.control_kind == :string
      assert row.advisories == []
    end

    test "a path the map says nothing about is untouched by the map" do
      {:ok, [row], nil} = Expression.simple("plan == 'pro'", path_types: %{"other" => :boolean})

      assert row.declared_kind == nil
      assert row.advisories == []
      assert row.control_kind == row.value_kind
    end

    test "no path_types is exactly today's row" do
      sources = [
        "plan == 'pro'",
        "amount >= 500",
        "step in ['payment', 'review']",
        "status == 'active' AND amount >= 500"
      ]

      for source <- sources do
        assert Expression.simple(source) == Expression.simple(source, path_types: %{})

        {:ok, rows, _connective} = Expression.simple(source)

        for row <- rows do
          assert row.declared_kind == nil
          assert row.advisories == []
          assert row.control_kind == row.value_kind
        end
      end
    end

    test "an unusable predicator still degrades to :outside" do
      Application.put_env(:statifier_ui, :predicator_simple, NotPredicatorSimple)
      on_exit(fn -> Application.delete_env(:statifier_ui, :predicator_simple) end)

      assert Expression.simple("plan == 'pro'", path_types: %{"plan" => :boolean}) == :outside
      assert Expression.relative_date_candidates() == []
    end

    test "relative_date_candidates/0 is empty when the resolved module lacks duration_units/0" do
      Application.put_env(:statifier_ui, :predicator_simple, SimpleWithoutDurationUnits)
      on_exit(fn -> Application.delete_env(:statifier_ui, :predicator_simple) end)

      assert Expression.simple_available?()
      assert Expression.relative_date_candidates() == []
    end
  end

  describe "an inline shape in the map (sui-9pj)" do
    @holder {:shape,
             [
               %{name: "name", type: :string, required?: true},
               %{name: "since", type: :datetime, required?: false}
             ]}

    @card {:shape,
           [
             %{name: "brand", type: :string, required?: true},
             %{name: "last_four", type: :integer, required?: false},
             %{name: "issued_on", type: :date, required?: true},
             %{name: "issuer", type: {:declared, "cards.issuer"}, required?: true},
             %{name: "holder", type: @holder, required?: true}
           ]}

    test "a member read is typed by its member" do
      {:ok, [row], nil} =
        Expression.simple("card.brand == 'visa'", path_types: %{"card" => @card})

      assert row.declared_kind == :string
      assert row.control_kind == :string
      assert row.advisories == []
    end

    test "a member is typed exactly as the same declaration spelled on the path" do
      shaped = Expression.simple("card.brand == 'visa'", path_types: %{"card" => @card})
      spelled = Expression.simple("card.brand == 'visa'", path_types: %{"card.brand" => :string})

      assert shaped == spelled
    end

    test "an integer member answers the projection's own tag for integer" do
      {:ok, [row], nil} =
        Expression.simple("card.last_four == 1234", path_types: %{"card" => @card})

      assert row.declared_kind == :number
      assert row.advisories == []
    end

    test "a date member is offered the relative-date candidates" do
      {:ok, [row], nil} = Expression.simple("card.issued_on == 1", path_types: %{"card" => @card})

      assert row.declared_kind == :date
      assert row.candidates != []
    end

    test "a member the shape does not promise is read like any other" do
      {:ok, [promised], nil} =
        Expression.simple("card.brand == 'visa'", path_types: %{"card" => @card})

      {:ok, [unpromised], nil} =
        Expression.simple("card.last_four == 1", path_types: %{"card" => @card})

      assert promised.declared_kind == :string
      assert unpromised.declared_kind == :number
      assert unpromised.advisories == []
    end

    test "a shape nested in a shape is read through" do
      {:ok, [row], nil} =
        Expression.simple("card.holder.name == 'ada'", path_types: %{"card" => @card})

      assert row.declared_kind == :string
      assert row.advisories == []
    end

    test "the path holding a nested shape carries that shape and declares nothing" do
      {:ok, [row], nil} =
        Expression.simple("card.holder == 'ada'", path_types: %{"card" => @card})

      assert row.declared_kind == @holder
      assert row.control_kind == row.value_kind
      assert row.advisories == []
    end

    test "the bracketed spelling of a member read is the same member" do
      {:ok, [dotted], nil} =
        Expression.simple("card.brand == 'visa'", path_types: %{"card" => @card})

      {:ok, [bracketed], nil} =
        Expression.simple("card['brand'] == 'visa'", path_types: %{"card" => @card})

      assert dotted.declared_kind == :string
      assert bracketed.declared_kind == dotted.declared_kind
    end

    test "an exact entry for the longer path wins over the shape's member" do
      {:ok, [row], nil} =
        Expression.simple("card.brand == 'visa'",
          path_types: %{"card" => @card, "card.brand" => {:one_of, ["visa", "amex"]}}
        )

      assert row.declared_kind == {:one_of, ["visa", "amex"]}
    end

    test "a member the shape does not name declares nothing" do
      {:ok, [row], nil} =
        Expression.simple("card.expiry == 'visa'", path_types: %{"card" => @card})

      assert row.declared_kind == nil
      assert row.advisories == []
    end

    test "a member typed by a declaration name declares nothing here" do
      {:ok, [row], nil} =
        Expression.simple("card.issuer == 'visa'", path_types: %{"card" => @card})

      assert row.declared_kind == nil
      assert row.advisories == []
    end

    test "the path holding the shape reads exactly as an undeclared path" do
      for source <- ["card == 'visa'", "card in ['visa']", "card CONTAINS 'visa'"] do
        {:ok, [shaped], nil} = Expression.simple(source, path_types: %{"card" => @card})
        {:ok, [undeclared], nil} = Expression.simple(source)

        assert Map.delete(shaped, :declared_kind) == Map.delete(undeclared, :declared_kind),
               "a shape changed the row for #{inspect(source)}"

        assert shaped.declared_kind == @card
        assert shaped.advisories == []
      end
    end
  end

  describe "the degraded source (no Predicator.Simple)" do
    setup do
      Application.put_env(:statifier_ui, :predicator_simple, NotPredicatorSimple)
      on_exit(fn -> Application.delete_env(:statifier_ui, :predicator_simple) end)
    end

    test "every source string is :outside, including one that does not parse" do
      for source <- ["status == 'active'", "NOT plan == 'pro'", "amount >= >="] do
        assert Expression.simple(source) == :outside
      end
    end

    test "no operators are offered, because there is nothing truthful to offer" do
      assert Expression.operators(:string) == []
    end

    test "the write half answers :error rather than guessing at a spelling" do
      assert Expression.source([{[root: "plan"], :equal_equal, {:string, "pro", :single}}], nil) ==
               :error

      assert Expression.value_source(:equal_equal, {:string, "pro", :single}) == :error
      assert Expression.segments("status") == :error
    end

    test "simple_available? says which of the two answers :outside means" do
      refute Expression.simple_available?()
    end
  end

  test "simple_available? is true against the resolved predicator" do
    assert Expression.simple_available?()
  end

  # The derivation the module used before sui-55g: render a probe clause
  # through `Predicator.Simple.to_source/1` and take the word between the path
  # and the value. It lives here, and only here, as the thing the vocabulary
  # read is checked against.
  defp ops(source, path_types) do
    {:ok, [row], nil} = Expression.simple(source, path_types: path_types)

    Enum.map(row.operators, & &1.op)
  end

  defp written_spelling(op) do
    value = if op == :in, do: {:list, [{:integer, 0}]}, else: {:integer, 0}

    [_path, spelling | _rest] =
      Predicator.Simple
      |> struct(connective: nil, clauses: [{[{:root, "x"}], op, value}])
      |> Predicator.Simple.to_source()
      |> String.split(" ", parts: 3)

    spelling
  end
end
