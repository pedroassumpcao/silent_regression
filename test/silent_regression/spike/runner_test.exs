defmodule SilentRegression.Spike.RunnerTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Providers.OpenAI
  alias SilentRegression.Spike.Runner
  alias SilentRegression.SpikeFakeProvider
  alias SilentRegression.SpikeFixtures

  test "plans exact initial calls and reserves every possible retry" do
    cases = [case_definition("first", "a"), case_definition("second", "b")]

    assert {:ok, plan} =
             Runner.plan(cases, SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 8,
               max_retries: 1,
               provider_options: [
                 max_output_tokens: 128,
                 callback: fn _case_definition, _options -> :not_called end
               ],
               environment: %{}
             )

    assert plan["provider"] == "fake"
    assert plan["model"] == "fake-model"
    assert plan["case_count"] == 2
    assert plan["samples_per_case"] == 2
    assert plan["planned_samples"] == 4
    assert plan["planned_calls"] == 4
    assert plan["retry_calls_reserved"] == 4
    assert plan["maximum_calls"] == 8
    assert plan["max_calls"] == 8
    assert plan["max_concurrency"] == 3

    assert plan["request_config"] == %{
             "api_endpoint" => "https://fake.invalid/v1/completions",
             "api_version" => "v1",
             "http_method" => "POST",
             "max_output_tokens" => 128,
             "max_retries" => 1,
             "model" => "fake-model"
           }

    assert Enum.map(plan["cases"], & &1["id"]) == ["first", "second"]
  end

  test "dry-run mode validates the plan without invoking the provider" do
    test_pid = self()

    callback = fn _case_definition, _options ->
      send(test_pid, :unexpected_provider_call)
      {:ok, response()}
    end

    assert {:ok, result} =
             Runner.run([case_definition("dry-run", "a")], SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 4,
               max_retries: 1,
               dry_run: true,
               provider_options: [callback: callback],
               environment: %{}
             )

    assert result["status"] == "dry_run"
    assert result["samples"] == []
    assert result["totals"]["planned_calls"] == 2
    assert result["totals"]["maximum_calls"] == 4
    assert result["totals"]["actual_calls"] == 0
    refute_received :unexpected_provider_call
  end

  test "refuses an insufficient max-calls cap before invoking the provider" do
    test_pid = self()

    callback = fn _case_definition, _options ->
      send(test_pid, :unexpected_provider_call)
      {:ok, response()}
    end

    assert {:error, error} =
             Runner.run(
               [case_definition("first", "a"), case_definition("second", "b")],
               SpikeFakeProvider,
               model: "fake-model",
               samples_per_case: 2,
               max_calls: 7,
               max_retries: 1,
               provider_options: [callback: callback],
               environment: %{}
             )

    assert error["type"] == "call_budget_exceeded"

    assert error["details"] == %{
             "planned_calls" => 4,
             "retry_calls_reserved" => 4,
             "maximum_calls" => 8,
             "max_calls" => 7
           }

    refute_received :unexpected_provider_call
  end

  test "keeps stable case order when concurrent calls complete out of order" do
    test_pid = self()

    callback = fn case_definition, _options ->
      send(test_pid, {:provider_started, case_definition.id, self()})

      if case_definition.id == "first" do
        receive do
          :release_first -> :ok
        after
          1_000 -> raise "first fake provider call was not released"
        end
      end

      send(test_pid, {:provider_completed, case_definition.id})
      {:ok, response(%{output_text: "response for #{case_definition.id}"})}
    end

    options =
      runner_options(callback,
        max_calls: 2,
        max_concurrency: 2
      )

    runner_pid =
      start_supervised!(
        {Task,
         fn ->
           result =
             Runner.run(
               [case_definition("first", "a"), case_definition("second", "b")],
               SpikeFakeProvider,
               options
             )

           send(test_pid, {:runner_result, result})
         end}
      )

    monitor_ref = Process.monitor(runner_pid)

    assert_receive {:provider_started, "first", first_provider_pid}
    assert_receive {:provider_started, "second", _second_provider_pid}
    assert_receive {:provider_completed, "second"}
    refute_received {:provider_completed, "first"}

    send(first_provider_pid, :release_first)

    assert_receive {:runner_result, {:ok, result}}
    assert_receive {:DOWN, ^monitor_ref, :process, ^runner_pid, :normal}

    assert Enum.map(result["samples"], & &1["case_id"]) == ["first", "second"]
    assert Enum.map(result["samples"], & &1["sample_index"]) == [0, 0]
  end

  test "preserves partial failures and counts success and error retry attempts" do
    callback = fn case_definition, _options ->
      if case_definition.id == "failing" do
        {:error,
         Provider.error(:rate_limited, "Synthetic rate limit",
           retryable?: true,
           details: %{"attempts" => 2}
         )}
      else
        {:ok, response(%{attempts: 3})}
      end
    end

    assert {:ok, result} =
             Runner.run(
               [case_definition("successful", "a"), case_definition("failing", "b")],
               SpikeFakeProvider,
               runner_options(callback, max_calls: 6, max_retries: 2)
             )

    assert result["status"] == "completed"

    assert [successful, failing] = result["samples"]
    assert successful["status"] == "ok"
    assert successful["attempts"] == 3
    assert failing["status"] == "error"
    assert failing["attempts"] == 2
    assert failing["error"]["type"] == "rate_limited"

    assert result["totals"] == %{
             "planned_samples" => 2,
             "planned_calls" => 2,
             "maximum_calls" => 6,
             "actual_calls" => 5,
             "successful_samples" => 1,
             "failed_samples" => 1
           }
  end

  test "validates known provider environment keys without exposing their values" do
    options = [
      model: "explicit-model",
      max_calls: 1,
      provider_options: [max_output_tokens: 128],
      environment: %{}
    ]

    assert {:error, missing_key_error} =
             Runner.plan([case_definition("known-provider", "a")], OpenAI, options)

    assert missing_key_error["type"] == "configuration_error"
    assert missing_key_error["details"]["env_var"] == "OPENAI_API_KEY"

    assert {:ok, plan} =
             Runner.plan(
               [case_definition("known-provider", "a")],
               OpenAI,
               Keyword.put(options, :environment, %{"OPENAI_API_KEY" => "super-secret"})
             )

    assert plan["credential"] == %{
             "required" => true,
             "env_var" => "OPENAI_API_KEY",
             "present" => true
           }

    refute inspect(plan) =~ "super-secret"
  end

  test "requires an explicit model and max-calls cap" do
    callback = fn _case_definition, _options -> {:ok, response()} end
    case_definition = case_definition("required-options", "a")

    assert {:error, %{"details" => %{"field" => "model"}}} =
             Runner.plan([case_definition], SpikeFakeProvider,
               max_calls: 1,
               provider_options: [callback: callback],
               environment: %{}
             )

    assert {:error, %{"details" => %{"field" => "max_calls"}}} =
             Runner.plan([case_definition], SpikeFakeProvider,
               model: "fake-model",
               provider_options: [callback: callback],
               environment: %{}
             )
  end

  test "refuses an undersized output-token budget for open synthesis" do
    {:ok, open_synthesis} = SilentRegression.Spike.CaseSet.fetch("rag_open_synthesis")
    callback = fn _case_definition, _options -> {:ok, response()} end

    assert {:error, error} =
             Runner.plan([open_synthesis], SpikeFakeProvider,
               model: "fake-model",
               max_calls: 1,
               provider_options: [callback: callback, max_output_tokens: 256],
               environment: %{}
             )

    assert error["type"] == "configuration_error"
    assert error["details"]["field"] == "provider_options.max_output_tokens"
    assert error["details"]["actual"] == 256
    assert error["details"]["minimum"] == 512
    assert error["details"]["case_ids"] == ["rag_open_synthesis"]

    assert {:ok, plan} =
             Runner.plan([open_synthesis], SpikeFakeProvider,
               model: "fake-model",
               max_calls: 1,
               provider_options: [callback: callback, max_output_tokens: 512],
               environment: %{}
             )

    assert plan["request_config"]["max_output_tokens"] == 512
  end

  test "converts an unexpected provider exception into a failed sample" do
    callback = fn _case_definition, _options -> raise "synthetic provider crash" end

    assert {:ok, result} =
             Runner.run(
               [case_definition("provider-crash", "a")],
               SpikeFakeProvider,
               runner_options(callback)
             )

    assert [sample] = result["samples"]
    assert sample["status"] == "error"
    assert sample["attempts"] == 1
    assert sample["error"]["type"] == "provider_exception"
    assert result["totals"]["actual_calls"] == 1
    assert result["totals"]["failed_samples"] == 1
  end

  defp runner_options(callback, overrides \\ []) do
    [
      model: "fake-model",
      samples_per_case: 1,
      max_calls: 1,
      max_retries: 0,
      max_concurrency: 1,
      provider_options: [callback: callback],
      environment: %{}
    ]
    |> Keyword.merge(overrides)
  end

  defp case_definition(id, fingerprint_character) do
    SpikeFixtures.case_definition(%{
      id: id,
      fingerprint: String.duplicate(fingerprint_character, 64)
    })
  end

  defp response(overrides \\ %{}) do
    SpikeFixtures.response(
      Map.merge(
        %{
          provider: "fake",
          requested_model: "fake-model",
          returned_model: "fake-model"
        },
        overrides
      )
    )
  end
end
