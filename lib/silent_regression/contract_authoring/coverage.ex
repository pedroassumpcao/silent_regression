defmodule SilentRegression.ContractAuthoring.Coverage do
  @moduledoc """
  Computes rule-specific fixture proof for the bounded flat authoring model.

  Only complete fixtures whose overall and per-rule outcomes match the owner's
  judgment count as proof. Critical rules require at least one matching pass
  and one matching failure, unless an owner waiver matches the exact rule
  fingerprint. Warning-rule gaps remain visible but do not block approval.
  """

  alias SilentRegression.ContractAuthoring.CoverageWaiver
  alias SilentRegression.Monitors.Fingerprint

  @schema_version "rule_coverage_v1"

  def schema_version, do: @schema_version

  def analyze(%{"type" => "all", "rules" => rules}, fixture_results, waivers)
      when is_list(rules) and is_list(fixture_results) and is_list(waivers) do
    matching_results = Enum.filter(fixture_results, & &1.matches?)
    waivers_by_rule = Map.new(waivers, &{&1.rule_id, &1})

    rule_coverage =
      Enum.map(rules, fn rule ->
        rule_id = rule["id"]
        rule_fingerprint = rule_fingerprint(rule)
        severity = effective_severity(rule)
        waiver = valid_waiver(Map.get(waivers_by_rule, rule_id), rule_fingerprint)

        positive_fixture_ids = fixture_ids_with_status(matching_results, rule_id, "pass")
        negative_fixture_ids = fixture_ids_with_status(matching_results, rule_id, "fail")
        missing = missing_branches(positive_fixture_ids, negative_fixture_ids)

        %{
          rule_id: rule_id,
          rule_type: rule["type"],
          rule_fingerprint: rule_fingerprint,
          severity: severity,
          positive_fixture_ids: positive_fixture_ids,
          negative_fixture_ids: negative_fixture_ids,
          positive_proven?: positive_fixture_ids != [],
          negative_proven?: negative_fixture_ids != [],
          missing_branches: missing,
          blocking?: severity == :critical and missing != [] and is_nil(waiver),
          waiver: waiver_prop(waiver)
        }
      end)

    blockers =
      for rule <- rule_coverage, rule.blocking? do
        branches = Enum.map_join(rule.missing_branches, " and ", &Atom.to_string/1)

        %{
          code: "rule_proof_missing",
          message:
            "Critical rule #{rule.rule_id} needs matching #{branches} fixture proof or an owner waiver.",
          fixture_id: nil,
          rule_id: rule.rule_id,
          missing_branches: rule.missing_branches
        }
      end

    fingerprint =
      Fingerprint.digest(%{
        "proof_schema_version" => @schema_version,
        "rules" => Enum.map(rule_coverage, &fingerprint_rule/1)
      })

    %{
      schema_version: @schema_version,
      fingerprint: fingerprint,
      ready?: blockers == [],
      blockers: blockers,
      rules: rule_coverage
    }
  end

  def rule_fingerprint(rule) when is_map(rule) do
    Fingerprint.digest(%{
      "fingerprint_schema" => "contract-rule-v1",
      "rule" => rule
    })
  end

  defp effective_severity(%{"severity" => "warning"}), do: :warning
  defp effective_severity(_rule), do: :critical

  defp fixture_ids_with_status(results, rule_id, status) do
    results
    |> Enum.filter(&(&1.actual_rule_statuses[rule_id] == status))
    |> Enum.map(& &1.fixture.id)
    |> Enum.sort()
  end

  defp missing_branches(positive_ids, negative_ids) do
    []
    |> maybe_add_branch(positive_ids == [], :positive)
    |> maybe_add_branch(negative_ids == [], :negative)
  end

  defp maybe_add_branch(branches, true, branch), do: branches ++ [branch]
  defp maybe_add_branch(branches, false, _branch), do: branches

  defp valid_waiver(%CoverageWaiver{rule_fingerprint: fingerprint} = waiver, fingerprint),
    do: waiver

  defp valid_waiver(_waiver, _fingerprint), do: nil

  defp waiver_prop(nil), do: nil

  defp waiver_prop(waiver) do
    %{
      id: waiver.id,
      rationale: waiver.rationale,
      waived_by_user_id: waiver.waived_by_user_id,
      waived_at: DateTime.to_iso8601(waiver.inserted_at)
    }
  end

  defp fingerprint_rule(rule) do
    %{
      "rule_id" => rule.rule_id,
      "rule_fingerprint" => rule.rule_fingerprint,
      "severity" => Atom.to_string(rule.severity),
      "positive_fixture_ids" => rule.positive_fixture_ids,
      "negative_fixture_ids" => rule.negative_fixture_ids,
      "waiver" => fingerprint_waiver(rule.waiver)
    }
  end

  defp fingerprint_waiver(nil), do: nil

  defp fingerprint_waiver(waiver) do
    %{
      "rationale" => waiver.rationale,
      "waived_by_user_id" => waiver.waived_by_user_id,
      "waived_at" => waiver.waived_at
    }
  end
end
