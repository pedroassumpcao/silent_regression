defmodule SilentRegression.Spike.SemanticLayer.Representation.FieldAware do
  @moduledoc """
  Extracts generic JSON fields and prose facts recoverable without a model.

  Prose features cover citations, quantities, normalized polarity, and their
  segment-local attribution. The extractor contains no monitor-specific facts.
  """

  @behaviour SilentRegression.Spike.SemanticLayer.Representation

  @parameters %{
    "features" => [
      "json_path",
      "json_path_value",
      "citation",
      "quantity",
      "polarity",
      "citation_quantity",
      "citation_polarity"
    ],
    "term_frequency" => "sublinear",
    "inverse_document_frequency" => "smooth",
    "distance" => "cosine"
  }

  @negative_words ~w(no not never prohibited forbidden barred banned cannot)
  @positive_words ~w(allowed permitted authorized)

  @impl true
  def method_name, do: "field_aware"

  @impl true
  def method_version, do: 1

  @impl true
  def parameters, do: @parameters

  @impl true
  def features(text) when is_binary(text) do
    normalized = text |> :unicode.characters_to_nfkc_binary() |> String.downcase()
    prose_features = prose_features(normalized)
    json_features = json_features(normalized)
    {:ok, Enum.frequencies(json_features ++ prose_features)}
  end

  def features(_text), do: {:error, %{type: :invalid_text, reason: :must_be_a_string}}

  defp prose_features(text) do
    citations = citations(text)
    quantities = quantities(text)
    polarities = polarities(text)

    global =
      Enum.map(citations, &"citation:#{&1}") ++
        Enum.map(quantities, &"quantity:#{&1}") ++
        Enum.map(polarities, &"polarity:#{&1}")

    attributed =
      text
      |> segments()
      |> Enum.flat_map(fn segment ->
        for citation <- citations(segment), quantity <- quantities(segment) do
          "citation_quantity:#{citation}:#{quantity}"
        end ++
          for citation <- citations(segment), polarity <- polarities(segment) do
            "citation_polarity:#{citation}:#{polarity}"
          end
      end)

    global ++ attributed
  end

  defp citations(text) do
    ~r/\[([\p{L}\p{N}][\p{L}\p{N}._:-]*)\]/u
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
  end

  defp quantities(text) do
    ~r/\b\d+(?:[.,]\d+)?\b/u
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, ",", ""))
  end

  defp polarities(text) do
    words = Regex.scan(~r/[\p{L}]+/u, text) |> List.flatten()

    Enum.flat_map(words, fn word ->
      cond do
        word in @negative_words -> ["negative"]
        word in @positive_words -> ["positive"]
        true -> []
      end
    end)
  end

  defp segments(text) do
    Regex.split(~r/(?:[.!?]+\s+)|(?:\n+)/u, text, trim: true)
  end

  defp json_features(text) do
    case Jason.decode(text) do
      {:ok, value} -> flatten_json(value, "$")
      {:error, _reason} -> []
    end
  end

  defp flatten_json(value, path) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {key, child} ->
      child_path = "#{path}.#{normalize_scalar(key)}"
      ["json_path:#{child_path}" | flatten_json(child, child_path)]
    end)
  end

  defp flatten_json(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} ->
      child_path = "#{path}[#{index}]"
      ["json_path:#{child_path}" | flatten_json(child, child_path)]
    end)
  end

  defp flatten_json(value, path), do: ["json_path_value:#{path}=#{normalize_scalar(value)}"]

  defp normalize_scalar(value) when is_binary(value),
    do: value |> String.trim() |> String.replace(~r/\s+/u, " ")

  defp normalize_scalar(value), do: Jason.encode!(value)
end
