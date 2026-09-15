defmodule SilentRegression.CapturesTest do
  use SilentRegression.DataCase, async: true
  use Oban.Testing, repo: SilentRegression.Repo

  import SilentRegression.ContractAuthoringFixtures
  import SilentRegression.WorkspacesFixtures

  alias SilentRegression.Captures

  alias SilentRegression.Captures.{
    CaptureObservation,
    CaptureRun,
    Prompt,
    ProviderAttempt
  }

  alias SilentRegression.Captures.Workers.ObservationWorker

  setup do
    scope = workspace_scope_fixture()
    fixture = baseline_ready_monitor_fixture(scope)

    %{fixture: fixture, scope: scope}
  end

  describe "plan_run/3" do
    test "freezes exact approved inputs and is idempotent by workspace identity", %{
      fixture: fixture,
      scope: scope
    } do
      attrs = plan_attrs(%{kind: :baseline})

      assert {:ok, run} = Captures.plan_run(scope, fixture.monitor.id, attrs)
      assert run.status == :planned
      assert run.kind == :baseline
      assert run.monitor_version_id == fixture.version.id
      assert run.contract_version_id == fixture.contract.id
      assert run.provider_credential_id == fixture.credential.id
      assert run.monitor_fingerprint == fixture.version.fingerprint
      assert run.case_set_fingerprint == fixture.version.case_set_fingerprint
      assert run.contract_fingerprint == fixture.contract.fingerprint
      assert run.planned_call_count == 1
      assert run.maximum_call_count == 2

      assert [observation] = run.observations
      assert observation.case_version_id == hd(fixture.version.cases).id
      assert observation.status == :planned
      assert observation.sample_index == 0
      assert [] = all_enqueued(worker: ObservationWorker)

      assert {:ok, duplicate} = Captures.plan_run(scope, fixture.monitor.id, attrs)
      assert duplicate.id == run.id

      assert {:error, :identity_conflict} =
               Captures.plan_run(scope, fixture.monitor.id, %{attrs | kind: :scheduled})
    end

    test "does not expose runs across workspace scopes", %{fixture: fixture, scope: scope} do
      assert {:ok, run} = Captures.plan_run(scope, fixture.monitor.id, plan_attrs())
      other_scope = workspace_scope_fixture()

      assert {:error, :not_found} = Captures.get_run(other_scope, run.id)
      assert {:error, :not_found} = Captures.cancel_run(other_scope, run.id)
    end

    test "manual and scheduled kinds share the same execution path", %{
      fixture: fixture,
      scope: scope
    } do
      for kind <- [:manual, :scheduled] do
        assert {:ok, run} = planned_and_enqueued(scope, fixture, %{kind: kind})
        assert run.kind == kind
        assert :ok = perform_job(ObservationWorker, worker_args(run))
        assert {:ok, %{status: :succeeded, kind: ^kind}} = Captures.get_run(scope, run.id)
      end
    end
  end

  describe "enqueue_run/2" do
    test "refuses baseline execution without a durable authorization", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, run} =
               Captures.plan_run(scope, fixture.monitor.id, plan_attrs(%{kind: :baseline}))

      assert {:error, :authorization_required} = Captures.enqueue_run(scope, run.id)
      assert [] = all_enqueued(worker: ObservationWorker)
    end

    test "enqueues only durable identifiers, never prompt or credential material", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, run} = Captures.plan_run(scope, fixture.monitor.id, plan_attrs())
      assert {:ok, queued} = Captures.enqueue_run(scope, run.id)
      assert queued.status == :queued

      assert [%Oban.Job{args: args}] = all_enqueued(worker: ObservationWorker)

      assert args == %{
               "capture_run_id" => run.id,
               "observation_id" => hd(run.observations).id
             }

      refute Map.has_key?(args, "secret")
      refute Map.has_key?(args, "prompt")
      refute Map.has_key?(args, "context")

      assert {:ok, %{id: duplicate_id}} = Captures.enqueue_run(scope, run.id)
      assert duplicate_id == run.id
      assert length(all_enqueued(worker: ObservationWorker)) == 1
    end
  end

  describe "observation execution" do
    test "persists one provider attempt and local evaluation exactly once", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, run} = planned_and_enqueued(scope, fixture)
      args = worker_args(run)

      assert :ok = perform_job(ObservationWorker, args)
      assert {:ok, completed} = Captures.get_run(scope, run.id)
      assert completed.status == :succeeded
      assert completed.started_at
      assert completed.completed_at

      assert [observation] = completed.observations
      assert observation.status == :succeeded
      assert observation.output_text == "approved"
      assert observation.completion_state == :complete
      assert observation.requested_model == fixture.version.requested_model
      assert observation.returned_model == fixture.version.requested_model
      assert observation.input_tokens == 10
      assert observation.output_tokens == 1

      assert [attempt] = observation.provider_attempts
      assert attempt.status == :succeeded
      assert attempt.attempt_number == 1
      assert attempt.client_request_id
      assert attempt.provider_request_id

      assert [evaluation] = observation.evaluations
      assert evaluation.status == :pass
      assert length(evaluation.rule_results) == 3
      assert Enum.all?(evaluation.rule_results, &(&1.status == :pass))

      assert :ok = perform_job(ObservationWorker, args)
      assert {:ok, repeated} = Captures.get_run(scope, run.id)
      assert length(hd(repeated.observations).provider_attempts) == 1
      assert length(hd(repeated.observations).evaluations) == 1
    end

    test "retries a known retryable failure within the persisted call budget", %{scope: scope} do
      fixture = baseline_ready_monitor_fixture(scope, %{cases: [retry_case()]})

      assert {:ok, run} = planned_and_enqueued(scope, fixture)
      args = worker_args(run)

      assert {:snooze, 1} = perform_job(ObservationWorker, args)
      assert {:ok, retrying} = Captures.get_run(scope, run.id)
      assert retrying.status == :running
      assert [retrying_observation] = retrying.observations
      assert retrying_observation.status == :retrying
      assert [failed_attempt] = retrying_observation.provider_attempts
      assert failed_attempt.status == :failed
      assert failed_attempt.retryable
      assert failed_attempt.failure_category == :rate_limited

      assert :ok = perform_job(ObservationWorker, args)
      assert {:ok, completed} = Captures.get_run(scope, run.id)
      assert completed.status == :succeeded
      assert [observation] = completed.observations
      assert observation.status == :succeeded
      assert Enum.map(observation.provider_attempts, & &1.status) == [:failed, :succeeded]
    end

    test "enforces the hard run call cap before scheduling another paid attempt", %{scope: scope} do
      fixture = baseline_ready_monitor_fixture(scope, %{cases: [retry_case()]})

      assert {:ok, run} =
               planned_and_enqueued(scope, fixture, %{maximum_call_count: 1})

      assert :ok = perform_job(ObservationWorker, worker_args(run))
      assert {:ok, completed} = Captures.get_run(scope, run.id)
      assert completed.status == :failed
      assert [observation] = completed.observations
      assert observation.status == :failed
      assert observation.failure_category == :rate_limited
      assert length(observation.provider_attempts) == 1
    end

    test "marks an abandoned reservation unknown without replaying it", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, run} = planned_and_enqueued(scope, fixture)
      [observation] = run.observations
      now = DateTime.utc_now()

      run =
        run
        |> CaptureRun.lifecycle_changeset(%{
          status: :running,
          started_at: DateTime.add(now, -1_100, :second)
        })
        |> Repo.update!()

      observation =
        observation
        |> CaptureObservation.lifecycle_changeset(%{status: :running})
        |> Repo.update!()

      _attempt =
        %ProviderAttempt{}
        |> ProviderAttempt.create_changeset(run, observation, %{
          attempt_number: 1,
          client_request_id: Ecto.UUID.generate(),
          started_at: DateTime.add(now, -1_000, :second),
          lease_expires_at: DateTime.add(now, -1, :second)
        })
        |> Repo.insert!()

      assert :ok = perform_job(ObservationWorker, worker_args(run))
      assert {:ok, reviewed} = Captures.get_run(scope, run.id)
      assert reviewed.status == :needs_review
      assert [unknown] = reviewed.observations
      assert unknown.status == :unknown
      assert unknown.failure_category == :unknown_outcome
      assert [attempt] = unknown.provider_attempts
      assert attempt.status == :unknown
      assert attempt.failure_category == :unknown_outcome
    end

    test "snoozes a duplicate worker while an attempt lease is active", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, run} = planned_and_enqueued(scope, fixture)
      [observation] = run.observations
      now = DateTime.utc_now()

      run =
        run
        |> CaptureRun.lifecycle_changeset(%{status: :running, started_at: now})
        |> Repo.update!()

      observation =
        observation
        |> CaptureObservation.lifecycle_changeset(%{status: :running})
        |> Repo.update!()

      _attempt =
        %ProviderAttempt{}
        |> ProviderAttempt.create_changeset(run, observation, %{
          attempt_number: 1,
          client_request_id: Ecto.UUID.generate(),
          started_at: now,
          lease_expires_at: DateTime.add(now, 60, :second)
        })
        |> Repo.insert!()

      assert {:snooze, seconds} = perform_job(ObservationWorker, worker_args(run))
      assert seconds in 59..60
      assert Repo.aggregate(ProviderAttempt, :count) == 1
    end

    test "cancellation stops pending work without manufacturing provider attempts", %{
      fixture: fixture,
      scope: scope
    } do
      assert {:ok, run} = planned_and_enqueued(scope, fixture)
      assert {:ok, cancelled} = Captures.cancel_run(scope, run.id)
      assert cancelled.status == :cancelled
      assert cancelled.cancellation_requested_at
      assert cancelled.completed_at
      assert [observation] = cancelled.observations
      assert observation.status == :cancelled

      assert :ok = perform_job(ObservationWorker, worker_args(run))
      assert Repo.aggregate(ProviderAttempt, :count) == 0
    end

    test "finalizes mixed outcomes as partial failure and preserves successful evidence", %{
      scope: scope
    } do
      fixture =
        baseline_ready_monitor_fixture(scope, %{
          cases: [successful_case(), provider_failure_case()]
        })

      assert {:ok, run} =
               planned_and_enqueued(scope, fixture, %{
                 retry_limit: 0,
                 maximum_call_count: 2
               })

      Enum.each(run.observations, fn observation ->
        assert :ok =
                 perform_job(ObservationWorker, %{
                   capture_run_id: run.id,
                   observation_id: observation.id
                 })
      end)

      assert {:ok, completed} = Captures.get_run(scope, run.id)
      assert completed.status == :partial_failed

      observations = Map.new(completed.observations, &{&1.status, &1})
      assert %{succeeded: succeeded, failed: failed} = observations
      assert length(succeeded.evaluations) == 1
      assert length(succeeded.provider_attempts) == 1
      assert failed.failure_category == :provider_unavailable
      assert failed.evaluations == []
      assert length(failed.provider_attempts) == 1
    end
  end

  describe "Prompt.render/2" do
    test "renders bounded string and JSON values without inventing missing variables" do
      assert {:ok, ~s(Question: hello; metadata: {"count":2})} =
               Prompt.render("Question: {{question}}; metadata: {{metadata}}", %{
                 "question" => "hello",
                 "metadata" => %{"count" => 2}
               })

      assert {:error, {:missing_prompt_variable, "missing"}} =
               Prompt.render("{{missing}}", %{})
    end
  end

  defp planned_and_enqueued(scope, fixture, overrides \\ %{}) do
    attrs = Map.merge(plan_attrs(), overrides)

    with {:ok, run} <- Captures.plan_run(scope, fixture.monitor.id, attrs),
         {:ok, _queued} <- Captures.enqueue_run(scope, run.id) do
      {:ok, run}
    end
  end

  defp plan_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        identity_key: "capture-#{System.unique_integer([:positive])}",
        kind: :manual,
        samples_per_case: 1,
        retry_limit: 1,
        maximum_call_count: 2
      },
      overrides
    )
  end

  defp worker_args(run) do
    %{
      capture_run_id: run.id,
      observation_id: hd(run.observations).id
    }
  end

  defp successful_case do
    %{
      case_key: "successful-answer",
      name: "Successful answer",
      input_variables_json: ~s({"question":"Which plan includes SSO?"}),
      frozen_context: "The Enterprise plan includes SSO.",
      status: "active"
    }
  end

  defp retry_case do
    %{
      case_key: "retry-answer",
      name: "Retry answer",
      input_variables_json: ~s({"question":"Which plan includes SSO?"}),
      frozen_context: "[fake:retry-once] The Enterprise plan includes SSO.",
      status: "active"
    }
  end

  defp provider_failure_case do
    %{
      case_key: "failed-answer",
      name: "Failed answer",
      input_variables_json: ~s({"question":"Which plan includes SSO?"}),
      frozen_context: "[fake:provider-failure] The provider is unavailable.",
      status: "active"
    }
  end
end
