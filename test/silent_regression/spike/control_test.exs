defmodule SilentRegression.Spike.ControlTest do
  use ExUnit.Case, async: false

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Control
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFakeProvider
  alias SilentRegression.SpikeFixtures

  @captured_at ~U[2026-09-07 13:00:01Z]
  @run_time ~U[2026-09-07 13:00:00Z]

  @tag :tmp_dir
  test "dry run defaults to twenty samples per case and performs no work", %{tmp_dir: tmp_dir} do
    baseline = fake_baseline(2)
    test_pid = self()
    output_path = Path.join(tmp_dir, "control.json")

    assert {:ok, result} =
             Control.run(baseline, SpikeFakeProvider,
               model: "fake-model",
               max_calls: 21,
               seed: 17,
               dry_run: true,
               run_id: "control-dry-run",
               output_path: output_path,
               git_revision: "abc123",
               availability_checker: fn _provider, _model, _options ->
                 send(test_pid, :unexpected_availability_call)
               end,
               provider_options: [
                 callback: fn _case, _options -> send(test_pid, :unexpected_generation_call) end,
                 max_output_tokens: 512
               ],
               environment: %{}
             )

    plan = result["plan"]
    assert result["status"] == "dry_run"
    assert plan["condition"] == "control"
    assert plan["baseline_run_id"] == baseline.run_id
    assert plan["samples_per_case"] == 20
    assert plan["planned_samples"] == 20
    assert plan["planned_calls"] == 21
    assert plan["maximum_calls"] == 21
    assert plan["comparison_seed"] == 17
    assert plan["permutations"] == 999
    refute File.exists?(output_path)
    refute_received :unexpected_availability_call
    refute_received :unexpected_generation_call
  end

  test "rejects incompatible generation settings before model access" do
    baseline = fake_baseline(2)
    test_pid = self()

    assert {:error, error} =
             Control.plan(baseline, SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 3,
               seed: 1,
               availability_checker: fn _provider, _model, _options ->
                 send(test_pid, :unexpected_availability_call)
               end,
               provider_options: [max_output_tokens: 1024],
               environment: %{}
             )

    assert error["type"] == "incompatible_provenance"
    assert error["details"]["field"] == "request_config"
    refute_received :unexpected_availability_call
  end

  @tag :tmp_dir
  test "captures, persists, and compares an end-to-end fake control", %{tmp_dir: tmp_dir} do
    {:ok, structured_case} = CaseSet.fetch("rag_structured_extract")
    baseline = fake_baseline(2, structured_case)
    output_path = Path.join(tmp_dir, "control.json")

    provider_callback = fn case_definition, options ->
      assert case_definition.id == structured_case.id
      assert options[:model] == "fake-model"
      {:ok, response(passing_structured_output())}
    end

    assert {:ok, result} =
             Control.run(baseline, SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 3,
               max_retries: 0,
               max_concurrency: 2,
               seed: 71,
               permutations: 19,
               run_id: "control-e2e",
               label: "fake held-out control",
               output_path: output_path,
               git_revision: "abc123",
               clock: fn -> @run_time end,
               availability_checker: fn provider, model, options ->
                 assert provider == SpikeFakeProvider
                 assert model == "fake-model"
                 assert options[:environment] == %{}
                 {:ok, availability()}
               end,
               provider_options: [callback: provider_callback, max_output_tokens: 512],
               environment: %{}
             )

    assert result["status"] == "completed"
    assert result["totals"]["actual_calls"] == 3
    assert result["totals"]["quality_passed_samples"] == 2
    assert result["comparison"]["baseline_run_id"] == baseline.run_id
    assert result["comparison"]["candidate_run_id"] == "control-e2e"
    assert hd(result["comparison"]["by_case"])["outcome"] == "not_calibrated"

    assert {:ok, persisted} = Storage.read(output_path)
    assert persisted.condition == "control"
    assert persisted.run_id == "control-e2e"
    assert persisted.label == "fake held-out control"
    assert Enum.all?(persisted.samples, &(&1["quality"]["passed"] == true))
  end

  defp fake_baseline(sample_count, case_definition \\ nil) do
    {:ok, default_case} = CaseSet.fetch("rag_open_synthesis")
    case_definition = case_definition || default_case

    output =
      if case_definition.id == "rag_structured_extract",
        do: passing_structured_output(),
        else: passing_synthesis_output()

    SpikeFixtures.analyzed_run(%{
      run_id: "fake-baseline",
      case_definition: case_definition,
      outputs: List.duplicate(output, sample_count)
    })
  end

  defp availability do
    %{
      "provider" => "fake",
      "requested_model" => "fake-model",
      "returned_model" => "fake-model",
      "request_id" => "fake-model-check",
      "attempts" => 1
    }
  end

  defp response(output_text) do
    SpikeFixtures.response(%{
      provider: "fake",
      requested_model: "fake-model",
      returned_model: "fake-model",
      output_text: output_text,
      request_id: "response-#{System.unique_integer([:positive, :monotonic])}",
      usage: %{"input_tokens" => 10, "output_tokens" => 5},
      latency_ms: 50,
      captured_at: @captured_at,
      finish_reason: "completed",
      attempts: 1
    })
  end

  defp passing_structured_output do
    Jason.encode!(%{
      "project_name" => "Meridian Lantern",
      "launch_date" => "2042-11-18",
      "city" => "Bellweather Harbor",
      "budget_usd" => 480_000,
      "source_ids" => ["brief-7", "finance-2"]
    })
  end

  defp passing_synthesis_output do
    "The full fleet of 12 electric ferries targets a 19-minute crossing by 2044 " <>
      "[transit-plan]. Phase one funds six ferries [phase-one-budget]. From March " <>
      "through July, service near the islands is limited to 12 knots [habitat-rules]."
  end
end
