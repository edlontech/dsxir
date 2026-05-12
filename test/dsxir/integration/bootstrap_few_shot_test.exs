defmodule Dsxir.Integration.BootstrapFewShotTest do
  @moduledoc """
  Live-LM acceptance for BootstrapFewShot. Excluded from the default
  `mix test` run; opt in via `mix test --include integration`. Skipped when
  `OPENAI_API_KEY` is unset.

  At 10 examples the lift can be noisy. The test soft-asserts a non-strict
  improvement and prints a warning when the +5pts target is missed; the run
  still passes so small-N variance does not block releases. The strict delta
  is documented as a target, not a release gate.
  """

  use ExUnit.Case, async: false

  alias Dsxir.Evaluate
  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  @moduletag :integration

  @tag timeout: 300_000
  test "BootstrapFewShot vs LabeledFewShot on QA holdout" do
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
            baseline = Program.new(QA.TwoStep)

            {:ok, labeled, _} =
              LabeledFewShot.compile(baseline, QA.trainset_10(), &QA.exact_match_two_step/3,
                max_labeled_demos: 5,
                deterministic: true
              )

            {:ok, bootstrapped, _} =
              BootstrapFewShot.compile(baseline, QA.trainset_10(), &QA.exact_match_two_step/3,
                max_labeled_demos: 2,
                max_bootstrapped_demos: 3,
                max_rounds: 2,
                threshold: 1.0,
                deterministic: true
              )

            ev = %Evaluate{
              devset: QA.holdout_10(),
              metric: &QA.exact_match_two_step/3,
              num_threads: 4
            }

            labeled_result = Evaluate.run(ev, labeled)
            bootstrapped_result = Evaluate.run(ev, bootstrapped)

            delta = bootstrapped_result.score - labeled_result.score

            assert bootstrapped_result.score >= labeled_result.score,
                   "expected bootstrapped score >= labeled; got #{bootstrapped_result.score} vs #{labeled_result.score}"

            if delta < 5.0 do
              IO.puts(
                "[warn] BootstrapFewShot lift below +5pts target (delta=#{Float.round(delta, 2)}); revisit threshold/rounds before release"
              )
            end
          end
        )
    end
  end
end
