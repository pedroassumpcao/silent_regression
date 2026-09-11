defmodule SilentRegression.Spike.SemanticLayer.Representation do
  @moduledoc """
  Common behavior and fitting boundary for local semantic representations.

  Each method extracts inspectable sparse features. Corpus-derived IDF values
  are fitted only from the caller-supplied null observations. Features first
  seen after fitting remain visible and receive the maximum smoothed IDF;
  candidate-only facts are therefore not silently discarded.
  """

  alias SilentRegression.Spike.SemanticLayer.Representation.CharacterNgram
  alias SilentRegression.Spike.SemanticLayer.Representation.FieldAware
  alias SilentRegression.Spike.SemanticLayer.Representation.WordNgram
  alias SilentRegression.Spike.SemanticLayer.RepresentationModel

  @type feature_counts :: %{optional(String.t()) => pos_integer()}
  @type vector :: %{optional(String.t()) => float()}
  @type error :: %{required(:type) => atom(), optional(atom()) => term()}

  @callback method_name() :: String.t()
  @callback method_version() :: pos_integer()
  @callback parameters() :: map()
  @callback features(String.t()) :: {:ok, feature_counts()} | {:error, error()}

  @methods [WordNgram, CharacterNgram, FieldAware]

  @doc "Returns the frozen method modules in benchmark order."
  @spec methods() :: [module()]
  def methods, do: @methods

  @doc "Returns immutable public metadata for a representation method."
  @spec metadata(module()) :: map()
  def metadata(module) when module in @methods do
    %{
      "name" => module.method_name(),
      "version" => module.method_version(),
      "parameters" => module.parameters()
    }
  end

  @doc "Fits smoothed IDF document frequencies from unlabeled null text."
  @spec fit(module(), [String.t()]) :: {:ok, RepresentationModel.t()} | {:error, error()}
  def fit(module, documents) when module in @methods and is_list(documents) do
    cond do
      documents == [] ->
        {:error, %{type: :insufficient_fit_data, minimum_count: 1, actual_count: 0}}

      not Enum.all?(documents, &is_binary/1) ->
        {:error, %{type: :invalid_fit_data, reason: :documents_must_be_strings}}

      true ->
        with {:ok, feature_sets} <- extract_feature_sets(module, documents) do
          document_frequencies =
            Enum.reduce(feature_sets, %{}, fn features, frequencies ->
              Enum.reduce(features, frequencies, fn feature, accumulated ->
                Map.update(accumulated, feature, 1, &(&1 + 1))
              end)
            end)

          {:ok,
           %RepresentationModel{
             method_name: module.method_name(),
             method_version: module.method_version(),
             parameters: module.parameters(),
             document_count: length(documents),
             document_frequencies: document_frequencies
           }}
        end
    end
  end

  def fit(module, _documents) when module in @methods,
    do: {:error, %{type: :invalid_fit_data, reason: :documents_must_be_a_list}}

  def fit(module, _documents),
    do: {:error, %{type: :unsupported_representation, module: module}}

  @doc "Encodes text as an L2-normalized, sublinear-TF/smoothed-IDF sparse vector."
  @spec encode(RepresentationModel.t(), String.t()) :: {:ok, vector()} | {:error, error()}
  def encode(%RepresentationModel{} = model, text) when is_binary(text) do
    with {:ok, module} <- module_for(model.method_name, model.method_version),
         true <- model.parameters == module.parameters(),
         {:ok, counts} <- module.features(text) do
      weighted =
        Map.new(counts, fn {feature, count} ->
          term_frequency = 1.0 + :math.log(count)
          document_frequency = Map.get(model.document_frequencies, feature, 0)

          inverse_document_frequency =
            :math.log((1.0 + model.document_count) / (1.0 + document_frequency)) + 1.0

          {feature, term_frequency * inverse_document_frequency}
        end)

      {:ok, l2_normalize(weighted)}
    else
      false -> {:error, %{type: :representation_parameters_changed}}
      {:error, error} -> {:error, error}
    end
  end

  def encode(%RepresentationModel{}, _text),
    do: {:error, %{type: :invalid_text, reason: :must_be_a_string}}

  def encode(_model, _text), do: {:error, %{type: :invalid_representation_model}}

  @doc "Returns cosine distance for two sparse, normalized vectors."
  @spec distance(vector(), vector()) :: float()
  def distance(left, right) when is_map(left) and is_map(right) do
    cond do
      map_size(left) == 0 and map_size(right) == 0 ->
        0.0

      map_size(left) == 0 or map_size(right) == 0 ->
        1.0

      true ->
        {smaller, larger} =
          if map_size(left) <= map_size(right), do: {left, right}, else: {right, left}

        similarity =
          Enum.reduce(smaller, 0.0, fn {feature, value}, total ->
            total + value * Map.get(larger, feature, 0.0)
          end)

        1.0 - min(1.0, max(0.0, similarity))
    end
  end

  @doc "Builds the function options consumed by the shared statistics module."
  @spec statistics_options(RepresentationModel.t()) :: keyword()
  def statistics_options(%RepresentationModel{} = model) do
    [
      normalizer: fn text -> encode(model, text) end,
      distance: &distance/2
    ]
  end

  defp module_for(name, version) do
    case Enum.find(@methods, &(&1.method_name() == name and &1.method_version() == version)) do
      nil -> {:error, %{type: :unsupported_representation, name: name, version: version}}
      module -> {:ok, module}
    end
  end

  defp extract_feature_sets(module, documents) do
    documents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {document, index}, {:ok, sets} ->
      case module.features(document) do
        {:ok, counts} -> {:cont, {:ok, [Map.keys(counts) | sets]}}
        {:error, error} -> {:halt, {:error, Map.put(error, :document_index, index)}}
      end
    end)
    |> then(fn
      {:ok, sets} -> {:ok, Enum.reverse(sets)}
      {:error, error} -> {:error, error}
    end)
  end

  defp l2_normalize(vector) when map_size(vector) == 0, do: vector

  defp l2_normalize(vector) do
    norm = vector |> Map.values() |> Enum.reduce(0.0, &(&2 + &1 * &1)) |> :math.sqrt()
    Map.new(vector, fn {feature, value} -> {feature, value / norm} end)
  end
end
