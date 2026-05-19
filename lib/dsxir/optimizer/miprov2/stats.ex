defmodule Dsxir.Optimizer.MIPROv2.Stats do
  @moduledoc """
  Per-compile statistics returned from `Dsxir.Optimizer.MIPROv2.compile/4`.

  Stores per-trial records, full-eval records, aggregate counters, and the
  program / dataset summaries used to ground the proposer. Informational
  only — does not feed back into runtime behaviour.

  ## Persistence round-trip

  When a compiled program is saved with `Dsxir.save/2` and later restored
  with `Dsxir.load/3`, the stats are encoded into the artifact metadata
  under `program.metadata["_miprov2_stats"]`. The restored value is a plain
  string-keyed map (and `:trials` / `:full_evals` are plain maps too) — it
  is **not** rehydrated back into a `%#{inspect(__MODULE__)}{}` struct.
  This is symmetric with how `compiled_with` degrades to its raw atom
  representation when the optimizer module is not loaded at hydrate time.
  """

  alias __MODULE__.Record

  defmodule Record do
    @moduledoc "Per-trial record produced by `Dsxir.Optimizer.MIPROv2.Trial.run/1`."
    defstruct [
      :trial_index,
      :config,
      :score,
      :lm_calls,
      :cached_calls,
      :duration_ms
    ]

    @type t :: %__MODULE__{
            trial_index: non_neg_integer(),
            config: map(),
            score: float(),
            lm_calls: non_neg_integer(),
            cached_calls: non_neg_integer(),
            duration_ms: non_neg_integer()
          }

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%Dsxir.Optimizer.MIPROv2.Stats.Record{} = record, opts) do
        concat([
          "#Dsxir.Optimizer.MIPROv2.Stats.Record<trial: ",
          to_doc(record.trial_index, opts),
          ", score: ",
          to_doc(record.score, opts),
          ", lm: ",
          to_doc(record.lm_calls, opts),
          ", cached: ",
          to_doc(record.cached_calls, opts),
          ", ms: ",
          to_doc(record.duration_ms, opts),
          ">"
        ])
      end
    end
  end

  defstruct best_score: nil,
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

  @type t :: %__MODULE__{
          best_score: nil | float(),
          best_config: map(),
          trials: [Record.t()],
          full_evals: [Record.t()],
          proposer_calls: non_neg_integer(),
          total_task_lm_calls: non_neg_integer(),
          total_cached_calls: non_neg_integer(),
          program_summary: nil | String.t(),
          dataset_summary: nil | String.t(),
          wall_clock_ms: non_neg_integer(),
          degraded: boolean()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.MIPROv2.Stats{} = stats, opts) do
      concat([
        "#Dsxir.Optimizer.MIPROv2.Stats<best_score: ",
        to_doc(stats.best_score, opts),
        ", trials: ",
        Integer.to_string(length(stats.trials)),
        ", full_evals: ",
        Integer.to_string(length(stats.full_evals)),
        ", proposer_calls: ",
        Integer.to_string(stats.proposer_calls),
        ", task_lm: ",
        Integer.to_string(stats.total_task_lm_calls),
        ", cached: ",
        Integer.to_string(stats.total_cached_calls),
        ", ms: ",
        Integer.to_string(stats.wall_clock_ms),
        ", degraded: ",
        to_doc(stats.degraded, opts),
        ">"
      ])
    end
  end
end
