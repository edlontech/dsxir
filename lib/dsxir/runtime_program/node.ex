defmodule Dsxir.RuntimeProgram.Node do
  @moduledoc "One predictor invocation site inside a runtime program."

  @enforce_keys [:name, :impl, :signature]
  defstruct [:name, :impl, :signature, guard: nil]

  @type t :: %__MODULE__{
          name: atom(),
          impl: module(),
          signature: module() | Dsxir.Signature.Compiled.t(),
          guard: nil | Dsxir.Predicate.Source.t()
        }
end
