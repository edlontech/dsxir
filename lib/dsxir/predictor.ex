defmodule Dsxir.Predictor do
  @moduledoc """
  Predictor behaviour. A predictor is a stateless module that turns inputs into
  a `%Dsxir.Prediction{}` by routing through an adapter and the active LM.

  ## Augmented outputs

  Some predictors synthesize extra output fields at runtime that are not
  declared on the underlying signature module (e.g. `:reasoning` from
  `Dsxir.Predictor.ChainOfThought`, `:trajectory` from
  `Dsxir.Predictor.ReAct`). Impls report these via the optional
  `c:augmented_outputs/1` callback so that `Dsxir.Artifact` allows them
  through the demo field validation on save/load. The callback is
  optional; impls that do not augment their signature can omit it.
  """

  @type signature :: module() | Dsxir.Signature.Compiled.t()

  @callback forward(
              state :: Dsxir.Program.State.t(),
              signature :: signature(),
              inputs :: map(),
              opts :: keyword()
            ) :: {Dsxir.Program.State.t(), Dsxir.Prediction.t()}

  @doc """
  Output field names synthesized by the predictor at runtime, in addition
  to the declared outputs of `signature`. Optional. Defaults to `[]` for
  impls that do not implement it.
  """
  @callback augmented_outputs(signature()) :: [atom()]

  @optional_callbacks [augmented_outputs: 1]

  @doc """
  Resolve the augmented output names for `impl` against `signature`, or
  return `[]` when the impl does not implement `c:augmented_outputs/1`.
  """
  @spec augmented_outputs(module(), signature()) :: [atom()]
  def augmented_outputs(impl, signature) when is_atom(impl) do
    if Code.ensure_loaded?(impl) and function_exported?(impl, :augmented_outputs, 1) do
      impl.augmented_outputs(signature)
    else
      []
    end
  end
end
