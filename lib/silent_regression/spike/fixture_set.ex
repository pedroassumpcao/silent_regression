defmodule SilentRegression.Spike.FixtureSet do
  @moduledoc """
  Loads and validates the human-approved semantic fixture set.

  Official comparisons are deliberately restricted to the committed approved
  directory. Candidate or arbitrary fixture paths can never be used to produce
  an official Task 11 artifact.
  """

  alias SilentRegression.Spike.CaseSet
  alias SilentRegression.Spike.DeterministicChecks
  alias SilentRegression.Spike.Provider
  alias SilentRegression.Spike.Run

  @schema_version 1
  @fixture_conditions ~w(harmless_rewording subtle_regression obvious_regression)
  @fixture_labels ~w(acceptable regression)
  @fixture_severities ~w(none subtle obvious)
  @variant_types ~w(
    meaning_preserving
    style_only
    wrong_fact
    wrong_attribution
    unsupported_claim
    omission
    failed_abstention
    multiple_wrong_facts
  )

  @type loaded :: %{required(String.t()) => term()}

  @spec official_root() :: Path.t()
  def official_root do
    Path.expand("../../../test/fixtures/drift_spike/approved", __DIR__)
  end

  @doc "Loads the official fixture directory and verifies every declared fixture."
  @spec load(Path.t()) :: {:ok, loaded()} | {:error, map()}
  def load(root \\ official_root())

  def load(root) when is_binary(root) and root != "" do
    expanded_root = Path.expand(root)

    with :ok <- validate_official_root(expanded_root),
         manifest_path <- Path.join(expanded_root, "manifest.json"),
         {:ok, manifest_contents} <- read_file(manifest_path),
         {:ok, manifest} <- decode(manifest_contents, manifest_path),
         :ok <- validate_manifest(manifest),
         {:ok, cases_by_id} <- current_cases(),
         {:ok, fixtures} <- load_fixture_files(expanded_root, manifest, cases_by_id),
         :ok <- validate_blueprints(manifest, fixtures, cases_by_id) do
      {:ok,
       %{
         "root" => expanded_root,
         "manifest_path" => manifest_path,
         "manifest_sha256" => sha256(manifest_contents),
         "file_sha256s" =>
           Map.new(manifest["fixture_files"], &{&1["file"], &1["content_sha256"]}),
         "manifest" => manifest,
         "fixtures" => fixtures,
         "fixtures_by_case" => Enum.group_by(fixtures, & &1["case_id"])
       }}
    end
  end

  def load(root) do
    error(:unapproved_fixture_path, "Official fixture path must be a non-empty string", %{
      "actual" => inspect(root),
      "expected" => official_root()
    })
  end

  defp validate_official_root(root) do
    expected = official_root()

    if root == expected do
      :ok
    else
      error(
        :unapproved_fixture_path,
        "Official reports may use only the committed approved fixture directory",
        %{"actual" => root, "expected" => expected}
      )
    end
  end

  defp validate_manifest(manifest) when is_map(manifest) do
    fixture_files = manifest["fixture_files"]
    blueprints = manifest["batch_blueprints"]

    cond do
      manifest["schema_version"] != @schema_version ->
        error(:unsupported_fixture_schema, "Fixture manifest schema is unsupported", %{
          "actual" => manifest["schema_version"],
          "expected" => @schema_version
        })

      manifest["status"] != "approved" or manifest["review_required"] != false ->
        error(:unapproved_fixture_set, "Fixture manifest has not been approved", %{
          "review_required" => manifest["review_required"],
          "status" => manifest["status"]
        })

      not valid_approval_record?(manifest["approval_record"]) ->
        error(:invalid_fixture_manifest, "Fixture approval record is incomplete")

      not (is_integer(manifest["sample_size"]) and manifest["sample_size"] >= 2) ->
        error(:invalid_fixture_manifest, "Fixture sample_size must be at least two")

      not (is_list(fixture_files) and fixture_files != []) ->
        error(:invalid_fixture_manifest, "Fixture manifest must declare fixture files")

      not Enum.all?(fixture_files, &is_map/1) ->
        error(:invalid_fixture_manifest, "Fixture file declarations must be JSON objects")

      not (is_list(blueprints) and blueprints != []) ->
        error(:invalid_fixture_manifest, "Fixture manifest must declare batch blueprints")

      not Enum.all?(blueprints, &is_map/1) ->
        error(:invalid_fixture_manifest, "Batch blueprints must be JSON objects")

      true ->
        :ok
    end
  end

  defp validate_manifest(_manifest),
    do: error(:invalid_fixture_manifest, "Fixture manifest must be a JSON object")

  defp valid_approval_record?(record) when is_map(record) do
    Enum.all?(~w(approved_on method scope), &non_empty_string?(record[&1]))
  end

  defp valid_approval_record?(_record), do: false

  defp current_cases do
    cases = CaseSet.all()

    case CaseSet.validate(cases) do
      :ok ->
        {:ok, Map.new(cases, &{&1.id, &1})}

      {:error, reason} ->
        error(:invalid_case_set, "Current case set is invalid", %{"reason" => inspect(reason)})
    end
  end

  defp load_fixture_files(root, manifest, cases_by_id) do
    declared_files = Enum.map(manifest["fixture_files"], & &1["file"])

    with :ok <- validate_declared_files(root, declared_files) do
      manifest["fixture_files"]
      |> Enum.reduce_while({:ok, []}, fn declaration, {:ok, loaded} ->
        case load_fixture_file(root, declaration, cases_by_id) do
          {:ok, fixtures} -> {:cont, {:ok, Enum.reverse(fixtures, loaded)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> then(fn
        {:ok, fixtures} -> validate_unique_fixture_ids(Enum.reverse(fixtures))
        {:error, error} -> {:error, error}
      end)
    end
  end

  defp validate_declared_files(root, declared_files) do
    actual_files =
      root
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.basename/1)
      |> Enum.reject(&(&1 == "manifest.json"))
      |> Enum.sort()

    cond do
      not Enum.all?(declared_files, &safe_basename?/1) ->
        error(:invalid_fixture_manifest, "Fixture filenames must be safe basenames")

      Enum.uniq(declared_files) != declared_files ->
        error(:invalid_fixture_manifest, "Fixture filenames must be unique")

      Enum.sort(declared_files) != actual_files ->
        error(:invalid_fixture_manifest, "Declared fixture files do not match the directory", %{
          "actual" => actual_files,
          "declared" => Enum.sort(declared_files)
        })

      true ->
        :ok
    end
  end

  defp load_fixture_file(root, declaration, cases_by_id) when is_map(declaration) do
    path = Path.join(root, declaration["file"] || "")

    with {:ok, case_definition} <- fetch_case(cases_by_id, declaration["case_id"]),
         {:ok, contents} <- read_file(path),
         :ok <- validate_content_hash(contents, declaration),
         {:ok, document} <- decode(contents, path),
         :ok <- validate_document(document, declaration, case_definition),
         {:ok, fixtures} <- validate_fixtures(document["fixtures"], case_definition) do
      {:ok, fixtures}
    end
  end

  defp load_fixture_file(_root, _declaration, _cases_by_id),
    do: error(:invalid_fixture_manifest, "Fixture file declarations must be JSON objects")

  defp fetch_case(cases_by_id, case_id) do
    case Map.fetch(cases_by_id, case_id) do
      {:ok, case_definition} ->
        {:ok, case_definition}

      :error ->
        error(:invalid_fixture_manifest, "Fixture declaration references an unknown case", %{
          "case_id" => case_id
        })
    end
  end

  defp validate_document(document, declaration, case_definition) when is_map(document) do
    fixtures = document["fixtures"]

    actual_ids =
      if is_list(fixtures) do
        Enum.map(fixtures, fn
          fixture when is_map(fixture) -> fixture["id"]
          _fixture -> nil
        end)
      else
        []
      end

    cond do
      document["schema_version"] != @schema_version ->
        error(:unsupported_fixture_schema, "Fixture document schema is unsupported", %{
          "file" => declaration["file"]
        })

      document["status"] != "approved" ->
        error(:unapproved_fixture_set, "Fixture document has not been approved", %{
          "file" => declaration["file"]
        })

      document["case_id"] != case_definition.id or
          document["case_id"] != declaration["case_id"] ->
        error(:invalid_fixture_document, "Fixture case ID does not match its declaration", %{
          "file" => declaration["file"]
        })

      document["case_version"] != case_definition.version or
          document["case_fingerprint"] != case_definition.fingerprint ->
        error(:stale_fixture_set, "Fixture document does not match the current case snapshot", %{
          "case_id" => case_definition.id,
          "expected_fingerprint" => case_definition.fingerprint,
          "expected_version" => case_definition.version
        })

      not is_list(fixtures) or fixtures == [] ->
        error(:invalid_fixture_document, "Fixture document must contain fixtures", %{
          "file" => declaration["file"]
        })

      actual_ids != declaration["expected_fixture_ids"] ->
        error(:invalid_fixture_document, "Fixture IDs do not match the approved manifest", %{
          "actual" => actual_ids,
          "expected" => declaration["expected_fixture_ids"],
          "file" => declaration["file"]
        })

      true ->
        :ok
    end
  end

  defp validate_document(_document, declaration, _case_definition),
    do:
      error(:invalid_fixture_document, "Fixture document must be a JSON object", %{
        "file" => declaration["file"]
      })

  defp validate_content_hash(contents, declaration) do
    expected = declaration["content_sha256"]
    actual = sha256(contents)

    cond do
      not sha256?(expected) ->
        error(:invalid_fixture_manifest, "Fixture declaration has no valid content hash", %{
          "file" => declaration["file"]
        })

      actual != expected ->
        error(:fixture_content_changed, "Fixture content does not match its approved hash", %{
          "actual" => actual,
          "expected" => expected,
          "file" => declaration["file"]
        })

      true ->
        :ok
    end
  end

  defp validate_fixtures(fixtures, case_definition) do
    fixtures
    |> Enum.reduce_while({:ok, []}, fn fixture, {:ok, validated} ->
      case validate_fixture(fixture, case_definition) do
        {:ok, enriched} -> {:cont, {:ok, [enriched | validated]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> then(fn
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, error} -> {:error, error}
    end)
  end

  defp validate_fixture(fixture, case_definition) when is_map(fixture) do
    with :ok <- validate_fixture_shape(fixture),
         {:ok, deterministic} <-
           DeterministicChecks.evaluate(case_definition, fixture["output_text"]),
         :ok <- validate_expected_deterministic(fixture, deterministic) do
      {:ok,
       fixture
       |> Map.put("case_id", case_definition.id)
       |> Map.put("case_fingerprint", case_definition.fingerprint)}
    else
      {:error, %{"type" => _type} = error} ->
        {:error, error}

      {:error, reason} ->
        error(:invalid_fixture, "Fixture could not be evaluated", %{
          "fixture_id" => fixture["id"],
          "reason" => inspect(reason)
        })
    end
  end

  defp validate_fixture(_fixture, _case_definition),
    do: error(:invalid_fixture, "Fixture must be a JSON object")

  defp validate_fixture_shape(fixture) do
    valid? =
      non_empty_string?(fixture["id"]) and fixture["condition"] in @fixture_conditions and
        fixture["variant_type"] in @variant_types and
        fixture["intended_label"] in @fixture_labels and
        fixture["severity"] in @fixture_severities and is_list(fixture["failure_modes"]) and
        Enum.all?(fixture["failure_modes"], &non_empty_string?/1) and
        is_boolean(fixture["expected_deterministic_pass"]) and
        non_empty_string?(fixture["rationale"]) and non_empty_string?(fixture["output_text"])

    if valid?,
      do: :ok,
      else: error(:invalid_fixture, "Fixture shape is invalid", %{"fixture_id" => fixture["id"]})
  end

  defp validate_expected_deterministic(fixture, deterministic) do
    if fixture["expected_deterministic_pass"] == deterministic["all_passed"] do
      :ok
    else
      error(:invalid_fixture, "Fixture deterministic expectation no longer matches", %{
        "actual" => deterministic["all_passed"],
        "expected" => fixture["expected_deterministic_pass"],
        "fixture_id" => fixture["id"]
      })
    end
  end

  defp validate_unique_fixture_ids(fixtures) do
    ids = Enum.map(fixtures, & &1["id"])

    if Enum.uniq(ids) == ids,
      do: {:ok, fixtures},
      else: error(:invalid_fixture_manifest, "Fixture IDs must be unique across the set")
  end

  defp validate_blueprints(manifest, fixtures, cases_by_id) do
    blueprints = manifest["batch_blueprints"]
    ids = Enum.map(blueprints, & &1["id"])
    expected_case_ids = Map.keys(cases_by_id) |> MapSet.new()

    cond do
      Enum.uniq(ids) != ids ->
        error(:invalid_fixture_manifest, "Batch blueprint IDs must be unique")

      true ->
        Enum.reduce_while(blueprints, :ok, fn blueprint, :ok ->
          case validate_blueprint(blueprint, manifest["sample_size"], fixtures, expected_case_ids) do
            :ok -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
    end
  end

  defp validate_blueprint(blueprint, sample_size, fixtures, expected_case_ids)
       when is_map(blueprint) do
    assembly = blueprint["assembly"] || %{}
    matches = Enum.filter(fixtures, &fixture_matches?(&1, assembly["fixture_filter"] || %{}))

    cond do
      not non_empty_string?(blueprint["id"]) or blueprint["condition"] not in Run.conditions() or
          blueprint["intended_label"] not in @fixture_labels ->
        invalid_blueprint(blueprint, "identity or label is invalid")

      blueprint["sample_size"] != sample_size ->
        invalid_blueprint(blueprint, "sample size does not match the manifest")

      MapSet.new(blueprint["applies_to_case_ids"] || []) != expected_case_ids ->
        invalid_blueprint(blueprint, "case coverage is incomplete")

      not valid_rate?(blueprint["expected_regression_rate"]) ->
        invalid_blueprint(blueprint, "expected regression rate is invalid")

      matches == [] ->
        invalid_blueprint(blueprint, "fixture filter matches no approved fixtures")

      not all_cases_have_matches?(matches, expected_case_ids, blueprint["intended_label"]) ->
        invalid_blueprint(blueprint, "fixture filter does not cover every case and label")

      true ->
        validate_assembly(blueprint, assembly, sample_size)
    end
  end

  defp validate_blueprint(_blueprint, _sample_size, _fixtures, _expected_case_ids),
    do: error(:invalid_fixture_manifest, "Batch blueprint must be a JSON object")

  defp validate_assembly(blueprint, %{"type" => "cycle_matching_fixtures"}, _sample_size) do
    if blueprint["expected_regression_rate"] in [0.0, 1.0],
      do: :ok,
      else:
        invalid_blueprint(blueprint, "cycled batches must be entirely acceptable or regressed")
  end

  defp validate_assembly(
         blueprint,
         %{
           "type" => "replace_control_samples",
           "base_condition" => "control",
           "sample_indexes" => indexes
         },
         sample_size
       )
       when is_list(indexes) and indexes != [] do
    valid_indexes? =
      Enum.uniq(indexes) == indexes and
        Enum.all?(indexes, &(is_integer(&1) and &1 >= 0 and &1 < sample_size))

    expected_rate = length(indexes) / sample_size

    if valid_indexes? and abs(blueprint["expected_regression_rate"] - expected_rate) < 1.0e-12,
      do: :ok,
      else: invalid_blueprint(blueprint, "replacement indexes do not match the declared rate")
  end

  defp validate_assembly(blueprint, _assembly, _sample_size),
    do: invalid_blueprint(blueprint, "assembly type is unsupported or incomplete")

  defp all_cases_have_matches?(fixtures, expected_case_ids, intended_label) do
    Enum.all?(expected_case_ids, fn case_id ->
      Enum.any?(fixtures, fn fixture ->
        fixture["case_id"] == case_id and fixture["intended_label"] == intended_label
      end)
    end)
  end

  defp fixture_matches?(fixture, filter) when is_map(filter) and map_size(filter) > 0 do
    Enum.all?(filter, fn {key, value} -> fixture[key] == value end)
  end

  defp fixture_matches?(_fixture, _filter), do: false

  defp invalid_blueprint(blueprint, reason) do
    error(:invalid_fixture_manifest, "Batch blueprint is invalid", %{
      "batch_id" => blueprint["id"],
      "reason" => reason
    })
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        error(:fixture_read_failed, "Fixture file could not be read", %{
          "path" => path,
          "reason" => Atom.to_string(reason)
        })
    end
  end

  defp decode(contents, path) do
    case Jason.decode(contents) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        error(:invalid_fixture_json, "Fixture file contains invalid JSON", %{
          "path" => path,
          "reason" => Exception.message(reason)
        })
    end
  end

  defp safe_basename?(value) when is_binary(value) do
    value != "" and Path.basename(value) == value and Path.extname(value) == ".json"
  end

  defp safe_basename?(_value), do: false

  defp valid_rate?(value), do: is_number(value) and value >= 0 and value <= 1
  defp non_empty_string?(value), do: is_binary(value) and String.trim(value) != ""
  defp sha256?(value), do: is_binary(value) and String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp error(type, message, details \\ %{}) do
    {:error, Provider.error(type, message, details: details)}
  end
end
