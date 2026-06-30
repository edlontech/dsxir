defmodule Dsxir.Integration.MIPROv2LiveTest do
  @moduledoc """
  Live-LM acceptance for MIPROv2. Tagged `:integration` and excluded from the
  default `mix test` run. Opt in with `mix test.integration` or
  `mix test --include integration test/dsxir/integration/miprov2_live_test.exs`.

  Requires `OPENAI_API_KEY` in the environment; when missing the test is
  skipped (matches the pattern used by other live tests so CI without
  credentials does not abort the suite).

  Asserts the ordering `MIPROv2 >= BootstrapFewShot >= baseline` on full-eval
  score against a synthetic GSM8K-shaped arithmetic word-problem split. Does
  **not** assert that TPE beats Random; only that the better of the two clears
  the BootstrapFewShot bar.
  """

  use ExUnit.Case, async: false

  alias Dsxir.Evaluate
  alias Dsxir.EvaluationResult
  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Optimizer.MIPROv2
  alias Dsxir.Optimizer.Search.Random
  alias Dsxir.Optimizer.Search.TPE
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Test.Fixtures.Metrics
  alias Dsxir.Test.Fixtures.Programs
  alias Dsxir.Test.Fixtures.Programs.ArithmeticQA

  @moduletag :integration
  @moduletag timeout: 600_000

  @model "openai:gpt-4o-mini"

  setup_all do
    case System.get_env("OPENAI_API_KEY") do
      key when is_binary(key) and key != "" ->
        Dsxir.configure(adapter: Dsxir.Adapter.Chat)

        {trainset, valset} = Programs.arithmetic_dataset(30, 15)
        {:ok, api_key: key, trainset: trainset, valset: valset}

      _ ->
        {:skip, "OPENAI_API_KEY not set"}
    end
  end

  test "MIPROv2 >= BootstrapFewShot >= baseline on full-eval score", ctx do
    program = Program.new(ArithmeticQA)
    metric = &Metrics.exact_match/3

    with_lm(ctx.api_key, fn ->
      baseline_score = score(program, ctx.valset, metric)

      {:ok, bfs_compiled, _bfs_stats} =
        Dsxir.compile(BootstrapFewShot, program, ctx.trainset, metric, max_bootstrapped_demos: 4)

      bfs_score = score(bfs_compiled, ctx.valset, metric)

      {:ok, miprov2_random_compiled, miprov2_random_stats} =
        Dsxir.compile(MIPROv2, program, ctx.trainset, metric,
          auto: :light,
          sampler: Random,
          seed: 42
        )

      {:ok, miprov2_tpe_compiled, miprov2_tpe_stats} =
        Dsxir.compile(MIPROv2, program, ctx.trainset, metric,
          auto: :light,
          sampler: TPE,
          seed: 42
        )

      miprov2_random_score = score(miprov2_random_compiled, ctx.valset, metric)
      miprov2_tpe_score = score(miprov2_tpe_compiled, ctx.valset, metric)
      miprov2_score = max(miprov2_random_score, miprov2_tpe_score)

      IO.puts("""

      === MIPROv2 acceptance ===
      baseline:       #{baseline_score}
      BFS:            #{bfs_score}
      MIPROv2 Random: #{miprov2_random_score}  (#{miprov2_random_stats.total_task_lm_calls} LM calls)
      MIPROv2 TPE:    #{miprov2_tpe_score}  (#{miprov2_tpe_stats.total_task_lm_calls} LM calls)
      """)

      assert miprov2_score >= bfs_score,
             "expected max(MIPROv2 random/TPE) >= BFS; got #{miprov2_score} vs #{bfs_score}"

      assert bfs_score >= baseline_score,
             "expected BFS >= baseline; got #{bfs_score} vs #{baseline_score}"
    end)
  end

  defp with_lm(api_key, fun) do
    Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: @model, api_key: api_key, temperature: 0.0]}],
      fun
    )
  end

  @spec score(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t()) :: float()
  defp score(program, valset, metric) do
    case Evaluate.run!(%Evaluate{devset: valset, metric: metric}, program) do
      %EvaluationResult{score: s} when is_float(s) -> s
    end
  end
end
