defmodule SilentRegression.Spike.SemanticLayer.RepresentationTest do
  use ExUnit.Case, async: true

  alias SilentRegression.Spike.SemanticLayer.Representation
  alias SilentRegression.Spike.SemanticLayer.Representation.CharacterNgram
  alias SilentRegression.Spike.SemanticLayer.Representation.FieldAware
  alias SilentRegression.Spike.SemanticLayer.Representation.WordNgram
  alias SilentRegression.Spike.Statistics

  test "word n-grams retain local ordering" do
    {:ok, model} = Representation.fit(WordNgram, ["cats chase dogs", "dogs chase cats"])
    {:ok, first} = Representation.encode(model, "cats chase dogs")
    {:ok, reordered} = Representation.encode(model, "dogs chase cats")

    assert Representation.distance(first, reordered) > 0.0
    assert first["word:2:cats chase"] > 0.0
    refute Map.has_key?(first, "word:2:dogs chase")
  end

  test "character n-grams ignore punctuation and presentation changes" do
    {:ok, model} = Representation.fit(CharacterNgram, ["Dock 3 is ready."])
    {:ok, plain} = Representation.encode(model, "Dock 3 is ready.")
    {:ok, formatted} = Representation.encode(model, "**DOCK 3** — is ready!")

    assert_in_delta Representation.distance(plain, formatted), 0.0, 1.0e-12
  end

  test "field-aware features normalize prohibition wording and expose changed facts" do
    fit_documents = [
      "Pile-driving is prohibited through July [habitat]. Speed is 12 knots.",
      "Pile-driving is barred through July [habitat]. Speed is 12 knots."
    ]

    {:ok, model} = Representation.fit(FieldAware, fit_documents)
    {:ok, prohibited} = Representation.encode(model, Enum.at(fit_documents, 0))
    {:ok, barred} = Representation.encode(model, Enum.at(fit_documents, 1))

    {:ok, permitted} =
      Representation.encode(
        model,
        "Pile-driving is permitted through July [habitat]. Speed is 14 knots."
      )

    assert_in_delta Representation.distance(prohibited, barred), 0.0, 1.0e-12
    assert Representation.distance(prohibited, permitted) > 0.25
    assert permitted["citation_polarity:habitat:positive"] > 0.0
    assert permitted["quantity:14"] > 0.0
  end

  test "field-aware JSON features preserve paths and scalar values" do
    document = ~s({"route":{"minutes":19,"funded":true}})
    {:ok, model} = Representation.fit(FieldAware, [document])
    {:ok, vector} = Representation.encode(model, document)

    assert vector["json_path:$.route.minutes"] > 0.0
    assert vector["json_path_value:$.route.minutes=19"] > 0.0
  end

  test "candidate-only features are retained with a smoothed IDF" do
    {:ok, model} = Representation.fit(WordNgram, ["known baseline fact"])
    {:ok, vector} = Representation.encode(model, "unseen candidate fact")

    assert vector["word:1:unseen"] > 0.0
    assert vector["word:2:unseen candidate"] > 0.0
  end

  test "shared statistics use fitted representations deterministically" do
    reference = ["alpha beta", "alpha gamma", "alpha delta"]
    candidate = ["omega psi", "omega chi", "omega phi"]
    {:ok, model} = Representation.fit(WordNgram, reference)
    metric_options = Representation.statistics_options(model)

    options = Keyword.merge(metric_options, seed: 42, permutations: 99)

    assert {:ok, first} = Statistics.permutation_test(reference, candidate, options)
    assert {:ok, second} = Statistics.permutation_test(reference, candidate, options)
    assert first == second
    assert first["observed_energy"] > 0.0
  end
end
