defmodule Dsxir.Optimizer.MIPROv2.Proposer.Grounded do
  @moduledoc """
  Asks the proposer LM to produce `n_candidates` candidate instructions for a
  single predictor, grounded in a program summary, a dataset summary, and an
  optional stylistic tip.

  One LM call per invocation. The current instruction is prepended outside
  this module so the baseline always survives in the search space.

  On parse, the result is truncated or padded with empty strings so the
  returned list is always exactly `n_candidates` long; padding signals a
  degraded slot to the surrounding optimizer.
  """

  alias Dsxir.Optimizer.MIPROv2.Proposer.Tips
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @type args :: %{
          required(:program_summary) => String.t(),
          required(:dataset_summary) => String.t(),
          required(:predictor_decl) => map(),
          required(:tip) => Tips.tip(),
          required(:n_candidates) => pos_integer(),
          required(:lm) => {module(), keyword()}
        }

  @doc """
  Generate candidate instructions. See module doc for the argument map shape.
  """
  @spec run(args()) :: {:ok, [String.t()]} | {:error, term()}
  def run(%{
        program_summary: psum,
        dataset_summary: dsum,
        predictor_decl: decl,
        tip: tip,
        n_candidates: n,
        lm: {lm_module, lm_config}
      })
      when is_binary(psum) and is_binary(dsum) and is_integer(n) and n > 0 and
             is_atom(lm_module) and is_list(lm_config) do
    prompt = render_prompt(psum, dsum, decl, tip, n)

    case lm_module.generate_text(lm_config, [%{role: "user", content: prompt}], []) do
      {:ok, text, _usage} -> {:ok, parse(text, n)}
      {:error, exception} -> {:error, exception}
    end
  end

  defp render_prompt(psum, dsum, decl, tip, n) do
    tip_line = Tips.resolve(tip)

    fields =
      decl.signature
      |> SignatureRuntime.fields()
      |> Enum.map_join("\n", fn f -> "- #{f.name} (#{f.kind})" end)

    style_hint = if tip_line, do: "\nStyle hint: #{tip_line}", else: ""

    """
    You are writing #{n} alternative instructions for a single LLM predictor.

    Program summary:
    #{psum}

    Task summary:
    #{dsum}

    Predictor: #{inspect(decl.name)}
    Fields:
    #{fields}
    #{style_hint}

    Output #{n} distinct candidate instructions, one per line, prefixed with a number and a period (e.g., "1. ..."). Do not include any other text.
    """
  end

  defp parse(text, n) do
    lines =
      text
      |> String.split("\n", trim: true)
      |> Enum.map(&strip_numbering/1)
      |> Enum.reject(&(&1 == ""))

    take = Enum.take(lines, n)
    pad = List.duplicate("", max(0, n - length(take)))
    take ++ pad
  end

  defp strip_numbering(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\s*\d+\.\s*/, "")
    |> String.trim()
  end
end
