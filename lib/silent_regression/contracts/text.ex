defmodule SilentRegression.Contracts.Text do
  @moduledoc """
  Fixed literal-text normalization for deterministic contract version 1.

  This is deliberately a syntactic transformation, not a semantic comparison.
  """

  @spec normalize(String.t()) :: String.t()
  def normalize(value) when is_binary(value) do
    if String.valid?(value) do
      value
      |> :unicode.characters_to_nfkc_binary()
      |> :string.casefold()
      |> :unicode.characters_to_binary()
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
    else
      ""
    end
  end

  @spec contains_literal?(String.t(), String.t()) :: boolean()
  def contains_literal?(text, literal) when is_binary(text) and is_binary(literal) do
    text
    |> normalize()
    |> contains_normalized_literal?(literal)
  end

  @spec contains_normalized_literal?(String.t(), String.t()) :: boolean()
  def contains_normalized_literal?(normalized_text, literal)
      when is_binary(normalized_text) and is_binary(literal) do
    normalized_literal = normalize(literal)

    normalized_literal != "" and
      String.contains?(" #{normalized_text} ", " #{normalized_literal} ")
  end

  @spec word_count(String.t()) :: non_neg_integer()
  def word_count(text) when is_binary(text) do
    case normalize(text) do
      "" -> 0
      normalized -> normalized |> String.split(" ", trim: true) |> length()
    end
  end
end
