defmodule Dsxir.Optimizer.SIMBA.Strategy.AppendRule do
  @moduledoc """
  SIMBA strategy that reflects on a better-vs-worse trajectory pair and appends
  per-predictor advice to each named predictor's instruction. One LM call.

  Skips when the good trajectory is at or below the mini-batch 10th percentile
  or the bad trajectory is at or above the 90th percentile. When the good and
  bad scores tie (the degenerate case), the weaker-but-higher-percentile
  trajectory is blanked before rendering so the contrast still favours one side.

  The reflective LM runs the `OfferFeedback` signature through the adapter via
  `Dsxir.Predictor.Predict.forward/4` (the mechanism `Dsxir.Predictor.Refine`
  uses), and the parsed advice is appended to each predictor's effective
  instruction through `instructions_override`. A reflective-LM failure or
  unparseable advice degrades the strategy to `:skip` rather than crashing the
  optimization step.
  """

  @behaviour Dsxir.Optimizer.SIMBA.Strategy

  require Logger

  alias Dsxir.Errors
  alias Dsxir.Example
  alias Dsxir.Optimizer.SIMBA.Proposer.OfferFeedback
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Signature.Runtime

  @not_available %{"N/A" => "Prediction not available"}

  @impl Dsxir.Optimizer.SIMBA.Strategy
  def apply(bucket, program, ctx) do
    good = hd(bucket.records)
    bad = List.last(bucket.records)

    cond do
      good.score <= ctx.batch_p10 -> :skip
      bad.score >= ctx.batch_p90 -> :skip
      true -> generate(good, bad, program, ctx)
    end
  end

  defp generate(good, bad, program, ctx) do
    {good, bad} = maybe_blank(good, bad)

    case advice_map(good, bad, program, ctx.reflective_lm) do
      advice when map_size(advice) == 0 -> :skip
      advice -> {:ok, append_advice(program, advice)}
    end
  end

  defp maybe_blank(good, bad) do
    if good.score > bad.score, do: {good, bad}, else: {blank(good), bad}
  end

  defp blank(record), do: %{record | trace: [], score: "N/A", prediction: @not_available}

  defp advice_map(good, bad, program, reflective_lm) do
    inputs = feedback_inputs(good, bad, program)

    {_state, %Prediction{fields: fields}} =
      Dsxir.Predictor.Predict.forward(
        %Program.State{},
        OfferFeedback.signature(),
        inputs,
        lm: reflective_lm
      )

    OfferFeedback.parse(Map.get(fields, :advice))
  rescue
    e in [
      Errors.Adapter.ParseError,
      Errors.Adapter.ZoiValidation,
      Errors.Adapter.FallbackExhausted,
      Errors.LM.RequestFailed,
      Errors.LM.RateLimited,
      Errors.LM.ContextWindow,
      Errors.LM.Authentication,
      Errors.Invalid.Configuration,
      Errors.Framework.PredictorError,
      Errors.Halted.Plug,
      RuntimeError
    ] ->
      Logger.warning("SIMBA AppendRule reflective LM call failed: #{Exception.message(e)}")
      %{}
  end

  defp feedback_inputs(good, bad, program) do
    example = good.example

    %{
      program_inputs: render(Example.inputs(example)),
      oracle_metadata: render(Example.labels(example)),
      better_program_trajectory: OfferFeedback.render_trajectory(good.trace),
      better_program_outputs: render_outputs(good.prediction),
      better_reward_value: good.score,
      better_reward_info: render(good.metadata),
      worse_program_trajectory: OfferFeedback.render_trajectory(bad.trace),
      worse_program_outputs: render_outputs(bad.prediction),
      worse_reward_value: bad.score,
      worse_reward_info: render(bad.metadata),
      module_names: module_names(program)
    }
  end

  defp render(value), do: inspect(OfferFeedback.recursive_mask(value))

  defp render_outputs(%Prediction{fields: fields}), do: render(fields)
  defp render_outputs(other), do: render(other)

  defp module_names(program) do
    program.predictors |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp append_advice(program, advice) do
    valid = program.predictors |> Map.keys() |> MapSet.new()

    Enum.reduce(advice, program, fn {name_str, text}, prog ->
      case existing_predictor(name_str, valid) do
        {:ok, name} -> append_rule(prog, name, text)
        :error -> prog
      end
    end)
  end

  defp append_rule(program, name, advice) do
    state = Program.get_state(program, name)
    signature = Program.Source.signature_for(program.source, name)
    effective = effective_instruction(state, signature)
    override = if effective == "", do: advice, else: effective <> "\n\n" <> advice
    Program.put_state(program, name, %{state | instructions_override: override})
  end

  defp effective_instruction(%Program.State{instructions_override: nil}, signature) do
    case Runtime.instruction(signature) do
      nil -> ""
      instruction -> instruction
    end
  end

  defp effective_instruction(%Program.State{instructions_override: override}, _signature) do
    override
  end

  defp existing_predictor(name_str, valid) do
    name = String.to_existing_atom(name_str)
    if MapSet.member?(valid, name), do: {:ok, name}, else: :error
  rescue
    ArgumentError -> :error
  end
end
