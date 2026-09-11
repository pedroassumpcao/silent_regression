defmodule SilentRegression.Spike.SemanticLayer.PairedFixturePromotionTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.PairedFixturePromotion
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet

  test "creates a separately identified approved copy without mutating its candidate" do
    candidate = candidate_fixture_set()

    assert {:ok, approved} =
             PairedFixturePromotion.promote(candidate, "product_owner",
               clock: fn -> ~U[2026-09-10 20:00:00.987654Z] end,
               git_revision: "abc123"
             )

    assert candidate.status == "candidate"
    assert candidate.fixture_set_id == "semantic-pairs-tuning-v1"
    assert Enum.all?(candidate.fixtures, &(&1["approval"] == candidate_approval()))

    assert approved.status == "approved"
    assert approved.fixture_set_id == "semantic-pairs-tuning-v1-approved"
    assert approved.created_at == ~U[2026-09-10 20:00:00Z]
    assert approved.git_revision == "abc123"
    assert approved.source_control == candidate.source_control
    assert approved.partition_policy == candidate.partition_policy
    assert approved.duplicate_counts == candidate.duplicate_counts

    assert Enum.all?(approved.fixtures, fn fixture ->
             fixture["approval"] == %{
               "status" => "approved",
               "reviewer" => "product_owner",
               "reviewed_at" => "2026-09-10T20:00:00Z"
             }
           end)
  end

  test "rejects invalid reviewers, already approved sets, and partial approval state" do
    candidate = candidate_fixture_set()

    assert {:error, %{"type" => "configuration_error"}} =
             PairedFixturePromotion.promote(candidate, "")

    {:ok, approved} = PairedFixturePromotion.promote(candidate, "product_owner")

    assert {:error, %{"type" => "invalid_candidate"}} =
             PairedFixturePromotion.promote(approved, "product_owner")

    partially_approved =
      put_in(candidate.fixtures, [Access.at(0), "approval"], %{
        "status" => "approved",
        "reviewer" => "product_owner",
        "reviewed_at" => "2026-09-10T20:00:00Z"
      })

    candidate = %{candidate | fixtures: partially_approved}

    assert {:error, %{"type" => "invalid_candidate"}} =
             PairedFixturePromotion.promote(candidate, "product_owner")
  end

  defp candidate_fixture_set do
    fixtures =
      for label <- ~w(meaning_preserving style_only subtle_regression) do
        %{
          "fixture_id" => "tuning-parent-1-#{label}",
          "parent_observation_id" => "control:rag_open_synthesis:0",
          "parent_sample_index" => 0,
          "parent_output_sha256" => hash("parent"),
          "case_id" => "rag_open_synthesis",
          "split" => "tuning",
          "label" => label,
          "failure_modes" => if(label == "subtle_regression", do: ["wrong_fact"], else: []),
          "expected_contract_pass" => label != "subtle_regression",
          "rationale" => "Reviewed #{label} judgment.",
          "output_text" => "Distinct #{label} output.",
          "approval" => candidate_approval()
        }
      end

    {:ok, fixture_set} =
      PairedFixtureSet.new(%{
        fixture_set_id: "semantic-pairs-tuning-v1",
        created_at: ~U[2026-09-10 19:00:00Z],
        git_revision: "candidate123",
        status: "candidate",
        source_control: %{
          "run_id" => "control",
          "condition" => "control",
          "artifact_sha256" => hash("control"),
          "case_id" => "rag_open_synthesis"
        },
        partition_policy: %{
          "version" => 1,
          "group_key" => "parent_observation_id",
          "splits" => PairedFixtureSet.splits()
        },
        fixtures: fixtures,
        duplicate_counts: PairedFixtureSet.duplicate_counts(fixtures)
      })

    fixture_set
  end

  defp candidate_approval do
    %{"status" => "candidate", "reviewer" => nil, "reviewed_at" => nil}
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
