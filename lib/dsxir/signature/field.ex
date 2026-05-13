defmodule Dsxir.Signature.Field do
  @moduledoc """
  Internal struct produced by the Signature DSL for each `input` / `output` entity.

  `:type` holds the raw user value (shorthand atom, tuple, or Zoi schema). `:zoi`
  is populated by the transformer with the canonical Zoi schema. `:kind` is
  `:input` or `:output`.
  """

  @derive {Inspect, except: [:__spark_metadata__]}
  defstruct [:name, :type, :zoi, :kind, :desc, :__spark_metadata__]

  @type kind :: :input | :output
  @type t :: %__MODULE__{
          name: atom(),
          type: term(),
          zoi: nil | Zoi.schema(),
          kind: kind(),
          desc: nil | String.t(),
          __spark_metadata__: term()
        }
end
