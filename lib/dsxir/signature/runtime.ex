defmodule Dsxir.Signature.Runtime do
  @moduledoc """
  Stable introspection surface for signature modules. Callers depend on this
  module rather than on the Spark `Info` generator output.
  """

  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Info

  @spec fields(module()) :: [Field.t()]
  def fields(signature_module), do: Info.signature(signature_module)

  @spec inputs(module()) :: [Field.t()]
  def inputs(signature_module) do
    signature_module |> fields() |> Enum.filter(&(&1.kind == :input))
  end

  @spec outputs(module()) :: [Field.t()]
  def outputs(signature_module) do
    signature_module |> fields() |> Enum.filter(&(&1.kind == :output))
  end

  @spec instruction(module()) :: nil | String.t()
  def instruction(signature_module) do
    case Info.signature_instruction(signature_module) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @spec zoi_for(module(), atom()) :: {:ok, Zoi.schema()} | :error
  def zoi_for(signature_module, name) do
    case Enum.find(fields(signature_module), &(&1.name == name)) do
      %Field{zoi: zoi} when not is_nil(zoi) -> {:ok, zoi}
      _ -> :error
    end
  end
end
