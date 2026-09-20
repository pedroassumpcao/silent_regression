defmodule SilentRegression.Monitors.Fingerprint do
  @moduledoc """
  Stable SHA-256 fingerprints for normalized, JSON-compatible product data.
  """

  def digest(value) do
    value
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def case_digest(case_attributes) do
    digest(%{
      "fingerprint_schema" => "case-version-v1",
      "case_key" => case_attributes.case_key,
      "status" => Atom.to_string(case_attributes.status),
      "input_variables" => case_attributes.input_variables,
      "frozen_context" => case_attributes.frozen_context
    })
  end

  def case_set_digest(cases) do
    case_fingerprints =
      cases
      |> Enum.sort_by(& &1.case_key)
      |> Enum.map(&%{"case_key" => &1.case_key, "fingerprint" => &1.fingerprint})

    digest(%{
      "fingerprint_schema" => "case-set-v1",
      "cases" => case_fingerprints
    })
  end

  def monitor_version_digest(%{request_mode: :provider_native_v1} = attributes) do
    digest(%{
      "fingerprint_schema" => "monitor-version-v2",
      "schema_version" => attributes.schema_version,
      "provider" => Atom.to_string(attributes.provider),
      "requested_model" => attributes.requested_model,
      "request_mode" => "provider_native_v1",
      "request_schema_version" => attributes.request_schema_version,
      "effective_requests" => attributes.request_artifact_fingerprints,
      "case_set_fingerprint" => attributes.case_set_fingerprint
    })
  end

  def monitor_version_digest(attributes) do
    digest(%{
      "fingerprint_schema" => "monitor-version-v1",
      "schema_version" => attributes.schema_version,
      "provider" => Atom.to_string(attributes.provider),
      "requested_model" => attributes.requested_model,
      "system_prompt" => attributes.system_prompt,
      "user_prompt_template" => attributes.user_prompt_template,
      "response_format" => attributes.response_format,
      "generation_config" => attributes.generation_config,
      "case_set_fingerprint" => attributes.case_set_fingerprint
    })
  end

  defp canonicalize(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested_value} -> {key, canonicalize(nested_value)} end)
      |> Enum.sort_by(fn {key, _nested_value} -> key end)

    {:map, entries}
  end

  defp canonicalize(value) when is_list(value), do: {:list, Enum.map(value, &canonicalize/1)}
  defp canonicalize(value), do: value
end
