defmodule Dsxir.Program.OptimizableSite do
  @moduledoc "A predictor site eligible for optimizer demo writes."

  @enforce_keys [:name, :kind]
  defstruct [:name, :kind]

  @type kind :: :predictor
  @type t :: %__MODULE__{name: atom(), kind: kind()}
end
