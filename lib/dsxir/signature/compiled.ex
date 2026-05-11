defmodule Dsxir.Signature.Compiled do
  @moduledoc """
  Runtime-compiled signature carrying the same introspection shape as a
  module-based signature. Produced by `Dsxir.Signature.from_string/2` and
  `Dsxir.Signature.from_string!/2` (string form) and by
  `Dsxir.Predictor.ChainOfThought` (field augmentation).

  Consumers go through `Dsxir.Signature.Runtime`, which dispatches on
  `module()` vs `%__MODULE__{}` so callers never branch.
  """

  alias Dsxir.Signature.Field

  defstruct fields: [], instruction: nil, source: nil

  @type t :: %__MODULE__{
          fields: [Field.t()],
          instruction: nil | String.t(),
          source: term()
        }
end
