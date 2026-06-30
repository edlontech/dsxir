defmodule Dsxir.Optimizer.SIMBA.StatsTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.SIMBA.Stats

  describe "%Stats{}" do
    test "builds with default values" do
      stats = %Stats{}

      assert stats.best_score == nil
      assert stats.best_program_idx == nil
      assert stats.steps == 0
      assert stats.num_candidates_total == 0
      assert stats.candidate_programs == []
      assert stats.trial_logs == %{}
      assert stats.total_program_runs == 0
      assert stats.degraded == false
      assert stats.wall_clock_ms == 0
    end

    test "builds with all keys set" do
      fake_program = %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}}

      stats = %Stats{
        best_score: 0.85,
        best_program_idx: 3,
        steps: 8,
        num_candidates_total: 48,
        candidate_programs: [%{score: 0.85, program: fake_program}],
        trial_logs: %{0 => %{train_score: 0.5}, 1 => %{train_score: 0.7}},
        total_program_runs: 384,
        degraded: true,
        wall_clock_ms: 12_345
      }

      assert stats.best_score == 0.85
      assert stats.best_program_idx == 3
      assert stats.steps == 8
      assert stats.num_candidates_total == 48
      assert length(stats.candidate_programs) == 1
      assert stats.total_program_runs == 384
      assert stats.degraded == true
      assert stats.wall_clock_ms == 12_345
    end
  end

  describe "inspect/2" do
    test "renders a compact single-line summary" do
      stats = %Stats{best_score: 0.75, steps: 4, candidate_programs: []}
      result = inspect(stats)

      assert result =~ "#Dsxir.Optimizer.SIMBA.Stats<"
      assert result =~ "best_score:"
      assert result =~ "0.75"
      assert result =~ "steps:"
      assert result =~ "4"
      assert result =~ "candidates:"
      refute String.contains?(result, "\n")
    end

    test "includes candidate count, not program internals" do
      fake_program = %Dsxir.Program{
        source: nil,
        predictors: %{my_pred: :sensitive_data},
        metadata: %{secret: "do not dump"}
      }

      stats = %Stats{
        best_score: 0.9,
        steps: 2,
        candidate_programs: [
          %{score: 0.9, program: fake_program},
          %{score: 0.8, program: fake_program}
        ]
      }

      result = inspect(stats)

      assert result =~ "candidates: 2"
      refute result =~ "sensitive_data"
      refute result =~ "do not dump"
      refute result =~ "my_pred"
    end
  end
end
