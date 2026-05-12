defmodule Dsxir.Module.Transformer do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @doc false
  @spec transform(Spark.Dsl.t()) :: {:ok, Spark.Dsl.t()} | {:error, term()}
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    entities = Transformer.get_entities(dsl_state, [:module])

    Enum.reduce_while(entities, {:ok, dsl_state}, fn decl, {:ok, acc} ->
      case compile_signature(decl, module) do
        {:ok, ^decl} ->
          {:cont, {:ok, acc}}

        {:ok, updated} ->
          {:cont,
           {:ok, Transformer.replace_entity(acc, [:module], updated, &(&1.name == decl.name))}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp compile_signature(%{signature: sig} = decl, _module) when is_atom(sig), do: {:ok, decl}

  defp compile_signature(%{signature: source} = decl, module) when is_binary(source) do
    case Dsxir.Signature.Parser.parse(source) do
      {:ok, compiled} ->
        {:ok, %{decl | signature: compiled}}

      {:error, reason} ->
        {:error,
         %Dsxir.Errors.Invalid.Signature{
           module: module,
           field: nil,
           reason: reason
         }}
    end
  end
end
