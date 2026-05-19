defmodule Dsxir.Optimizer.MIPROv2.StatsTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.MIPROv2.Stats
  alias Dsxir.Optimizer.MIPROv2.Stats.Record

  describe "%Stats{}" do
    test "defaults match the documented contract" do
      assert %Stats{
               best_score: nil,
               best_config: %{},
               trials: [],
               full_evals: [],
               proposer_calls: 0,
               total_task_lm_calls: 0,
               total_cached_calls: 0,
               program_summary: nil,
               dataset_summary: nil,
               wall_clock_ms: 0,
               degraded: false
             } = %Stats{}
    end

    test "accepts overrides without losing other defaults" do
      stats = %Stats{best_score: 0.5, trials: [%Record{trial_index: 0, score: 0.5}]}

      assert stats.best_score == 0.5
      assert [%Record{trial_index: 0, score: 0.5}] = stats.trials
      assert stats.degraded == false
    end
  end

  describe "%Stats.Record{}" do
    test "all fields are nil by default" do
      assert %Record{
               trial_index: nil,
               config: nil,
               score: nil,
               lm_calls: nil,
               cached_calls: nil,
               duration_ms: nil
             } = %Record{}
    end

    test "captures a populated trial entry" do
      record = %Record{
        trial_index: 3,
        config: %{{:a, :instruction} => 1, {:a, :demos} => 0},
        score: 0.75,
        lm_calls: 2,
        cached_calls: 1,
        duration_ms: 42
      }

      assert record.trial_index == 3
      assert record.score == 0.75
      assert record.lm_calls == 2
      assert record.cached_calls == 1
      assert record.duration_ms == 42
    end
  end

  describe "Inspect for Stats" do
    test "renders compact tag with key counters" do
      stats = %Stats{
        best_score: 0.85,
        trials: List.duplicate(%Record{}, 18),
        full_evals: List.duplicate(%Record{}, 4),
        proposer_calls: 6,
        total_task_lm_calls: 432,
        total_cached_calls: 67,
        wall_clock_ms: 9876,
        degraded: false
      }

      rendered = inspect(stats)
      assert rendered =~ "#Dsxir.Optimizer.MIPROv2.Stats<"
      assert rendered =~ "best_score: 0.85"
      assert rendered =~ "trials: 18"
      assert rendered =~ "full_evals: 4"
      assert rendered =~ "proposer_calls: 6"
      assert rendered =~ "task_lm: 432"
      assert rendered =~ "cached: 67"
      assert rendered =~ "ms: 9876"
      assert rendered =~ "degraded: false"
    end

    test "renders nil best_score without crashing" do
      assert inspect(%Stats{}) =~ "best_score: nil"
    end

    test "omits long summary strings" do
      stats = %Stats{
        program_summary: String.duplicate("p", 500),
        dataset_summary: String.duplicate("d", 500)
      }

      rendered = inspect(stats)
      refute rendered =~ "program_summary"
      refute rendered =~ "dataset_summary"
      refute rendered =~ String.duplicate("p", 50)
    end
  end

  describe "Inspect for Stats.Record" do
    test "renders compact tag with key fields" do
      record = %Record{
        trial_index: 3,
        config: %{},
        score: 0.85,
        lm_calls: 12,
        cached_calls: 3,
        duration_ms: 142
      }

      assert inspect(record) ==
               "#Dsxir.Optimizer.MIPROv2.Stats.Record<trial: 3, score: 0.85, lm: 12, cached: 3, ms: 142>"
    end

    test "renders nil fields without crashing" do
      assert inspect(%Record{}) ==
               "#Dsxir.Optimizer.MIPROv2.Stats.Record<trial: nil, score: nil, lm: nil, cached: nil, ms: nil>"
    end
  end
end
