defmodule Dsxir.Predictor.BestOfN do
  @moduledoc """
  Runs a program's `forward/2` up to `n` times with diverse sampling, scores
  each result with `reward_fn`, and returns the highest-reward attempt — or the
  first to clear `threshold`. Invoked directly from a `forward/2` body, like
  `Dsxir.Predictor.Parallel`; it is not a declared predictor.

  `reward_fn` receives the program inputs and the produced `%Dsxir.Prediction{}`
  and returns a number. Raising attempts are tolerated up to `:fail_count`
  (default `n`); past that the last error re-raises wrapped as
  `Dsxir.Errors.Framework.PredictorError`.

  ## Recognised opts

    * `:n` (required) — number of attempts.
    * `:threshold` — stop early once `reward >= threshold`. Defaults to `nil`
      (run all `n`, return the best).
    * `:fail_count` — failures tolerated before re-raising. Defaults to `n`.
    * `:temperature` — per-attempt sampling temperature. Defaults to `1.0`.
  """

  alias Dsxir.Predictor.Sampling

  @doc "Sample `program` up to `:n` times and return the highest-reward prediction (or the first to clear `:threshold`)."
  @spec run(Dsxir.Program.t(), map(), (map(), Dsxir.Prediction.t() -> number()), keyword()) ::
          {Dsxir.Program.t(), Dsxir.Prediction.t()}
  def run(program, inputs, reward_fn, opts) do
    Sampling.run(program, inputs, reward_fn, put_event(opts))
  end

  defp put_event(opts),
    do: opts |> Keyword.put(:event_name, :best_of_n) |> Keyword.put(:on_attempt, nil)
end
