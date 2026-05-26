defmodule Dsxir.Predictor.Refine do
  @moduledoc """
  Like `Dsxir.Predictor.BestOfN`, but reflective: after a sub-threshold attempt
  it runs the internal `OfferFeedback` predictor over the captured trace and
  injects per-predictor corrective advice into the next attempt through the
  `Dsxir.Settings` `:hints` channel. Invoked from a `forward/2` body; not a
  declared predictor.

  Same opts as `BestOfN` plus `:feedback_lm` (a `{module, config}` tuple)
  overriding the LM used for the `OfferFeedback` call. With `threshold: nil`,
  every sub-final attempt is refined.
  """

  alias Dsxir.Predictor.Refine.Feedback
  alias Dsxir.Predictor.Sampling

  @doc """
  Run `program` up to `:n` times, refining each sub-threshold attempt with
  `OfferFeedback`-generated advice, and return the best-scoring prediction.
  """
  @spec run(Dsxir.Program.t(), map(), (map(), Dsxir.Prediction.t() -> number()), keyword()) ::
          {Dsxir.Program.t(), Dsxir.Prediction.t()}
  def run(program, inputs, reward_fn, opts) do
    threshold = Keyword.get(opts, :threshold)

    hook = fn
      nil ->
        nil

      %{pred: pred, reward: reward, trace: trace} ->
        if refine?(reward, threshold) do
          Feedback.advise(program, inputs, pred, reward, trace, opts)
        else
          %{}
        end
    end

    Sampling.run(
      program,
      inputs,
      reward_fn,
      opts |> Keyword.put(:event_name, :refine) |> Keyword.put(:on_attempt, hook)
    )
  end

  defp refine?(_reward, nil), do: true
  defp refine?(reward, threshold), do: reward < threshold
end
