defmodule Mix.Tasks.DriftSpike.PromoteSemanticPairsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.DriftSpike.PromoteSemanticPairs
  alias SilentRegression.Spike.SemanticLayer.PairedFixtureSet
  alias SilentRegression.Spike.SemanticLayer.Storage, as: SemanticStorage

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous_shell) end)
  end

  @tag :tmp_dir
  test "validates a complete review and writes immutable approved copies", %{tmp_dir: tmp_dir} do
    tuning_path = Path.join(tmp_dir, "tuning-candidate.json")
    heldout_path = Path.join(tmp_dir, "heldout-candidate.json")
    review_log_path = Path.join(tmp_dir, "REVIEW_LOG.md")
    output_directory = Path.join(tmp_dir, "approved")

    :ok = SemanticStorage.write(tuning_path, candidate_fixture_set("tuning"))
    :ok = SemanticStorage.write(heldout_path, candidate_fixture_set("heldout"))

    tuning_bytes = File.read!(tuning_path)
    heldout_bytes = File.read!(heldout_path)
    tuning_sha256 = sha256(tuning_bytes)
    heldout_sha256 = sha256(heldout_bytes)
    File.write!(review_log_path, complete_review_log(tuning_sha256, heldout_sha256))

    arguments = [
      "--tuning",
      tuning_path,
      "--heldout",
      heldout_path,
      "--review-log",
      review_log_path,
      "--reviewer",
      "product_owner",
      "--output",
      output_directory
    ]

    dry_run_output = capture_io(fn -> PromoteSemanticPairs.run(arguments ++ ["--dry-run"]) end)
    assert dry_run_output =~ "Semantic paired fixture promotion (dry run)"
    assert dry_run_output =~ "Approved judgments: 120/120"
    assert dry_run_output =~ "Provider calls: 0"
    assert dry_run_output =~ "No artifacts were written."
    refute File.exists?(output_directory)

    output = capture_io(fn -> PromoteSemanticPairs.run(arguments) end)
    assert output =~ "Semantic paired fixtures promoted"
    assert output =~ "Candidate artifacts were not changed."

    assert File.read!(tuning_path) == tuning_bytes
    assert File.read!(heldout_path) == heldout_bytes

    assert {:ok, tuning} = SemanticStorage.read(Path.join(output_directory, "tuning-pairs.json"))

    assert {:ok, heldout} =
             SemanticStorage.read(Path.join(output_directory, "heldout-pairs.json"))

    for fixture_set <- [tuning, heldout] do
      assert fixture_set.status == "approved"
      assert length(fixture_set.fixtures) == 60

      assert Enum.all?(fixture_set.fixtures, fn fixture ->
               fixture["approval"]["status"] == "approved" and
                 fixture["approval"]["reviewer"] == "product_owner" and
                 is_binary(fixture["approval"]["reviewed_at"])
             end)
    end

    assert_raise Mix.Error, ~r/Refusing to overwrite/, fn ->
      capture_io(fn -> PromoteSemanticPairs.run(arguments) end)
    end
  end

  @tag :tmp_dir
  test "refuses an incomplete review log or mismatched candidate hash", %{tmp_dir: tmp_dir} do
    tuning_path = Path.join(tmp_dir, "tuning-candidate.json")
    heldout_path = Path.join(tmp_dir, "heldout-candidate.json")
    review_log_path = Path.join(tmp_dir, "REVIEW_LOG.md")

    :ok = SemanticStorage.write(tuning_path, candidate_fixture_set("tuning"))
    :ok = SemanticStorage.write(heldout_path, candidate_fixture_set("heldout"))
    File.write!(review_log_path, "- Approved: 120/120 judgments — complete\n")

    arguments = [
      "--tuning",
      tuning_path,
      "--heldout",
      heldout_path,
      "--review-log",
      review_log_path,
      "--reviewer",
      "product_owner",
      "--output",
      Path.join(tmp_dir, "approved"),
      "--dry-run"
    ]

    assert_raise Mix.Error, ~r/Review log is incomplete or does not match/, fn ->
      capture_io(fn -> PromoteSemanticPairs.run(arguments) end)
    end
  end

  defp candidate_fixture_set(split) do
    fixtures =
      for parent <- 0..19,
          label <- ~w(meaning_preserving style_only subtle_regression) do
        %{
          "fixture_id" => "#{split}-#{parent}-#{label}",
          "parent_observation_id" => "#{split}-control:rag_open_synthesis:#{parent}",
          "parent_sample_index" => parent,
          "parent_output_sha256" => sha256("#{split}-parent-#{parent}"),
          "case_id" => "rag_open_synthesis",
          "split" => split,
          "label" => label,
          "failure_modes" => if(label == "subtle_regression", do: ["wrong_fact"], else: []),
          "expected_contract_pass" => label != "subtle_regression",
          "rationale" => "Reviewed #{label} judgment for parent #{parent}.",
          "output_text" => "Distinct #{split} #{label} output for parent #{parent}.",
          "approval" => %{"status" => "candidate", "reviewer" => nil, "reviewed_at" => nil}
        }
      end

    {:ok, fixture_set} =
      PairedFixtureSet.new(%{
        fixture_set_id: "semantic-pairs-#{split}-v1",
        created_at: ~U[2026-09-10 19:00:00Z],
        git_revision: "candidate123",
        status: "candidate",
        source_control: %{
          "run_id" => "#{split}-control",
          "condition" => "control",
          "artifact_sha256" => sha256("#{split}-control"),
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

  defp complete_review_log(tuning_sha256, heldout_sha256) do
    approvals = [
      "Approve tuning parents 1–5",
      "Approve tuning parents 6–10",
      "Approve tuning parents 11–15",
      "Approve tuning parents 16–20",
      "Approve held-out parents 1–5",
      "Approve held-out parents 6–10",
      "Approve held-out parents 11–15",
      "Approve held-out parents 16–20"
    ]

    """
    - Tuning candidate SHA-256: `#{tuning_sha256}`
    - Held-out candidate SHA-256: `#{heldout_sha256}`
    - Approved: 120/120 judgments — complete
    - Tuning: 60/60 approved — complete
    - Held-out: 60/60 approved — complete
    - Corrections requested: 0
    #{Enum.join(approvals, "\n")}
    """
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
