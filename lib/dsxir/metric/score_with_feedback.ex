defmodule Dsxir.Metric.ScoreWithFeedback do
  @moduledoc """
  Multi-objective score + feedback returned from a metric. Consumed by
  `Dsxir.Optimizer.GEPA`; transparent to `Dsxir.Evaluate` and other optimizers,
  which see only the aggregated scalar score.

  `score` is either a scalar `float()` or a per-objective `%{atom() => float()}`.
  When a map, `Dsxir.Metric.apply/4` aggregates it to scalar via the configured
  `:objective_aggregator` (default `:mean`, also accepts `:min`, `:max`, or a
  `{module, fun}` reference invoked as `apply(module, fun, [score_map])`).

  `feedback` is `nil`, a free-form `String.t()`, or a per-predictor map
  `%{atom() => String.t() | nil}`. GEPA's reflective proposer accepts all three
  shapes; non-GEPA consumers ignore the field.
  """

  @enforce_keys [:score, :feedback]
  defstruct score: nil, feedback: nil, meta: %{}

  @type predictor_feedback :: %{atom() => String.t() | nil}
  @type t :: %__MODULE__{
          score: float() | %{atom() => float()},
          feedback: nil | String.t() | predictor_feedback(),
          meta: map()
        }
end
