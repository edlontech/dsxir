defmodule Dsxir.Optimizer.COPRO.Proposer.GivenAttempts do
  @moduledoc """
  Later-round COPRO proposer. Asks the proposer LM for improved instructions for
  a single predictor, grounded in that predictor's signature and the sorted
  attempt history (worst-first, so the strongest instruction reads last and
  anchors the LM). Parse shortfalls are padded with the best attempt's
  instruction. Returns exactly `n` instructions.
  """

  alias Dsxir.Optimizer.COPRO.Proposer
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @type attempt :: %{instruction: String.t(), score: number()}
  @type ctx :: %{
          required(:kind) => :given_attempts,
          required(:decl) => map(),
          required(:attempts) => [attempt()],
          required(:n) => pos_integer(),
          required(:temperature) => float(),
          required(:lm) => {module(), keyword()}
        }

  @doc "Generate exactly `ctx.n` candidate instructions. See the module doc."
  @spec run(ctx()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def run(%{
        decl: decl,
        attempts: attempts,
        n: n,
        temperature: temperature,
        lm: {lm_module, lm_config}
      })
      when is_list(attempts) and is_integer(n) and n > 0 and is_atom(lm_module) and
             is_list(lm_config) do
    prompt = render_prompt(decl, attempts, n)
    fallback = best_instruction(attempts)

    case lm_module.generate_text(lm_config, [%{role: "user", content: prompt}],
           temperature: temperature
         ) do
      {:ok, text, _usage} ->
        {:ok, Proposer.pad(Proposer.parse(text), n, fallback)}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp best_instruction([]), do: ""

  defp best_instruction(attempts) do
    attempts |> Enum.max_by(& &1.score) |> Map.fetch!(:instruction)
  end

  defp render_prompt(decl, attempts, n) do
    inputs = decl.signature |> SignatureRuntime.inputs() |> Proposer.render_fields()
    outputs = decl.signature |> SignatureRuntime.outputs() |> Proposer.render_fields()
    history = render_attempts(attempts)

    """
    You are improving the instruction for a single LLM predictor.

    Predictor: #{inspect(decl.name)}

    Inputs:
    #{inputs}

    Outputs:
    #{outputs}

    Previous attempts, worst-first, with their scores:
    #{history}

    Output #{n} distinct instructions that should outperform the attempts above, one per line, prefixed with a number and a period (e.g., "1. ..."). Do not include any other text.
    """
  end

  defp render_attempts(attempts) do
    attempts
    |> Enum.sort_by(& &1.score)
    |> Enum.map_join("\n", fn %{instruction: instruction, score: score} ->
      "- (#{score}) #{instruction}"
    end)
  end
end
