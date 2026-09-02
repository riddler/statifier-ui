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
end
