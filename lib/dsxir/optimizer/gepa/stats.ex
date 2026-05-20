defmodule Dsxir.Optimizer.GEPA.Stats do
  @moduledoc """
  Open-map result for `Dsxir.Optimizer.GEPA.compile/4`. New optimizer keys land
  alongside without versioning.
  """

  defstruct best_score: nil,
            best_individual_id: nil,
            generations: 0,
            population_size: 0,
            frontier_size: 0,
            trials: [],
            proposer_calls: 0,
            total_devset_evals: 0,
            total_task_lm_calls: 0,
            degraded: false,
            wall_clock_ms: 0

  @type trial_record :: %{
          trial_idx: non_neg_integer(),
          individual_id: String.t() | nil,
          operator: atom(),
          accepted?: boolean(),
          score: float() | nil
        }

  @type t :: %__MODULE__{
          best_score: float() | nil,
          best_individual_id: String.t() | nil,
          generations: non_neg_integer(),
          population_size: non_neg_integer(),
          frontier_size: non_neg_integer(),
          trials: [trial_record()],
          proposer_calls: non_neg_integer(),
          total_devset_evals: non_neg_integer(),
          total_task_lm_calls: non_neg_integer(),
          degraded: boolean(),
          wall_clock_ms: non_neg_integer()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.GEPA.Stats{} = stats, opts) do
      concat([
        "#Dsxir.Optimizer.GEPA.Stats<best_score: ",
        to_doc(stats.best_score, opts),
        ", generations: ",
        Integer.to_string(stats.generations),
        ", population: ",
        Integer.to_string(stats.population_size),
        ", frontier: ",
        Integer.to_string(stats.frontier_size),
        ", trials: ",
        Integer.to_string(length(stats.trials)),
        ", proposer_calls: ",
        Integer.to_string(stats.proposer_calls),
        ", devset_evals: ",
        Integer.to_string(stats.total_devset_evals),
        ", task_lm: ",
        Integer.to_string(stats.total_task_lm_calls),
        ", ms: ",
        Integer.to_string(stats.wall_clock_ms),
        ", degraded: ",
        to_doc(stats.degraded, opts),
        ">"
      ])
    end
  end
end
