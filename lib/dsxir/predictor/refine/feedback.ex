defmodule Dsxir.Predictor.Refine.Feedback do
  @moduledoc """
  Runs the `OfferFeedback` signature for `Dsxir.Predictor.Refine` and folds the
  result into a `%{predictor_name => advice}` map, keeping only keys that match
  real predictors in the program. Any failure yields `%{}` so a flaky feedback
  call degrades refinement to plain resampling rather than crashing the loop.
  """

  alias Dsxir.Prediction
  alias Dsxir.Predictor.Refine.OfferFeedback
  alias Dsxir.Program
  alias Dsxir.Settings

  @doc """
  Produce per-predictor corrective advice for a sub-threshold attempt. Returns
  `%{}` (degrade, never raise) on any feedback-generation failure.
  """
  @spec advise(Program.t(), map(), Prediction.t(), number(), [Dsxir.Trace.entry()], keyword()) ::
          %{atom() => String.t()}
  def advise(%Program{} = program, inputs, %Prediction{} = pred, reward, trace, opts) do
    threshold = Keyword.get(opts, :threshold)
    feedback_lm = Keyword.get(opts, :feedback_lm) || Settings.resolve(:lm)
    valid_names = program.predictors |> Map.keys() |> MapSet.new()

    try do
      feedback_inputs = %{
        program_inputs: inspect(inputs),
        program_trajectory: OfferFeedback.render_trajectory(trace),
        program_outputs: inspect(pred.fields),
        reward_value: reward,
        target_threshold: threshold || 1.0,
        module_names: OfferFeedback.module_names(trace)
      }

      {_state, %Prediction{fields: fields}} =
        Dsxir.Predictor.Predict.forward(
          %Program.State{},
          OfferFeedback.signature(),
          feedback_inputs,
          lm: feedback_lm
        )

      fields |> Map.get(:advice) |> fold_advice(valid_names)
    rescue
      _e -> %{}
    end
  end

  defp fold_advice(advice, valid_names) when is_list(advice) do
    Enum.reduce(advice, %{}, fn entry, acc ->
      with {:ok, module} <- fetch(entry, :module),
           {:ok, instruction} <- fetch(entry, :instruction),
           {:ok, name} <- existing_atom(module),
           true <- MapSet.member?(valid_names, name) do
        Map.put(acc, name, instruction)
      else
        _ -> acc
      end
    end)
  end

  defp fold_advice(_other, _valid_names), do: %{}

  defp fetch(entry, key) when is_map(entry) do
    case Map.get(entry, key) || Map.get(entry, to_string(key)) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> :error
    end
  end

  defp existing_atom(str) do
    {:ok, String.to_existing_atom(str)}
  rescue
    ArgumentError -> :error
  end
end
