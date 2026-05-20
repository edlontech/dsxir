defmodule Dsxir.Optimizer.GEPA.Proposer.Reflective do
  @moduledoc """
  Reflective instruction proposer. One LM call per invocation. Two flavours:

    * `rewrite/4` — single parent. Given the current instruction, sampled
      rollouts (success + failure feedback), and the signature, the LM rewrites
      the instruction.
    * `merge/5` — two parents. Given both parents' instructions and a small
      sample of feedback rollouts from each, the LM produces a hybrid.

  Both return `{:ok, instruction :: String.t()} | {:error, Exception.t()}`.
  Parsing strips numbering, leading "Instruction:" labels, and surrounding
  quotes — same defensiveness as `MIPROv2.Proposer.Grounded`.
  """

  alias Dsxir.Optimizer.GEPA.FeedbackPool
  alias Dsxir.Signature.Runtime, as: SignatureRuntime

  @type rollout :: FeedbackPool.rollout()

  @doc """
  Single-parent rewrite. Asks the LM to revise `current_instruction` in light
  of sampled `rollouts` (mix of successes and failures) and the predictor
  `signature`. One LM call.
  """
  @spec rewrite(
          current_instruction :: String.t(),
          rollouts :: [rollout()],
          signature :: module(),
          lm :: {module(), keyword()}
        ) :: {:ok, String.t()} | {:error, Exception.t()}
  def rewrite(current, rollouts, signature, {lm_mod, lm_cfg})
      when is_binary(current) and is_list(rollouts) and is_atom(signature) and is_atom(lm_mod) do
    prompt = render_rewrite_prompt(current, rollouts, signature)

    case lm_mod.generate_text(lm_cfg, [%{role: "user", content: prompt}], []) do
      {:ok, text, _usage} -> {:ok, parse(text)}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc """
  Two-parent merge. Asks the LM to produce a hybrid of `instr_a` and `instr_b`
  using parent A's rollouts as grounding evidence. One LM call.
  """
  @spec merge(
          parent_a_instruction :: String.t(),
          parent_b_instruction :: String.t(),
          rollouts_a :: [rollout()],
          signature :: module(),
          lm :: {module(), keyword()}
        ) :: {:ok, String.t()} | {:error, Exception.t()}
  def merge(instr_a, instr_b, rollouts_a, signature, {lm_mod, lm_cfg})
      when is_binary(instr_a) and is_binary(instr_b) and is_list(rollouts_a) and
             is_atom(signature) and is_atom(lm_mod) do
    prompt = render_merge_prompt(instr_a, instr_b, rollouts_a, signature)

    case lm_mod.generate_text(lm_cfg, [%{role: "user", content: prompt}], []) do
      {:ok, text, _usage} -> {:ok, parse(text)}
      {:error, exception} -> {:error, exception}
    end
  end

  defp render_rewrite_prompt(current, rollouts, signature) do
    fields = format_fields(signature)
    rollouts_block = format_rollouts(rollouts)

    """
    You are improving the instruction for a single LLM predictor inside a multi-step program.

    Below are sample rollouts under the current instruction. Each rollout includes the metric score and feedback.

    #{rollouts_block}

    Current instruction:
    "#{current}"

    Predictor signature:
    #{fields}

    Write a rewritten instruction that keeps the things working well and corrects the things that went wrong.
    Output exactly one instruction. No preamble, no numbering, no surrounding quotes.
    """
  end

  defp render_merge_prompt(instr_a, instr_b, rollouts_a, signature) do
    fields = format_fields(signature)
    rollouts_block = format_rollouts(rollouts_a)

    """
    You are merging two candidate instructions for the same LLM predictor. Each was produced by a separate optimization branch.

    Below are sample rollouts from parent A. Each includes the score and feedback.

    #{rollouts_block}

    Parent A instruction:
    "#{instr_a}"

    Parent B instruction:
    "#{instr_b}"

    Predictor signature:
    #{fields}

    Write a hybrid instruction that combines the strengths of both parents. The output must be a single instruction, not commentary about the merge.
    No preamble, no numbering, no surrounding quotes.
    """
  end

  defp format_fields(signature) do
    signature
    |> SignatureRuntime.fields()
    |> Enum.map_join("\n", fn f -> "  - #{f.name} (#{f.kind})" end)
  end

  defp format_rollouts([]), do: "  (no feedback rollouts available)"

  defp format_rollouts(rollouts) do
    Enum.map_join(rollouts, "\n", fn r ->
      "  score=#{:erlang.float_to_binary(r.score * 1.0, decimals: 2)}, " <>
        "feedback: #{inspect(r.feedback)}"
    end)
  end

  @doc false
  @spec parse(String.t()) :: String.t()
  def parse(text) when is_binary(text) do
    text
    |> String.trim()
    |> strip_leading_label()
    |> strip_numbering()
    |> strip_quotes()
    |> String.trim()
  end

  defp strip_leading_label(s) do
    String.replace(s, ~r/^\s*(instruction|instructions)\s*:\s*/i, "", global: false)
  end

  defp strip_numbering(s) do
    String.replace(s, ~r/^\s*\d+\.\s*/, "", global: false)
  end

  defp strip_quotes(s) do
    case s do
      <<"\"", rest::binary>> -> String.trim_trailing(rest, "\"")
      <<"'", rest::binary>> -> String.trim_trailing(rest, "'")
      _ -> s
    end
  end
end
