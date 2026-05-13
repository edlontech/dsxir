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

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Signature.Compiled{fields: fields}, _opts) do
      {inputs, outputs} = Enum.split_with(fields, &(&1.kind == :input))
      concat(["#Dsxir.Signature.Compiled<", names(inputs), " -> ", names(outputs), ">"])
    end

    defp names([]), do: "_"
    defp names(fields), do: fields |> Enum.map_join(", ", &Atom.to_string(&1.name))
  end
end
