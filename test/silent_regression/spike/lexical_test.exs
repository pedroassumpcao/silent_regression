defmodule SilentRegression.Spike.LexicalTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Lexical

  describe "normalize/1" do
    test "uses NFKC, full Unicode case folding, and punctuation boundaries" do
      assert {:ok, words} = Lexical.normalize("  Ｃafé—Straße, FERRY's!  ")
      assert words == MapSet.new(["café", "strasse", "ferry", "s"])
    end

    test "ignores word frequency" do
      assert Lexical.normalize("red red RED ferry") == Lexical.normalize("red ferry")
    end

    test "returns an empty set for punctuation and whitespace only" do
      assert {:ok, words} = Lexical.normalize(" ... \n— ")
      assert MapSet.size(words) == 0
    end

    test "rejects non-strings and invalid UTF-8" do
      assert {:error, %{type: :invalid_text, reason: :must_be_a_string}} = Lexical.normalize(nil)

      assert {:error, %{type: :invalid_text, reason: :must_be_valid_utf8}} =
               Lexical.normalize(<<255>>)
    end
  end

  describe "Jaccard comparison" do
    test "matches a hand-computed example" do
      assert {:ok, similarity} = Lexical.jaccard_similarity("a b b", "b c")
      assert {:ok, distance} = Lexical.jaccard_distance("a b b", "b c")

      assert_in_delta similarity, 1 / 3, 1.0e-12
      assert_in_delta distance, 2 / 3, 1.0e-12
    end

    test "defines both empty-set cases" do
      assert {:ok, 1.0} = Lexical.jaccard_similarity("", "...")
      assert {:ok, empty_distance} = Lexical.jaccard_distance("", "...")
      assert {:ok, empty_similarity} = Lexical.jaccard_similarity("", "word")
      assert {:ok, 1.0} = Lexical.jaccard_distance("", "word")

      assert empty_distance == 0.0
      assert empty_similarity == 0.0
    end

    test "is symmetric, bounded, and zero for self-comparison" do
      samples = ["", "red ferry", "Red, red FERRY!", "blue harbor", "船 港"]

      for left <- samples, right <- samples do
        assert {:ok, left_to_right} = Lexical.jaccard_distance(left, right)
        assert {:ok, right_to_left} = Lexical.jaccard_distance(right, left)

        assert_in_delta left_to_right, right_to_left, 1.0e-12
        assert left_to_right >= 0.0
        assert left_to_right <= 1.0
      end

      for sample <- samples do
        assert {:ok, distance} = Lexical.jaccard_distance(sample, sample)
        assert distance == 0.0
      end
    end

    test "propagates input validation errors" do
      assert {:error, %{type: :invalid_text, reason: :must_be_a_string}} =
               Lexical.jaccard_distance("valid", nil)
    end
  end
end
