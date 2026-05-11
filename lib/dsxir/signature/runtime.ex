defmodule Dsxir.Signature.Runtime do
  @moduledoc """
  Stable introspection surface for signature modules. Callers depend on this
  module rather than on the Spark `Info` generator output.
  """

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Info

  @type signature :: module() | Compiled.t()

  @spec fields(signature()) :: [Field.t()]
  def fields(%Compiled{fields: fs}), do: fs

  def fields(signature_module) when is_atom(signature_module),
    do: Info.signature(signature_module)

  @spec inputs(signature()) :: [Field.t()]
  def inputs(signature) do
    signature |> fields() |> Enum.filter(&(&1.kind == :input))
  end

  @spec outputs(signature()) :: [Field.t()]
  def outputs(signature) do
    signature |> fields() |> Enum.filter(&(&1.kind == :output))
  end

  @spec instruction(signature()) :: nil | String.t()
  def instruction(%Compiled{instruction: i}), do: i

  def instruction(signature_module) when is_atom(signature_module) do
    case Info.signature_instruction(signature_module) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  @spec zoi_for(signature(), atom()) :: {:ok, Zoi.schema()} | :error
  def zoi_for(signature, name) do
    case Enum.find(fields(signature), &(&1.name == name)) do
      %Field{zoi: zoi} when not is_nil(zoi) -> {:ok, zoi}
      _ -> :error
    end
  end
end
