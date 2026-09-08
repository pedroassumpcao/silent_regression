defmodule SilentRegression.Spike.BaselineTest do
  use ExUnit.Case, async: false

  alias SilentRegression.Spike.Baseline
  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Storage
  alias SilentRegression.SpikeFakeProvider
  alias SilentRegression.SpikeFixtures

  @captured_at ~U[2026-09-07 12:00:01Z]
  @run_time ~U[2026-09-07 12:00:00Z]

  @tag :tmp_dir
  test "dry run defaults to thirty samples per case and performs no work", %{tmp_dir: tmp_dir} do
    test_pid = self()
    artifact_path = Path.join(tmp_dir, "dry-run.json")

    availability_checker = fn _provider, _model, _options ->
      send(test_pid, :unexpected_availability_call)
      {:ok, availability()}
    end

    provider_callback = fn _case_definition, _options ->
      send(test_pid, :unexpected_generation_call)
      {:ok, response("not used")}
    end

    assert {:ok, result} =
             Baseline.run(CaseSet.all(), SpikeFakeProvider,
               model: "fake-model",
               max_calls: 121,
               dry_run: true,
               output_path: artifact_path,
               run_id: "dry-run",
               git_revision: "abc123",
               availability_checker: availability_checker,
               provider_options: [callback: provider_callback, max_output_tokens: 128],
               environment: %{}
             )

    assert result["status"] == "dry_run"
    assert result["plan"]["samples_per_case"] == 30
    assert result["plan"]["planned_samples"] == 120
    assert result["plan"]["availability_calls"] == 1
    assert result["plan"]["generation_calls"] == 120
    assert result["plan"]["planned_calls"] == 121
    assert result["plan"]["maximum_calls"] == 121
    assert result["totals"]["actual_calls"] == 0
    refute File.exists?(artifact_path)
    refute_received :unexpected_availability_call
    refute_received :unexpected_generation_call
  end

  @tag :tmp_dir
  test "captures, scores, and atomically persists an end-to-end fake baseline", %{
    tmp_dir: tmp_dir
  } do
    access_state = start_supervised!({Agent, fn -> false end})
    artifact_path = Path.join(tmp_dir, "baseline.json")

    availability_checker = fn provider, model, options ->
      assert provider == SpikeFakeProvider
      assert model == "fake-model"
      assert options[:environment] == %{}
      Agent.update(access_state, fn _checked? -> true end)
      {:ok, availability()}
    end

    provider_callback = fn case_definition, options ->
      assert Agent.get(access_state, & &1)
      assert options[:model] == "fake-model"
      assert options[:max_retries] == 0
      {:ok, response(passing_output(case_definition.id))}
    end

    assert {:ok, result} =
             Baseline.run(CaseSet.all(), SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 9,
               max_retries: 0,
               max_concurrency: 2,
               label: "fake pilot baseline",
               run_id: "baseline-e2e",
               output_path: artifact_path,
               git_revision: "abc123",
               clock: fn -> @run_time end,
               availability_checker: availability_checker,
               provider_options: [callback: provider_callback, max_output_tokens: 128],
               environment: %{}
             )

    assert result["status"] == "completed"
    assert result["artifact_path"] == artifact_path
    assert File.exists?(artifact_path)
    assert {:ok, persisted_run} = Storage.read(artifact_path)
    assert persisted_run.run_id == "baseline-e2e"
    assert persisted_run.label == "fake pilot baseline"
    assert persisted_run.condition == "baseline"
    assert persisted_run.provider == "fake"
    assert persisted_run.git_revision == "abc123"
    assert persisted_run.started_at == @run_time
    assert persisted_run.completed_at == @run_time
    assert length(persisted_run.cases) == 4
    assert length(persisted_run.samples) == 8
    assert Enum.map(persisted_run.samples, & &1["sample_index"]) == [0, 1, 0, 1, 0, 1, 0, 1]
    assert Enum.all?(persisted_run.samples, &(&1["deterministic"]["all_passed"] == true))

    assert persisted_run.request_config["model"] == "fake-model"
    assert persisted_run.request_config["max_output_tokens"] == 128
    assert persisted_run.request_config["samples_per_case"] == 2

    assert persisted_run.request_config["api_endpoint"] ==
             "https://fake.invalid/v1/completions"

    assert persisted_run.request_config["api_version"] == "v1"
    assert persisted_run.request_config["http_method"] == "POST"
    assert persisted_run.request_config["model_availability"] == availability()

    assert persisted_run.totals == %{
             "planned_samples" => 8,
             "planned_calls" => 9,
             "maximum_calls" => 9,
             "actual_calls" => 9,
             "availability_calls" => 1,
             "generation_calls" => 8,
             "successful_samples" => 8,
             "failed_samples" => 0,
             "latency_ms" => 400,
             "input_tokens" => 80,
             "output_tokens" => 40,
             "returned_models" => %{"fake-model-snapshot" => 8}
           }

    assert Enum.all?(persisted_run.metrics["by_case"], fn case_metrics ->
             case_metrics["successful_samples"] == 2 and
               case_metrics["failed_samples"] == 0 and
               case_metrics["deterministic"]["sample_pass_rate"] == 1.0 and
               case_metrics["deterministic"]["check_pass_rate"] == 1.0 and
               case_metrics["within_distance"]["status"] == "available" and
               case_metrics["within_distance"]["pair_count"] == 1 and
               case_metrics["within_distance"]["mean"] == 0.0 and
               case_metrics["within_distance"]["sample_standard_deviation"] == nil and
               case_metrics["latency_ms"]["mean"] == 50.0 and
               case_metrics["usage"] == %{"input_tokens" => 20, "output_tokens" => 10}
           end)

    assert File.ls!(tmp_dir) == ["baseline.json"]
  end

  @tag :tmp_dir
  test "persists provider failures and reports insufficient within-run data", %{tmp_dir: tmp_dir} do
    call_count = start_supervised!({Agent, fn -> 0 end})
    [case_definition | _rest] = CaseSet.all()
    artifact_path = Path.join(tmp_dir, "partial.json")

    provider_callback = fn _case_definition, _options ->
      call_number = Agent.get_and_update(call_count, &{&1 + 1, &1 + 1})

      if call_number == 1 do
        {:ok, response(passing_output(case_definition.id))}
      else
        {:error,
         Provider.error(:synthetic_failure, "synthetic failure", details: %{"attempts" => 1})}
      end
    end

    assert {:ok, result} =
             Baseline.run([case_definition], SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 3,
               run_id: "partial-baseline",
               output_path: artifact_path,
               git_revision: nil,
               clock: fn -> @run_time end,
               availability_checker: fn _provider, _model, _options ->
                 {:ok, availability()}
               end,
               provider_options: [callback: provider_callback],
               environment: %{}
             )

    assert result["totals"]["successful_samples"] == 1
    assert result["totals"]["failed_samples"] == 1
    assert result["totals"]["actual_calls"] == 3

    [case_metrics] = result["metrics"]["by_case"]

    assert case_metrics["within_distance"] == %{
             "status" => "insufficient_data",
             "successful_samples" => 1,
             "minimum_successful_samples" => 2,
             "pair_count" => 0
           }

    assert {:ok, persisted_run} = Storage.read(artifact_path)
    assert Enum.map(persisted_run.samples, & &1["status"]) == ["ok", "error"]
  end

  @tag :tmp_dir
  test "stops after a failed model-access check and writes no artifact", %{tmp_dir: tmp_dir} do
    test_pid = self()
    artifact_path = Path.join(tmp_dir, "unavailable.json")

    provider_callback = fn _case_definition, _options ->
      send(test_pid, :unexpected_generation_call)
      {:ok, response("not used")}
    end

    availability_checker = fn _provider, _model, _options ->
      {:error,
       Provider.error(:model_unavailable, "not available",
         details: %{"attempts" => 1, "status" => 404}
       )}
    end

    assert {:error, error} =
             Baseline.run([hd(CaseSet.all())], SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 1,
               max_calls: 2,
               output_path: artifact_path,
               git_revision: nil,
               availability_checker: availability_checker,
               provider_options: [callback: provider_callback],
               environment: %{}
             )

    assert error["type"] == "model_unavailable"
    refute File.exists?(artifact_path)
    refute_received :unexpected_generation_call
  end

  test "rejects an insufficient total cap before checking model access" do
    test_pid = self()

    availability_checker = fn _provider, _model, _options ->
      send(test_pid, :unexpected_availability_call)
      {:ok, availability()}
    end

    assert {:error, error} =
             Baseline.plan([hd(CaseSet.all())], SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 2,
               availability_checker: availability_checker,
               provider_options: [callback: fn _case, _options -> :not_called end],
               environment: %{}
             )

    assert error["type"] == "call_budget_exceeded"
    assert error["details"]["availability_calls"] == 1
    assert error["details"]["generation_calls"] == 2
    assert error["details"]["maximum_calls"] == 3
    assert error["details"]["max_calls"] == 2
    refute_received :unexpected_availability_call
  end

  test "starts Req before a live model availability check" do
    assert :ok = Application.stop(:req)
    on_exit(fn -> Application.ensure_all_started(:req) end)
    refute Process.whereis(Req.Finch)

    availability_checker = fn _provider, _model, _options ->
      assert is_pid(Process.whereis(Req.Finch))

      {:error,
       Provider.error(:expected_test_stop, "stop after startup check",
         details: %{"attempts" => 1}
       )}
    end

    assert {:error, error} =
             Baseline.run([hd(CaseSet.all())], SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 1,
               max_calls: 2,
               git_revision: nil,
               availability_checker: availability_checker,
               provider_options: [callback: fn _case, _options -> :not_called end],
               environment: %{}
             )

    assert error["type"] == "expected_test_stop"
    assert is_pid(Process.whereis(Req.Finch))
  end

  test "reports and redacts the reason when a model availability check raises" do
    availability_checker = fn _provider, _model, _options ->
      raise ArgumentError, "synthetic failure containing super-secret"
    end

    assert {:error, error} =
             Baseline.run([hd(CaseSet.all())], SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 1,
               max_calls: 2,
               git_revision: nil,
               availability_checker: availability_checker,
               provider_options: [
                 api_key: "super-secret",
                 callback: fn _case, _options -> :not_called end
               ],
               environment: %{}
             )

    assert error["type"] == "model_availability_exception"
    assert error["details"]["exception"] == "ArgumentError"
    assert error["details"]["reason"] == "synthetic failure containing [REDACTED]"
    refute inspect(error) =~ "super-secret"
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
      returned_model: "fake-model-snapshot",
      output_text: output_text,
      usage: %{"input_tokens" => 10, "output_tokens" => 5},
      latency_ms: 50,
      captured_at: @captured_at,
      attempts: 1
    })
  end

  defp passing_output("rag_structured_extract") do
    Jason.encode!(%{
      "project_name" => "Meridian Lantern",
      "launch_date" => "2042-11-18",
      "city" => "Bellweather Harbor",
      "budget_usd" => 480_000,
      "source_ids" => ["brief-7", "finance-2"]
    })
  end

  defp passing_output("rag_answer_with_citations") do
    "Tours run Wednesday and Friday at 10:30 a.m. and last 75 minutes [tour-schedule]. " <>
      "Book at least 24 hours ahead [booking-policy]."
  end

  defp passing_output("rag_abstain_when_unsupported") do
    "The context does not specify paid parental leave."
  end

  defp passing_output("rag_open_synthesis") do
    "The full fleet of 12 electric ferries targets a 19-minute crossing by 2044 " <>
      "[transit-plan]. Phase one funds the first six ferries [phase-one-budget]. " <>
      "From March through July, service near the islands is limited to 12 knots " <>
      "[habitat-rules]."
  end
end
