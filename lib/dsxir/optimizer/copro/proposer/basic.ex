defmodule Dsxir.Optimizer.COPRO.Proposer.Basic do
  @moduledoc """
  Round-zero COPRO proposer. Asks the proposer LM for improved instructions for
  a single predictor, grounded in that predictor's signature and the current
  instruction. The current instruction always occupies one of the returned
  slots so the baseline survives the search; the rest are padded with it on a
  parse shortfall. Returns exactly `n` instructions.
  """

  alias Dsxir.Optimizer.COPRO.Proposer
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @type ctx :: %{
          required(:kind) => :basic,
          required(:decl) => map(),
          required(:current_instruction) => nil | String.t(),
          required(:n) => pos_integer(),
          required(:temperature) => float(),
          required(:lm) => {module(), keyword()}
        }

  @doc "Generate exactly `ctx.n` candidate instructions. See the module doc."
  @spec run(ctx()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def run(%{
        decl: decl,
        current_instruction: current,
        n: n,
        temperature: temperature,
        lm: {lm_module, lm_config}
      })
      when is_integer(n) and n > 0 and is_atom(lm_module) and is_list(lm_config) do
    baseline = current || ""
    prompt = render_prompt(decl, baseline, n)

    case lm_module.generate_text(lm_config, [%{role: "user", content: prompt}],
           temperature: temperature
         ) do
      {:ok, text, _usage} ->
        proposed = Proposer.parse(text)
        {:ok, Proposer.pad([baseline | proposed], n, baseline)}

      {:error, exception} ->
        {:error, exception}
    end
  end

  defp render_prompt(decl, baseline, n) do
    inputs = decl.signature |> SignatureRuntime.inputs() |> Proposer.render_fields()
    outputs = decl.signature |> SignatureRuntime.outputs() |> Proposer.render_fields()

    """
    You are improving the instruction for a single LLM predictor.

    Predictor: #{inspect(decl.name)}

    Inputs:
    #{inputs}

    Outputs:
    #{outputs}

    Current instruction:
    #{baseline}

    Output #{n} distinct, improved instructions for this predictor, one per line, prefixed with a number and a period (e.g., "1. ..."). Do not include any other text.
    """
  end
end
