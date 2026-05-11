defmodule Dsxir.Predictor do
  @moduledoc """
  Predictor behaviour. A predictor is a stateless module that turns inputs into
  a `%Dsxir.Prediction{}` by routing through an adapter and the active LM.
  """

  @type signature :: module() | Dsxir.Signature.Compiled.t()

  @callback forward(
              state :: Dsxir.Program.State.t(),
              signature :: signature(),
              inputs :: map(),
              opts :: keyword()
            ) :: {Dsxir.Program.State.t(), Dsxir.Prediction.t()}
end
