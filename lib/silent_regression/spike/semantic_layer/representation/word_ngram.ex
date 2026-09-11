defmodule SilentRegression.Spike.SemanticLayer.Representation.WordNgram do
  @moduledoc """
  Unicode word unigram/bigram representation retaining limited local order.
  """

  @behaviour SilentRegression.Spike.SemanticLayer.Representation

  @parameters %{
    "minimum_n" => 1,
    "maximum_n" => 2,
    "lowercase" => true,
    "term_frequency" => "sublinear",
    "inverse_document_frequency" => "smooth",
    "distance" => "cosine"
  }

  @impl true
  def method_name, do: "word_ngram"

  @impl true
  def method_version, do: 1

  @impl true
  def parameters, do: @parameters

  @impl true
  def features(text) when is_binary(text) do
    tokens =
      text
      |> :unicode.characters_to_nfkc_binary()
      |> String.downcase()
      |> then(&Regex.scan(~r/[\p{L}\p{N}]+/u, &1))
      |> List.flatten()

    features =
      for size <- @parameters["minimum_n"]..@parameters["maximum_n"],
          ngram <- ngrams(tokens, size),
          do: "word:#{size}:#{Enum.join(ngram, " ")}"

    {:ok, Enum.frequencies(features)}
  end

  def features(_text), do: {:error, %{type: :invalid_text, reason: :must_be_a_string}}

  defp ngrams(tokens, size) when length(tokens) < size, do: []
  defp ngrams(tokens, size), do: Enum.chunk_every(tokens, size, 1, :discard)
end
