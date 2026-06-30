defmodule Dsxir.Optimizer.SIMBA.Strategy do
  @moduledoc """
  Behaviour for SIMBA candidate-mutation strategies.

  Each strategy receives a trajectory bucket, the candidate program, and a
  context map, and either mutates the program or signals that the current
  candidate should be skipped.

  Context keys carried by `ctx`:

    * `batch_p10` — 10th percentile score across all sampled trajectories in
      the mini-batch. Used by all strategies as the low-quality skip threshold.
    * `batch_p90` — 90th percentile score. Used by `AppendRule` to guard the
      bad trajectory selection.
    * `reflective_lm` — `{impl, config}` tuple forwarded to the LM call in
      `AppendRule`. Not used by `AppendDemo`.
    * `source` — the source program picked from the pool for this candidate.
    * `rng` — current `:rand` state, threaded through strategies that need
      randomness.
    * `demo_input_field_maxlen` — maximum character length for any input field
      value in an augmented demo. `AppendDemo` truncates longer values.
  """

  @callback apply(bucket :: map(), program :: Dsxir.Program.t(), ctx :: map()) ::
              {:ok, Dsxir.Program.t()} | :skip
end
