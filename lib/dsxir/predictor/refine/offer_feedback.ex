defmodule Dsxir.Predictor.Refine.OfferFeedback do
  @moduledoc """
  Internal signature and trace-rendering helpers for `Dsxir.Predictor.Refine`.
  Given a failed attempt's trajectory, the active LM proposes per-predictor
  corrective advice that the next attempt injects through the `:hints` channel.
  Not a user-facing signature.
  """

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Trace.Entry

  @instruction """
  You are reviewing one attempt of a multi-step LLM program that scored below \
  its target. For each module named below, give one concrete, actionable \
  instruction that would raise the program's score. Only reference real module \
  names. Be specific.
  """

  @doc "The internal OfferFeedback signature run after a sub-threshold attempt."
  @spec signature() :: Compiled.t()
  def signature do
    %Compiled{
      fields: fields(),
      instruction: @instruction,
      source: {:offer_feedback, __MODULE__}
    }
  end

  defp fields do
    [
      %Field{
        name: :program_inputs,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "The program inputs."
      },
      %Field{
        name: :program_trajectory,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "Per-module inputs and outputs from the attempt."
      },
      %Field{
        name: :program_outputs,
        type: :string,
        zoi: Zoi.string(),
        kind: :input,
        desc: "The program's final outputs."
      },
      %Field{
        name: :reward_value,
        type: :number,
        zoi: Zoi.number(),
        kind: :input,
        desc: "The reward this attempt scored."
      },
      %Field{
        name: :target_threshold,
        type: :number,
        zoi: Zoi.number(),
        kind: :input,
        desc: "The reward the program should reach."
      },
      %Field{
        name: :module_names,
        type: {:list, :string},
        zoi: Zoi.list(Zoi.string()),
        kind: :input,
        desc: "Names of the modules you may advise."
      },
      %Field{
        name: :discussion,
        type: :string,
        zoi: Zoi.string(),
        kind: :output,
        desc: "Brief analysis of what went wrong."
      },
      %Field{
        name: :advice,
        type: {:list, :map},
        zoi: advice_zoi(),
        kind: :output,
        desc: "One {module, instruction} per module needing change."
      }
    ]
  end

  defp advice_zoi do
    Zoi.list(Zoi.object(%{module: Zoi.string(), instruction: Zoi.string()}))
  end

  @doc "Render a captured trace into a per-module trajectory string."
  @spec render_trajectory([Entry.t()]) :: String.t()
  def render_trajectory(trace) do
    Enum.map_join(trace, "\n\n", fn %Entry{predictor: name, inputs: inputs, prediction: pred} ->
      "## #{name}\ninputs: #{inspect(inputs)}\noutputs: #{inspect(pred.fields)}"
    end)
  end

  @doc "Unique predictor names from the trace, in first-seen order, as strings."
  @spec module_names([Entry.t()]) :: [String.t()]
  def module_names(trace) do
    trace |> Enum.map(&to_string(&1.predictor)) |> Enum.uniq()
  end
end
