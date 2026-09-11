defmodule SilentRegression.Spike.SemanticLayer.Representation.CharacterNgram do
  @moduledoc """
  Unicode character n-grams inside normalized word boundaries.

  Isolating n-grams within words makes punctuation and layout changes inert
  while retaining partial overlap for small spelling and morphology changes.
  """

  @behaviour SilentRegression.Spike.SemanticLayer.Representation

  @parameters %{
    "minimum_n" => 3,
    "maximum_n" => 5,
    "boundary_mode" => "within_word",
    "lowercase" => true,
    "term_frequency" => "sublinear",
    "inverse_document_frequency" => "smooth",
    "distance" => "cosine"
  }

  @impl true
  def method_name, do: "character_ngram"

  @impl true
  def method_version, do: 1

  @impl true
  def parameters, do: @parameters

  @impl true
  def features(text) when is_binary(text) do
    words =
      text
      |> :unicode.characters_to_nfkc_binary()
      |> String.downcase()
      |> then(&Regex.scan(~r/[\p{L}\p{N}]+/u, &1))
      |> List.flatten()

    features =
      for word <- words,
          size <- @parameters["minimum_n"]..@parameters["maximum_n"],
          ngram <- word_ngrams(word, size),
          do: "char:#{size}:#{ngram}"

    {:ok, Enum.frequencies(features)}
  end

  def features(_text), do: {:error, %{type: :invalid_text, reason: :must_be_a_string}}

  defp word_ngrams(word, size) do
    graphemes = String.graphemes(" #{word} ")

    if length(graphemes) < size do
      []
    else
      graphemes
      |> Enum.chunk_every(size, 1, :discard)
      |> Enum.map(&Enum.join/1)
    end
  end
end
