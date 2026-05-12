defmodule Dsxir.Signature.Transformer do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @spec transform(Spark.Dsl.t()) :: {:ok, Spark.Dsl.t()} | {:error, term()}
  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    fields = Transformer.get_entities(dsl_state, [:signature])

    with :ok <- ensure_unique(module, fields, :input),
         :ok <- ensure_unique(module, fields, :output) do
      expand_fields(module, dsl_state, fields)
    end
  end

  defp expand_fields(module, dsl_state, fields) do
    Enum.reduce_while(fields, {:ok, dsl_state}, fn field, {:ok, acc} ->
      case expand_type(field.type) do
        {:ok, zoi} ->
          updated = %{field | zoi: zoi}

          {:cont,
           {:ok, Transformer.replace_entity(acc, [:signature], updated, &same_field?(&1, field))}}

        {:error, reason} ->
          {:halt,
           {:error,
            %Dsxir.Errors.Invalid.Signature{
              module: module,
              field: field.name,
              reason: reason
            }}}
      end
    end)
  end

  defp ensure_unique(module, fields, kind) do
    names =
      fields
      |> Enum.filter(&(&1.kind == kind))
      |> Enum.map(& &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        :ok

      [dup | _] ->
        {:error,
         %Dsxir.Errors.Invalid.Signature{
           module: module,
           field: dup,
           reason: {:duplicate_field, kind}
         }}
    end
  end

  defp same_field?(a, b), do: a.name == b.name and a.kind == b.kind

  defp expand_type(:string), do: {:ok, Zoi.string()}
  defp expand_type(:integer), do: {:ok, Zoi.integer()}
  defp expand_type(:float), do: {:ok, Zoi.float()}
  defp expand_type(:boolean), do: {:ok, Zoi.boolean()}

  defp expand_type({:list, inner}) do
    with {:ok, expanded} <- expand_type(inner) do
      {:ok, Zoi.list(expanded)}
    end
  end

  defp expand_type(%_{} = zoi_struct) do
    if zoi_schema?(zoi_struct),
      do: {:ok, zoi_struct},
      else: {:error, {:not_a_zoi_schema, zoi_struct}}
  end

  defp expand_type(Dsxir.Primitives.History), do: {:ok, Zoi.any()}

  defp expand_type(other), do: {:error, {:unknown_type, other}}

  defp zoi_schema?(struct), do: Zoi.Type.impl_for(struct) != nil
end
