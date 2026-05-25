defmodule Dsxir.Optimizer.COPRO.Stats do
  @moduledoc "Result statistics for a COPRO run. Open map by convention."

  alias __MODULE__.Record

  defmodule Record do
    @moduledoc "Per-candidate trial record produced during a COPRO run."
    defstruct [:trial_index, :round, :predictor, :instruction, :score, :accepted?, :duration_ms]

    @type t :: %__MODULE__{
            trial_index: non_neg_integer(),
            round: non_neg_integer(),
            predictor: atom(),
            instruction: String.t() | nil,
            score: float() | nil,
            accepted?: boolean(),
            duration_ms: non_neg_integer()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%Dsxir.Optimizer.COPRO.Stats.Record{} = record, opts) do
        concat([
          "#Dsxir.Optimizer.COPRO.Stats.Record<trial: ",
          to_doc(record.trial_index, opts),
          ", round: ",
          to_doc(record.round, opts),
          ", predictor: ",
          to_doc(record.predictor, opts),
          ", score: ",
          to_doc(record.score, opts),
          ", accepted?: ",
          to_doc(record.accepted?, opts),
          ", ms: ",
          to_doc(record.duration_ms, opts),
          ">"
        ])
      end
    end
  end

  defstruct best_score: nil,
            best_instructions: %{},
            rounds: 0,
            breadth: 0,
            trials: [],
            proposer_calls: 0,
            total_devset_evals: 0,
            wall_clock_ms: 0,
            degraded: false

  @type t :: %__MODULE__{
          best_score: nil | float(),
          best_instructions: %{atom() => String.t() | nil},
          rounds: non_neg_integer(),
          breadth: non_neg_integer(),
          trials: [Record.t()],
          proposer_calls: non_neg_integer(),
          total_devset_evals: non_neg_integer(),
          wall_clock_ms: non_neg_integer(),
          degraded: boolean()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.COPRO.Stats{} = stats, opts) do
      concat([
        "#Dsxir.Optimizer.COPRO.Stats<best_score: ",
        to_doc(stats.best_score, opts),
        ", rounds: ",
        Integer.to_string(stats.rounds),
        ", breadth: ",
        Integer.to_string(stats.breadth),
        ", predictors: ",
        Integer.to_string(map_size(stats.best_instructions)),
        ", trials: ",
        Integer.to_string(length(stats.trials)),
        ", proposer_calls: ",
        Integer.to_string(stats.proposer_calls),
        ", devset_evals: ",
        Integer.to_string(stats.total_devset_evals),
        ", ms: ",
        Integer.to_string(stats.wall_clock_ms),
        ", degraded: ",
        to_doc(stats.degraded, opts),
        ">"
      ])
    end
  end
end
