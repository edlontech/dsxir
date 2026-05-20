defmodule Dsxir.RuntimeProgram.FieldSpec do
  @moduledoc "Typed I/O slot on a runtime program's boundary."

  @enforce_keys [:name, :type]
  defstruct [:name, :type, description: nil]

  @type t :: %__MODULE__{
          name: atom(),
          type: term(),
          description: nil | String.t()
        }
end
