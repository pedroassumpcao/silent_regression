defmodule SilentRegression.Spike.Lexical do
  @moduledoc """
  Unicode-aware word-set normalization and Jaccard comparison.

  Text is normalized with Unicode NFKC, full Unicode case folding, and a split
  at every run of non-letter/non-number characters. Empty tokens are removed.
  The result is a `MapSet`, so repeated words intentionally have no additional
  weight in this first, inexpensive lexical layer.

  Two empty sets have similarity `1.0` and distance `0.0`. Comparing one empty
  set with a non-empty set has similarity `0.0` and distance `1.0`.
  """

  @type error :: %{required(:type) => atom(), optional(:reason) => atom()}

  @doc """
  Normalizes text into its unique word set.
  """
  @spec normalize(term()) :: {:ok, MapSet.t(String.t())} | {:error, error()}
  def normalize(text) when is_binary(text) do
    if String.valid?(text) do
      words =
        text
        |> :unicode.characters_to_nfkc_binary()
        |> :string.casefold()
        |> :unicode.characters_to_binary()
        |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

      {:ok, MapSet.new(words)}
    else
      {:error, %{type: :invalid_text, reason: :must_be_valid_utf8}}
    end
  end

  def normalize(_text), do: {:error, %{type: :invalid_text, reason: :must_be_a_string}}

  @doc """
  Computes Jaccard similarity between two strings.
  """
  @spec jaccard_similarity(term(), term()) :: {:ok, float()} | {:error, error()}
  def jaccard_similarity(left, right) do
    with {:ok, left_set} <- normalize(left),
         {:ok, right_set} <- normalize(right) do
      {:ok, set_similarity(left_set, right_set)}
    end
  end

  @doc """
  Computes Jaccard distance (`1 - similarity`) between two strings.
  """
  @spec jaccard_distance(term(), term()) :: {:ok, float()} | {:error, error()}
  def jaccard_distance(left, right) do
    with {:ok, similarity} <- jaccard_similarity(left, right) do
      {:ok, 1.0 - similarity}
    end
  end

  @doc false
  @spec set_distance(MapSet.t(), MapSet.t()) :: float()
  def set_distance(%MapSet{} = left, %MapSet{} = right) do
    1.0 - set_similarity(left, right)
  end

  defp set_similarity(left, right) do
    union_size = left |> MapSet.union(right) |> MapSet.size()

    if union_size == 0 do
      1.0
    else
      intersection_size = left |> MapSet.intersection(right) |> MapSet.size()
      intersection_size / union_size
    end
  end
end
