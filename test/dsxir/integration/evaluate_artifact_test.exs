defmodule Dsxir.Integration.EvaluateArtifactTest do
  @moduledoc """
  Live LM acceptance for the evaluate / compile / save-load surface. Excluded
  from the default mix test run; opt in via `mix test.integration`. Requires
  OPENAI_API_KEY.
  """

  use ExUnit.Case, async: false

  alias Dsxir.Evaluate
  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  @moduletag :integration

  test "LabeledFewShot lifts score over baseline on QA holdout" do
    case System.get_env("OPENAI_API_KEY") do
      api_key when api_key in [nil, ""] ->
        IO.warn("skipping live test: OPENAI_API_KEY not set")

      api_key ->
        Dsxir.context(
          [
            lm:
              {Dsxir.LM.Sycophant,
               [model: "openai:gpt-4o-mini", api_key: api_key, temperature: 0.0]}
          ],
          fn ->
            baseline = Program.new(QA.Prog)

            {:ok, compiled, _stats} =
              LabeledFewShot.compile(baseline, QA.trainset_10(), &QA.exact_match/3,
                max_labeled_demos: 5,
                deterministic: true
              )

            ev = %Evaluate{devset: QA.holdout_10(), metric: &QA.exact_match/3, num_threads: 4}

            baseline_result = Evaluate.run(ev, baseline)
            compiled_result = Evaluate.run(ev, compiled)

            assert compiled_result.score >= baseline_result.score
            assert compiled_result.errors.count == 0
          end
        )
    end
  end

  test "20-example devset evaluated with num_threads: 8 completes and counts errors" do
    case System.get_env("OPENAI_API_KEY") do
      api_key when api_key in [nil, ""] ->
        IO.warn("skipping live test: OPENAI_API_KEY not set")

      api_key ->
        Dsxir.context(
          [
            lm:
              {Dsxir.LM.Sycophant,
               [model: "openai:gpt-4o-mini", api_key: api_key, temperature: 0.0]}
          ],
          fn ->
            ev = %Evaluate{devset: QA.devset_20(), metric: &QA.exact_match/3, num_threads: 8}
            result = Evaluate.run(ev, Program.new(QA.Prog))
            assert length(result.results) == 20
            assert is_float(result.score)
          end
        )
    end
  end
end
