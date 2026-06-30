defmodule Dsxir.Optimizer.SIMBA.Stats do
  @moduledoc """
  Open-map result for `Dsxir.Optimizer.SIMBA`. New optimizer keys land
  alongside without versioning.
  """

  defstruct best_score: nil,
            best_program_idx: nil,
            steps: 0,
            num_candidates_total: 0,
            candidate_programs: [],
            trial_logs: %{},
            total_program_runs: 0,
            degraded: false,
            wall_clock_ms: 0

  @type t :: %__MODULE__{
          best_score: float() | nil,
          best_program_idx: non_neg_integer() | nil,
          steps: non_neg_integer(),
          num_candidates_total: non_neg_integer(),
          candidate_programs: [%{score: float(), program: Dsxir.Program.t()}],
          trial_logs: %{optional(non_neg_integer()) => map()},
          total_program_runs: non_neg_integer(),
          degraded: boolean(),
          wall_clock_ms: non_neg_integer()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.SIMBA.Stats{} = stats, opts) do
      concat([
        "#Dsxir.Optimizer.SIMBA.Stats<best_score: ",
        to_doc(stats.best_score, opts),
        ", steps: ",
        Integer.to_string(stats.steps),
        ", candidates: ",
        Integer.to_string(length(stats.candidate_programs)),
        ", degraded: ",
        to_doc(stats.degraded, opts),
        ">"
      ])
    end
  end
end
