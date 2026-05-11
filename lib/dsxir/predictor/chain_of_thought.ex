defmodule Dsxir.Predictor.ChainOfThought do
  @moduledoc """
  Wraps `Dsxir.Predictor.Predict` by prepending a `:reasoning :string` output
  field to the signature. The reasoning text lands on `pred.fields.reasoning`;
  remaining output fields follow.

  Behaviour-identical to `Predict` aside from the field augmentation.
  """

  @behaviour Dsxir.Predictor

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime

  @reasoning_directive "Reason step by step before answering."

  @impl Dsxir.Predictor
  def forward(%Dsxir.Program.State{} = state, signature, inputs, opts) do
    augmented = augment(signature)
    Dsxir.Predictor.Predict.forward(state, augmented, inputs, opts)
  end

  @doc false
  @spec augment(Runtime.signature()) :: Compiled.t()
  def augment(signature) do
    instruction =
      case Runtime.instruction(signature) do
        nil -> @reasoning_directive
        existing -> existing <> "\n\n" <> @reasoning_directive
      end

    reasoning_field = %Field{
      name: :reasoning,
      type: :string,
      zoi: Zoi.string(),
      kind: :output,
      desc: "Step-by-step reasoning that leads to the final answer."
    }

    %Compiled{
      fields: [reasoning_field | Runtime.fields(signature)],
      instruction: instruction,
      source: {:cot_of, signature}
    }
  end
end
