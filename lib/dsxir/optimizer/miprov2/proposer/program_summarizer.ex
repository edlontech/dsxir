defmodule Dsxir.Optimizer.MIPROv2.Proposer.ProgramSummarizer do
  @moduledoc """
  Asks the proposer LM to summarize a user program — its predictor names,
  signatures, and current instructions — in a few sentences.

  One LM call. The resulting summary feeds the grounded proposer alongside the
  dataset summary.
  """

  alias Dsxir.Module.Info, as: ModuleInfo
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @doc """
  Render a textual digest of `user_module` and ask `lm_module` (with
  `lm_config`) to summarize it. Returns `{:ok, summary}` on success and
  `{:error, exception}` when the LM impl reports an error.
  """
  @spec run(module(), {module(), keyword()}) :: {:ok, String.t()} | {:error, term()}
  def run(user_module, {lm_module, lm_config})
      when is_atom(user_module) and is_atom(lm_module) and is_list(lm_config) do
    body = render(user_module)

    prompt = """
    Summarize this LM program in 3-5 sentences. Describe what each predictor does and how they compose.

    #{body}
    """

    case lm_module.generate_text(lm_config, [%{role: "user", content: prompt}], []) do
      {:ok, text, _usage} -> {:ok, text}
      {:error, exception} -> {:error, exception}
    end
  end

  defp render(user_module) do
    user_module
    |> ModuleInfo.module()
    |> Enum.map_join("\n---\n", &render_decl/1)
  end

  defp render_decl(decl) do
    fields =
      decl.signature
      |> SignatureRuntime.fields()
      |> Enum.map_join("\n", fn f -> "  - #{f.name} :: #{inspect(f.type)} (#{f.kind})" end)

    instruction =
      case SignatureRuntime.instruction(decl.signature) do
        nil -> "(no instruction set)"
        text -> text
      end

    """
    Predictor: #{inspect(decl.name)}
    Signature fields:
    #{fields}
    Current instruction: #{instruction}
    """
  end
end
