defmodule SilentRegression.ContractAuthoring.Fingerprints do
  @moduledoc false

  alias SilentRegression.Monitors.Fingerprint

  def fixture(attributes) do
    Fingerprint.digest(%{
      "fingerprint_schema" => "contract-fixture-v1",
      "name" => attributes.name,
      "position" => attributes.position,
      "output_text" => attributes.output_text,
      "expected_status" => status_string(attributes.expected_status),
      "expected_rule_statuses" => attributes.expected_rule_statuses
    })
  end

  def fixture_set(fixtures) do
    fixture_fingerprints =
      fixtures
      |> Enum.sort_by(&{&1.position, &1.id})
      |> Enum.map(&%{"position" => &1.position, "fingerprint" => &1.fingerprint})

    Fingerprint.digest(%{
      "fingerprint_schema" => "contract-fixture-set-v1",
      "fixtures" => fixture_fingerprints
    })
  end

  def version(attributes) do
    Fingerprint.digest(%{
      "fingerprint_schema" => "contract-approval-v1",
      "schema_version" => attributes.schema_version,
      "evaluator_engine_version" => attributes.evaluator_engine_version,
      "template_key" => attributes.template_key,
      "template_usage" => attributes.template_usage,
      "assistance_mode" => status_string(attributes.assistance_mode),
      "contract_fingerprint" => attributes.contract_fingerprint,
      "fixture_set_fingerprint" => attributes.fixture_set_fingerprint
    })
  end

  defp status_string(value) when is_atom(value), do: Atom.to_string(value)
  defp status_string(value), do: value
end
