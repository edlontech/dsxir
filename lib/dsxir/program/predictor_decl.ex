defmodule Dsxir.Program.PredictorDecl do
  @moduledoc "Normalized predictor declaration as returned by `Source.predictors/1`."

  @enforce_keys [:name, :impl, :signature]
  defstruct [:name, :impl, :signature]

  @type t :: %__MODULE__{
          name: atom(),
          impl: module(),
          signature: module() | Dsxir.Signature.Compiled.t()
        }
end
