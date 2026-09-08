defmodule SilentRegression.SpikeFakeProvider do
  @moduledoc false

  @behaviour SilentRegression.Spike.Provider

  @impl true
  def id, do: "fake"

  @impl true
  def request_provenance do
    %{
      "api_endpoint" => "https://fake.invalid/v1/completions",
      "api_version" => "v1",
      "http_method" => "POST"
    }
  end

  @impl true
  def complete(case_definition, options) do
    options
    |> Keyword.fetch!(:callback)
    |> then(& &1.(case_definition, options))
  end
end
