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
      [first, second | _rest] = Expression.completions(["order.total", "customer.tier"])

      assert first == %{
               label: "order.total",
               insert: "order.total",
               kind: "path",
               detail: "declared path"
             }

      assert second.insert == "customer.tier"
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
      assert Expression.completions(["order.total"]) == [
               %{
                 label: "order.total",
                 insert: "order.total",
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
      kept = Expression.completions(["order.total"]) |> Expression.datalist()
      insertions = Enum.map(kept, & &1.insert)

      assert "order.total" in insertions
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

      assert {:ok, [bracketed], nil} = Expression.simple("cart['items'] contains 'gift'")
      assert bracketed.path == "cart['items']"
      assert bracketed.segments == [root: "cart", key: "items"]
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

    test "every path parses back to the segments it was rendered from" do
      for path <- ["status", "card.brand", "cart['items']", "signup.created_at"] do
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
            "cart['items'] contains 'gift'"
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
      assert Expression.segments("cart['items']") == {:ok, [root: "cart", key: "items"]}
    end

    test "segments/1 refuses a string that is not a path" do
      for source <- ["amount >= 500", "len(plan)", "", "'pro'"] do
        assert Expression.segments(source) == :error
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
end
