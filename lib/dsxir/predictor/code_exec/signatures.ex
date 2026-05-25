defmodule Dsxir.Predictor.CodeExec.Signatures do
  @moduledoc """
  Builds the three synthetic signatures the engine drives, the same way
  `Dsxir.Predictor.ChainOfThought.augment/1` builds its reasoning-augmented
  signature. All three are `%Dsxir.Signature.Compiled{}`.

  All three builders take the user's **original** signature (a signature module
  or `%Dsxir.Signature.Compiled{}`), never the output of another builder.
  Passing a synthetic signature back in would compound instructions incorrectly.
  The engine always calls them with the user's signature.
  """

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime

  @doc """
  Builds the round-0 signature: the user's inputs plus a `:generated_code`
  output, instructed to write Elixir against the bound input variables.
  """
  @spec code_generate(Runtime.signature(), [atom()]) :: Compiled.t()
  def code_generate(signature, input_names) do
    %Compiled{
      fields: Runtime.inputs(signature) ++ [code_field()],
      instruction: generate_instruction(signature, input_names),
      source: {:code_generate, signature}
    }
  end

  @doc """
  Builds the retry signature: the user's inputs plus `:previous_code` and
  `:error` inputs and a `:generated_code` output, instructed to fix the prior
  attempt.
  """
  @spec code_regenerate(Runtime.signature(), [atom()]) :: Compiled.t()
  def code_regenerate(signature, input_names) do
    extra = [
      string_input(:previous_code, "The code from the previous attempt."),
      string_input(:error, "The error the previous attempt produced.")
    ]

    %Compiled{
      fields: Runtime.inputs(signature) ++ extra ++ [code_field()],
      instruction:
        generate_instruction(signature, input_names) <>
          "\n\nThe previous code failed with the error provided. Return corrected Elixir code.",
      source: {:code_regenerate, signature}
    }
  end

  @doc "The `input_names` argument is accepted for call-site uniformity with the other builders and is unused here."
  @spec generate_output(Runtime.signature(), [atom()]) :: Compiled.t()
  def generate_output(signature, _input_names) do
    extra = [
      string_input(:final_code, "The Elixir code that ran successfully."),
      string_input(:execution_result, "The value the code produced.")
    ]

    base_instruction =
      case Runtime.instruction(signature) do
        nil -> ""
        existing -> existing <> "\n\n"
      end

    %Compiled{
      fields: Runtime.inputs(signature) ++ extra ++ Runtime.outputs(signature),
      instruction:
        base_instruction <>
          "Use the code's execution result to produce the final answer.",
      source: {:generate_output, signature}
    }
  end

  defp generate_instruction(signature, input_names) do
    vars = Enum.map_join(input_names, ", ", &Atom.to_string/1)

    base =
      case Runtime.instruction(signature) do
        nil -> ""
        existing -> existing <> "\n\n"
      end

    base <>
      "Write Elixir code that computes the answer. The input variables " <>
      "(#{vars}) are already bound. The value of the last expression is the result. " <>
      "Return only raw Elixir code with no markdown code fences and no commentary."
  end

  defp code_field do
    %Field{
      name: :generated_code,
      type: :string,
      zoi: Zoi.string(),
      kind: :output,
      desc: "Elixir code that computes the answer."
    }
  end

  defp string_input(name, desc) do
    %Field{name: name, type: :string, zoi: Zoi.string(), kind: :input, desc: desc}
  end
end
