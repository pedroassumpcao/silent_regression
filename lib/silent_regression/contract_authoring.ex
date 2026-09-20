defmodule SilentRegression.ContractAuthoring do
  @moduledoc """
  Workspace-scoped deterministic contract authoring, fixture validation, and approval.

  Owners and members may author drafts and validate fixtures. Only owners may
  approve an exact contract-plus-fixture snapshot.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias SilentRegression.Accounts.{Scope, User}
  alias SilentRegression.Audit

  alias SilentRegression.ContractAuthoring.{
    ContractFixture,
    ContractVersion,
    Coverage,
    CoverageWaiver,
    DraftInput,
    Fingerprints,
    FixtureJudgment,
    Rescorer,
    RescoreSummary,
    Templates
  }

  alias SilentRegression.Contracts
  alias SilentRegression.Contracts.{Evaluation, RuleResult}
  alias SilentRegression.MonitorSetups.Setup
  alias SilentRegression.Monitors.{Monitor, MonitorVersion}
  alias SilentRegression.Repo
  alias SilentRegression.Workspaces.{Membership, Workspace}

  @max_fixtures 20

  def templates, do: Templates.all()
  def max_fixtures, do: @max_fixtures

  def get_state(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         {:ok, monitor} <- fetch_monitor(workspace_id, monitor_id),
         {:ok, monitor_version} <- fetch_current_monitor_version(monitor) do
      draft = load_contract(monitor.id, :draft)
      approved = load_contract(monitor.id, :approved)
      current = draft || approved
      fixtures = if current, do: load_fixtures(current.id), else: []
      fixture_results = evaluate_fixtures(current, fixtures)
      waivers = if current, do: load_coverage_waivers(current.id), else: []
      coverage = coverage(current, fixture_results, waivers)

      {:ok,
       %{
         monitor: monitor,
         monitor_version: monitor_version,
         contract_version: current,
         draft_contract_version: draft,
         approved_contract_version: approved,
         rescore_summary: rescore_summary(current),
         fixtures: fixtures,
         fixture_results: fixture_results,
         coverage: coverage,
         coverage_waivers: waivers,
         readiness: approval_readiness(current, fixtures, fixture_results, coverage)
       }}
    else
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_state(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def get_approved_contract(
        %Scope{workspace: %Workspace{id: workspace_id}, membership: %Membership{}},
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id),
         %Monitor{} <- load_monitor(workspace_id, monitor_id),
         %ContractVersion{} = contract_version <- load_contract(monitor_id, :approved) do
      {:ok, Repo.preload(contract_version, :fixtures)}
    else
      _reason -> {:error, :not_found}
    end
  end

  def get_approved_contract(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def save_draft(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with {:ok, monitor} <- fetch_locked_monitor(workspace_id, monitor_id),
             {:ok, monitor_version} <- fetch_current_monitor_version(monitor),
             existing <- load_contract(monitor.id, :draft),
             :ok <- ensure_editable_draft(existing, monitor),
             identity <- draft_identity(existing, monitor),
             {:ok, normalized} <- DraftInput.normalize(attrs, identity),
             normalized <- Map.put(normalized, :contract_id, identity.contract_id),
             {:ok, contract_version} <-
               persist_draft(existing, monitor, monitor_version, user, normalized),
             {:ok, contract_version} <-
               maybe_invalidate_fixture_judgments(existing, contract_version, normalized.root),
             {:ok, contract_version} <- refresh_fingerprints(contract_version) do
          record_contract_event!(
            contract_version,
            user,
            if(existing, do: "contract_version.updated", else: "contract_version.created")
          )

          Repo.preload(contract_version, :fixtures, force: true)
        else
          {:error, field, message} -> Repo.rollback(error_changeset(nil, field, message))
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def save_draft(%Scope{}, _monitor_id, _attrs), do: {:error, :workspace_required}

  def add_fixture(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        attrs
      )
      when is_map(attrs) do
    mutate_fixture(workspace_id, monitor_id, fn contract_version ->
      fixtures = load_fixtures(contract_version.id, lock: true)

      if length(fixtures) >= @max_fixtures do
        {:error, error_changeset(nil, :fixtures, "cannot exceed #{@max_fixtures}")}
      else
        position = next_fixture_position(fixtures)

        with {:ok, fixture_attrs} <- normalize_fixture(contract_version, attrs, position),
             {:ok, fixture} <-
               %ContractFixture{}
               |> ContractFixture.create_changeset(contract_version, user, fixture_attrs)
               |> Repo.insert(),
             {:ok, _contract_version} <- refresh_fingerprints(contract_version) do
          record_fixture_event!(contract_version, fixture, user, "contract_fixture.created")
          {:ok, fixture}
        end
      end
    end)
  end

  def add_fixture(%Scope{}, _monitor_id, _attrs), do: {:error, :workspace_required}

  def update_fixture(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        fixture_id,
        attrs
      )
      when is_map(attrs) do
    mutate_fixture(workspace_id, monitor_id, fn contract_version ->
      with {:ok, fixture_id} <- Ecto.UUID.cast(fixture_id),
           %ContractFixture{} = fixture <-
             load_fixture(contract_version.id, fixture_id, lock: true),
           {:ok, fixture_attrs} <-
             normalize_fixture(contract_version, attrs, fixture.position),
           {:ok, fixture} <-
             fixture |> ContractFixture.update_changeset(fixture_attrs) |> Repo.update(),
           {:ok, _contract_version} <- refresh_fingerprints(contract_version) do
        record_fixture_event!(contract_version, fixture, user, "contract_fixture.updated")
        {:ok, fixture}
      else
        :error -> {:error, :not_found}
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def update_fixture(%Scope{}, _monitor_id, _fixture_id, _attrs),
    do: {:error, :workspace_required}

  def delete_fixture(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id,
        fixture_id
      ) do
    mutate_fixture(workspace_id, monitor_id, fn contract_version ->
      with {:ok, fixture_id} <- Ecto.UUID.cast(fixture_id),
           %ContractFixture{} = fixture <-
             load_fixture(contract_version.id, fixture_id, lock: true),
           {:ok, fixture} <- Repo.delete(fixture),
           :ok <- compact_fixture_positions(contract_version.id),
           {:ok, _contract_version} <- refresh_fingerprints(contract_version) do
        record_fixture_event!(contract_version, fixture, user, "contract_fixture.deleted")
        {:ok, fixture}
      else
        :error -> {:error, :not_found}
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def delete_fixture(%Scope{}, _monitor_id, _fixture_id), do: {:error, :workspace_required}

  def put_coverage_waiver(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        monitor_id,
        rule_id,
        attrs
      )
      when is_binary(rule_id) and is_map(attrs) do
    mutate_waiver(workspace_id, monitor_id, fn contract_version ->
      with %{} = rule <- find_rule(contract_version.root, rule_id),
           fixtures <- load_fixtures(contract_version.id),
           results <- evaluate_fixtures(contract_version, fixtures),
           waivers <- load_coverage_waivers(contract_version.id),
           rule_coverage <-
             contract_version.root
             |> Coverage.analyze(results, waivers)
             |> Map.fetch!(:rules)
             |> Enum.find(&(&1.rule_id == rule_id)),
           :ok <- ensure_waivable(rule_coverage),
           waiver <-
             Repo.get_by(CoverageWaiver,
               contract_version_id: contract_version.id,
               rule_id: rule_id
             ) || %CoverageWaiver{},
           waiver_attrs <- %{
             rule_id: rule_id,
             rule_fingerprint: Coverage.rule_fingerprint(rule),
             rationale: value(attrs, :rationale)
           },
           {:ok, waiver} <-
             waiver
             |> CoverageWaiver.changeset(contract_version, user, waiver_attrs)
             |> Repo.insert_or_update() do
        record_coverage_waiver_event!(contract_version, waiver, user, "created_or_updated")
        {:ok, waiver}
      else
        nil -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def put_coverage_waiver(%Scope{}, _monitor_id, _rule_id, _attrs),
    do: {:error, :owner_required}

  def delete_coverage_waiver(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        monitor_id,
        rule_id
      )
      when is_binary(rule_id) do
    mutate_waiver(workspace_id, monitor_id, fn contract_version ->
      case Repo.get_by(CoverageWaiver,
             contract_version_id: contract_version.id,
             rule_id: rule_id
           ) do
        nil ->
          {:error, :not_found}

        waiver ->
          with {:ok, waiver} <- Repo.delete(waiver) do
            record_coverage_waiver_event!(contract_version, waiver, user, "removed")
            {:ok, waiver}
          end
      end
    end)
  end

  def delete_coverage_waiver(%Scope{}, _monitor_id, _rule_id),
    do: {:error, :owner_required}

  def approve(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{role: :owner},
          user: %User{} = user
        },
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with %Monitor{} <- locked_monitor(workspace_id, monitor_id),
             %ContractVersion{} = draft <- load_contract(monitor_id, :draft, lock: true),
             fixtures <- load_fixtures(draft.id, lock: true),
             waivers <- load_coverage_waivers(draft.id, lock: true),
             results <- evaluate_fixtures(draft, fixtures),
             coverage <- Coverage.analyze(draft.root, results, waivers),
             %{ready?: true} <- approval_readiness(draft, fixtures, results, coverage),
             {:ok, draft} <- refresh_fingerprints(draft),
             previous <- load_contract(monitor_id, :approved, lock: true),
             {:ok, rescore_summary} <- Rescorer.rescore(draft, previous),
             :ok <- retire_current_approved(previous),
             {:ok, approved} <-
               draft
               |> ContractVersion.approve_changeset(
                 user,
                 DateTime.utc_now(:second),
                 draft
                 |> fingerprint_attributes(load_fixtures(draft.id))
                 |> Map.merge(%{
                   proof_schema_version: coverage.schema_version,
                   proof_fingerprint: coverage.fingerprint
                 })
               )
               |> Repo.update() do
          record_contract_event!(approved, user, "contract_version.approved", %{
            "fixture_count" => length(fixtures),
            "rescore_observation_count" => rescore_summary.observation_count,
            "rescore_pass_count" => rescore_summary.pass_count,
            "rescore_fail_count" => rescore_summary.fail_count,
            "interpretation_changed" => rescore_summary.interpretation_changed,
            "proof_schema_version" => coverage.schema_version,
            "proof_fingerprint" => coverage.fingerprint,
            "coverage_waiver_count" => Enum.count(coverage.rules, & &1.waiver)
          })

          Repo.preload(approved, [:fixtures, :rescore_summary], force: true)
        else
          nil ->
            Repo.rollback(:not_found)

          %{ready?: false, blockers: blockers} ->
            Repo.rollback({:approval_blocked, blockers})

          {:error, {:rescore_failed, observation_id, _reason}} ->
            Repo.rollback(
              {:approval_blocked,
               [
                 blocker(
                   "historical_rescore_failed",
                   "Stored observation #{observation_id} could not be safely rescored."
                 )
               ]}
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def approve(%Scope{}, _monitor_id), do: {:error, :owner_required}

  def create_revision(
        %Scope{
          workspace: %Workspace{id: workspace_id},
          membership: %Membership{},
          user: %User{} = user
        },
        monitor_id
      ) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with %Monitor{} = monitor <- locked_monitor(workspace_id, monitor_id),
             nil <- load_contract(monitor_id, :draft),
             %ContractVersion{} = approved <- load_contract(monitor_id, :approved, lock: true),
             {:ok, revision} <- insert_revision(approved, monitor, user) do
          record_contract_event!(revision, user, "contract_version.revision_created", %{
            "predecessor_id" => approved.id
          })

          Repo.preload(revision, :fixtures, force: true)
        else
          %ContractVersion{} = draft -> draft
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  def create_revision(%Scope{}, _monitor_id), do: {:error, :workspace_required}

  def approval_readiness(nil, _fixtures) do
    %{
      ready?: false,
      blockers: [blocker("contract_missing", "Save a valid contract draft first.")]
    }
  end

  def approval_readiness(%ContractVersion{} = contract_version, fixtures) do
    results = evaluate_fixtures(contract_version, fixtures)
    waivers = load_coverage_waivers(contract_version.id)
    coverage = Coverage.analyze(contract_version.root, results, waivers)

    approval_readiness(contract_version, fixtures, results, coverage)
  end

  defp approval_readiness(nil, _fixtures, _results, _coverage),
    do: approval_readiness(nil, [])

  defp approval_readiness(%ContractVersion{}, fixtures, results, coverage) do
    blockers =
      []
      |> require_fixture_type(fixtures, :pass)
      |> require_fixture_type(fixtures, :fail)
      |> add_fixture_blockers(results)
      |> Kernel.++(coverage.blockers)

    %{ready?: blockers == [], blockers: blockers}
  end

  defp persist_draft(nil, monitor, monitor_version, user, normalized) do
    fixture_set_fingerprint = Fingerprints.fixture_set([])

    attrs =
      normalized
      |> Map.merge(%{
        version: next_contract_version(monitor.id),
        schema_version: 1,
        evaluator_engine_version: Contracts.evaluator_engine_version(),
        fixture_set_fingerprint: fixture_set_fingerprint
      })
      |> then(&Map.put(&1, :fingerprint, Fingerprints.version(&1)))

    associations = %{
      workspace: %{id: monitor.workspace_id},
      monitor: monitor,
      monitor_version: monitor_version,
      predecessor_id: version_id(load_contract(monitor.id, :approved)),
      user: user
    }

    %ContractVersion{id: normalized.contract_id}
    |> ContractVersion.create_changeset(associations, attrs)
    |> Repo.insert()
  end

  defp persist_draft(%ContractVersion{} = existing, _monitor, _monitor_version, _user, normalized) do
    attrs =
      normalized
      |> Map.merge(%{
        version: existing.version,
        schema_version: existing.schema_version,
        evaluator_engine_version: existing.evaluator_engine_version,
        fixture_set_fingerprint: existing.fixture_set_fingerprint
      })
      |> then(&Map.put(&1, :fingerprint, Fingerprints.version(&1)))

    existing |> ContractVersion.update_draft_changeset(attrs) |> Repo.update()
  end

  defp maybe_invalidate_fixture_judgments(nil, contract_version, _new_root),
    do: {:ok, contract_version}

  defp maybe_invalidate_fixture_judgments(existing, contract_version, new_root) do
    if existing.root == new_root do
      {:ok, contract_version}
    else
      {_count, nil} =
        CoverageWaiver
        |> where([waiver], waiver.contract_version_id == ^contract_version.id)
        |> Repo.delete_all()

      contract_version.id
      |> load_fixtures(lock: true)
      |> Enum.reduce_while({:ok, contract_version}, fn fixture, {:ok, contract_version} ->
        pending = %{fixture | expected_rule_statuses: %{}}
        fingerprint = Fingerprints.fixture(pending)

        case fixture
             |> ContractFixture.pending_judgment_changeset(fingerprint)
             |> Repo.update() do
          {:ok, _fixture} -> {:cont, {:ok, contract_version}}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end)
    end
  end

  defp coverage(nil, _fixture_results, _waivers), do: nil

  defp coverage(contract_version, fixture_results, waivers) do
    Coverage.analyze(contract_version.root, fixture_results, waivers)
  end

  defp normalize_fixture(contract_version, attrs, position) do
    name = value(attrs, :name)
    output_text = value(attrs, :output_text)
    expected_status = value(attrs, :expected_status)
    failed_ids = value(attrs, :expected_failed_rule_ids, [])

    with true <- is_binary(name) and String.valid?(name),
         true <- is_binary(output_text) and String.valid?(output_text),
         {:ok, expected_status, expected_rule_statuses} <-
           FixtureJudgment.expected_statuses(
             contract_version.root,
             expected_status,
             failed_ids
           ) do
      attributes = %{
        name: String.trim(name),
        position: position,
        output_text: output_text,
        expected_status: expected_status,
        expected_rule_statuses: expected_rule_statuses
      }

      {:ok, Map.put(attributes, :fingerprint, Fingerprints.fixture(attributes))}
    else
      false -> {:error, error_changeset(nil, :output_text, "must be valid UTF-8 text")}
      {:error, field, message} -> {:error, error_changeset(nil, field, message)}
    end
  end

  defp mutate_fixture(workspace_id, monitor_id, callback) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with %Monitor{} <- locked_monitor(workspace_id, monitor_id),
             %ContractVersion{} = contract_version <-
               load_contract(monitor_id, :draft, lock: true),
             {:ok, result} <- callback.(contract_version) do
          result
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  defp mutate_waiver(workspace_id, monitor_id, callback) do
    with {:ok, monitor_id} <- Ecto.UUID.cast(monitor_id) do
      Repo.transaction(fn ->
        with %Monitor{} <- locked_monitor(workspace_id, monitor_id),
             %ContractVersion{} = contract_version <-
               load_contract(monitor_id, :draft, lock: true),
             {:ok, result} <- callback.(contract_version) do
          result
        else
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      :error -> {:error, :not_found}
    end
  end

  defp ensure_waivable(%{severity: :warning}) do
    {:error, error_changeset(nil, :coverage_waiver, "is unnecessary for a warning rule")}
  end

  defp ensure_waivable(%{missing_branches: []}) do
    {:error, error_changeset(nil, :coverage_waiver, "is unnecessary for a fully proven rule")}
  end

  defp ensure_waivable(%{severity: :critical}), do: :ok

  defp find_rule(%{"type" => "all", "rules" => rules}, rule_id) do
    Enum.find(rules, &(&1["id"] == rule_id))
  end

  defp evaluate_fixtures(nil, _fixtures), do: []

  defp evaluate_fixtures(%ContractVersion{} = contract_version, fixtures) do
    case engine_contract(contract_version) do
      {:ok, contract} ->
        Enum.map(fixtures, &evaluate_fixture(contract, contract_version.root, &1))

      {:error, _error} ->
        []
    end
  end

  defp evaluate_fixture(contract, root, fixture) do
    {:ok, observation} =
      Contracts.new_observation(%{
        "id" => "fixture-#{fixture.id}",
        "output_text" => fixture.output_text
      })

    {:ok, evaluation} =
      Contracts.evaluate(contract, observation, evaluation_id: "fixture-evaluation-#{fixture.id}")

    actual_rule_statuses =
      Map.new(evaluation.rule_results, &{&1.rule_id, Atom.to_string(&1.status)})

    complete? = FixtureJudgment.complete?(root, fixture.expected_rule_statuses)

    %{
      fixture: fixture,
      evaluation: evaluation,
      actual_rule_statuses: actual_rule_statuses,
      judgment_complete?: complete?,
      matches?:
        complete? and Atom.to_string(evaluation.status) == Atom.to_string(fixture.expected_status) and
          actual_rule_statuses == fixture.expected_rule_statuses
    }
  end

  defp engine_contract(contract_version) do
    Contracts.parse_contract(%{
      "schema_version" => contract_version.schema_version,
      "contract_id" => contract_version.id,
      "contract_version" => contract_version.version,
      "monitor_id" => contract_version.monitor_id,
      "root" => contract_version.root
    })
  end

  defp require_fixture_type(blockers, fixtures, expected_status) do
    if Enum.any?(fixtures, &(&1.expected_status == expected_status)) do
      blockers
    else
      label = if expected_status == :pass, do: "known-valid", else: "known-invalid"

      blockers ++
        [blocker("#{expected_status}_fixture_required", "Add at least one #{label} fixture.")]
    end
  end

  defp add_fixture_blockers(blockers, results) do
    Enum.reduce(results, blockers, fn result, blockers ->
      cond do
        result.evaluation.status == :evaluator_error ->
          blockers ++
            [
              blocker(
                "fixture_evaluator_error",
                "#{result.fixture.name} could not be evaluated safely.",
                result.fixture.id
              )
            ]

        not result.judgment_complete? ->
          blockers ++
            [
              blocker(
                "fixture_judgment_required",
                "#{result.fixture.name} needs fresh per-rule judgments.",
                result.fixture.id
              )
            ]

        not result.matches? ->
          blockers ++
            [
              blocker(
                "fixture_mismatch",
                "#{result.fixture.name} does not match its expected rule outcomes.",
                result.fixture.id
              )
            ]

        true ->
          blockers
      end
    end)
  end

  defp blocker(code, message, fixture_id \\ nil) do
    %{code: code, message: message, fixture_id: fixture_id}
  end

  defp refresh_fingerprints(contract_version) do
    fixtures = load_fixtures(contract_version.id)
    attrs = fingerprint_attributes(contract_version, fixtures)
    contract_version |> ContractVersion.update_draft_changeset(attrs) |> Repo.update()
  end

  defp fingerprint_attributes(contract_version, fixtures) do
    fixture_set_fingerprint = Fingerprints.fixture_set(fixtures)

    attributes = %{
      schema_version: contract_version.schema_version,
      evaluator_engine_version: contract_version.evaluator_engine_version,
      template_key: contract_version.template_key,
      template_usage: contract_version.template_usage,
      assistance_mode: contract_version.assistance_mode,
      contract_fingerprint: contract_version.contract_fingerprint,
      fixture_set_fingerprint: fixture_set_fingerprint
    }

    Map.put(attributes, :fingerprint, Fingerprints.version(attributes))
  end

  defp retire_current_approved(nil), do: :ok

  defp retire_current_approved(approved) do
    case approved
         |> ContractVersion.retire_changeset(DateTime.utc_now(:second))
         |> Repo.update() do
      {:ok, _retired} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp rescore_summary(nil), do: nil

  defp rescore_summary(contract_version) do
    Repo.get_by(RescoreSummary, contract_version_id: contract_version.id)
  end

  defp insert_revision(approved, monitor, user) do
    fixtures = load_fixtures(approved.id, lock: true)
    fixture_set_fingerprint = Fingerprints.fixture_set([])

    attrs = %{
      version: next_contract_version(monitor.id),
      schema_version: approved.schema_version,
      evaluator_engine_version: approved.evaluator_engine_version,
      template_key: approved.template_key,
      template_usage: approved.template_usage,
      assistance_mode: approved.assistance_mode,
      root: approved.root,
      contract_fingerprint: approved.contract_fingerprint,
      fixture_set_fingerprint: fixture_set_fingerprint
    }

    attrs = Map.put(attrs, :fingerprint, Fingerprints.version(attrs))

    associations = %{
      workspace: %{id: approved.workspace_id},
      monitor: monitor,
      monitor_version: %{id: approved.monitor_version_id},
      predecessor_id: approved.id,
      user: user
    }

    with {:ok, revision} <-
           %ContractVersion{id: Ecto.UUID.generate()}
           |> ContractVersion.create_changeset(associations, attrs)
           |> Repo.insert(),
         :ok <- copy_fixtures(fixtures, revision, user),
         {:ok, revision} <- refresh_fingerprints(revision) do
      {:ok, revision}
    end
  end

  defp copy_fixtures(fixtures, revision, user) do
    Enum.reduce_while(fixtures, :ok, fn fixture, :ok ->
      attrs =
        Map.take(fixture, [
          :name,
          :position,
          :output_text,
          :expected_status,
          :expected_rule_statuses,
          :fingerprint
        ])

      case %ContractFixture{}
           |> ContractFixture.create_changeset(revision, user, attrs)
           |> Repo.insert() do
        {:ok, _copy} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp compact_fixture_positions(contract_version_id) do
    contract_version_id
    |> load_fixtures(lock: true)
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {fixture, position}, :ok ->
      if fixture.position == position do
        {:cont, :ok}
      else
        attributes = %{fixture | position: position}
        fingerprint = Fingerprints.fixture(attributes)

        case fixture
             |> ContractFixture.update_changeset(%{position: position, fingerprint: fingerprint})
             |> Repo.update() do
          {:ok, _fixture} -> {:cont, :ok}
          {:error, changeset} -> {:halt, {:error, changeset}}
        end
      end
    end)
  end

  defp next_fixture_position([]), do: 0

  defp next_fixture_position(fixtures),
    do: fixtures |> Enum.map(& &1.position) |> Enum.max() |> Kernel.+(1)

  defp next_contract_version(monitor_id) do
    ContractVersion
    |> where([contract_version], contract_version.monitor_id == ^monitor_id)
    |> select([contract_version], max(contract_version.version))
    |> Repo.one()
    |> case do
      nil -> 1
      version -> version + 1
    end
  end

  defp draft_identity(nil, monitor) do
    %{
      contract_id: Ecto.UUID.generate(),
      contract_version: next_contract_version(monitor.id),
      monitor_id: monitor.id
    }
  end

  defp draft_identity(contract_version, monitor) do
    %{
      contract_id: contract_version.id,
      contract_version: contract_version.version,
      monitor_id: monitor.id
    }
  end

  defp ensure_editable_draft(%ContractVersion{}, _monitor), do: :ok

  defp ensure_editable_draft(nil, monitor) do
    if load_contract(monitor.id, :approved), do: {:error, :revision_required}, else: :ok
  end

  defp current_monitor_version(monitor) do
    version_id =
      Setup
      |> where(
        [setup],
        setup.monitor_id == ^monitor.id and setup.status == :completed
      )
      |> select([setup], setup.completed_monitor_version_id)
      |> Repo.one()

    load_monitor_version(monitor.id, version_id)
  end

  defp fetch_current_monitor_version(monitor) do
    case current_monitor_version(monitor) do
      %MonitorVersion{} = monitor_version -> {:ok, monitor_version}
      nil -> {:error, :setup_incomplete}
    end
  end

  defp load_monitor_version(_monitor_id, nil), do: nil

  defp load_monitor_version(monitor_id, version_id) do
    MonitorVersion
    |> where([version], version.id == ^version_id and version.monitor_id == ^monitor_id)
    |> Repo.one()
  end

  defp load_monitor(workspace_id, monitor_id) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id)
    |> Repo.one()
  end

  defp fetch_monitor(workspace_id, monitor_id) do
    case load_monitor(workspace_id, monitor_id) do
      %Monitor{} = monitor -> {:ok, monitor}
      nil -> {:error, :not_found}
    end
  end

  defp locked_monitor(workspace_id, monitor_id) do
    Monitor
    |> where([monitor], monitor.workspace_id == ^workspace_id and monitor.id == ^monitor_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp fetch_locked_monitor(workspace_id, monitor_id) do
    case locked_monitor(workspace_id, monitor_id) do
      %Monitor{} = monitor -> {:ok, monitor}
      nil -> {:error, :not_found}
    end
  end

  defp load_contract(monitor_id, status, options \\ []) do
    query =
      ContractVersion
      |> where([contract_version], contract_version.monitor_id == ^monitor_id)
      |> where([contract_version], contract_version.status == ^status)

    query = if options[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp load_fixtures(contract_version_id, options \\ []) do
    query =
      ContractFixture
      |> where([fixture], fixture.contract_version_id == ^contract_version_id)
      |> order_by([fixture], asc: fixture.position, asc: fixture.id)

    query = if options[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.all(query)
  end

  defp load_fixture(contract_version_id, fixture_id, options) do
    query =
      ContractFixture
      |> where(
        [fixture],
        fixture.contract_version_id == ^contract_version_id and fixture.id == ^fixture_id
      )

    query = if options[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.one(query)
  end

  defp load_coverage_waivers(contract_version_id, options \\ []) do
    query =
      CoverageWaiver
      |> where([waiver], waiver.contract_version_id == ^contract_version_id)
      |> order_by([waiver], asc: waiver.rule_id)

    query = if options[:lock], do: lock(query, "FOR UPDATE"), else: query
    Repo.all(query)
  end

  defp error_changeset(_contract_version, field, message),
    do: %ContractVersion{} |> change() |> add_error(field, message)

  defp record_contract_event!(contract_version, user, action, metadata \\ %{}) do
    Audit.record_event!(%{
      action: action,
      target_type: "contract_version",
      target_id: contract_version.id,
      workspace_id: contract_version.workspace_id,
      actor_user_id: user.id,
      metadata:
        Map.merge(
          %{
            "monitor_id" => contract_version.monitor_id,
            "version" => contract_version.version,
            "status" => Atom.to_string(contract_version.status),
            "template_key" => contract_version.template_key,
            "assistance_mode" => Atom.to_string(contract_version.assistance_mode),
            "fingerprint" => contract_version.fingerprint
          },
          metadata
        )
    })
  end

  defp record_fixture_event!(contract_version, fixture, user, action) do
    Audit.record_event!(%{
      action: action,
      target_type: "contract_fixture",
      target_id: fixture.id,
      workspace_id: contract_version.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "contract_version_id" => contract_version.id,
        "expected_status" => Atom.to_string(fixture.expected_status),
        "position" => fixture.position,
        "fingerprint" => fixture.fingerprint
      }
    })
  end

  defp record_coverage_waiver_event!(contract_version, waiver, user, action) do
    Audit.record_event!(%{
      action: "contract_coverage_waiver.#{action}",
      target_type: "contract_coverage_waiver",
      target_id: waiver.id,
      workspace_id: contract_version.workspace_id,
      actor_user_id: user.id,
      metadata: %{
        "contract_version_id" => contract_version.id,
        "monitor_id" => contract_version.monitor_id,
        "rule_id" => waiver.rule_id,
        "rule_fingerprint" => waiver.rule_fingerprint
      }
    })
  end

  defp version_id(nil), do: nil
  defp version_id(contract_version), do: contract_version.id

  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  def evaluation_prop(%Evaluation{} = evaluation) do
    %{
      status: evaluation.status,
      error: evaluation.error,
      rule_results: Enum.map(evaluation.rule_results, &rule_result_prop/1)
    }
  end

  defp rule_result_prop(%RuleResult{} = result) do
    %{
      rule_id: result.rule_id,
      rule_type: result.rule_type,
      severity: result.severity,
      status: result.status,
      code: result.code,
      explanation: result.explanation,
      evidence: result.evidence,
      child_rule_ids: result.child_rule_ids
    }
  end
end
