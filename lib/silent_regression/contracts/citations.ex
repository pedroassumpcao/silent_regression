defmodule SilentRegression.Contracts.Citations do
  @moduledoc false

  alias SilentRegression.Contracts.Text

  @citation ~r/\[([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\](?!\()/

  @type citation :: %{id: String.t(), byte_offset: non_neg_integer()}

  @spec extract(String.t()) :: [citation()]
  def extract(output) when is_binary(output) do
    @citation
    |> Regex.scan(output, capture: :all, return: :index)
    |> Enum.map(fn [{start, _length}, {id_start, id_length}] ->
      %{id: binary_part(output, id_start, id_length), byte_offset: start}
    end)
  end

  @spec ids([citation()]) :: [String.t()]
  def ids(citations), do: citations |> Enum.map(& &1.id) |> Enum.uniq()

  @spec attributed_match(String.t(), [citation()], [String.t()], [String.t()], pos_integer()) ::
          {:ok, map()} | :error
  def attributed_match(output, citations, alternatives, source_ids, max_distance) do
    Enum.find_value(citations, :error, fn citation ->
      if citation.id in source_ids do
        segment = preceding_segment(output, citation.byte_offset, max_distance)

        case Enum.find(alternatives, &Text.contains_literal?(segment, &1)) do
          nil -> false
          alternative -> {:ok, %{"fact" => alternative, "source_id" => citation.id}}
        end
      else
        false
      end
    end)
  end

  defp preceding_segment(output, citation_offset, max_distance) do
    prefix = binary_part(output, 0, citation_offset)

    prefix
    |> String.graphemes()
    |> Enum.take(-max_distance)
    |> Enum.join()
    |> String.split(~r/[.!?\n]/u)
    |> List.last()
    |> to_string()
  end
end
