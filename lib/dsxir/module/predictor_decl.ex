defmodule Dsxir.Module.PredictorDecl do
  @moduledoc "Compile-time declaration of one predictor inside a user module."

  defstruct [:name, :impl, :signature, :__spark_metadata__]

  @type t :: %__MODULE__{
          name: atom(),
          impl: module(),
          signature: module(),
          __spark_metadata__: term()
        }
end
