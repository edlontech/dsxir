defmodule Dsxir.Signature.Parser do
  @moduledoc false

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field

  @typedoc """
  Controls how field-name atoms are resolved:

    * `:create` (default) — `String.to_atom/1`, for developer-authored
      signatures parsed at compile time.
    * `:existing` — `String.to_existing_atom/1`, for signatures reconstructed
      from untrusted serialized payloads, so a crafted blob cannot mint
      unbounded atoms. Unknown names yield `{:error, {:unknown_field, name}}`.
  """
  @type atom_mode :: :create | :existing

  @doc false
  @spec parse(String.t(), [{:atoms, atom_mode()}]) ::
          {:ok, Compiled.t()} | {:error, term()}
  def parse(source, opts \\ []) when is_binary(source) do
    mode = Keyword.get(opts, :atoms, :create)

    case String.split(source, "->", parts: 2) do
      [inputs_str, outputs_str] ->
        with {:ok, _} <- non_empty_side(inputs_str, :empty_inputs),
             {:ok, _} <- non_empty_side(outputs_str, :empty_outputs),
             {:ok, inputs} <- parse_field_list(inputs_str, :input, mode),
             {:ok, outputs} <- parse_field_list(outputs_str, :output, mode) do
          {:ok,
           %Compiled{
             fields: inputs ++ outputs,
             instruction: nil,
             source: {:string, source}
           }}
        end

      _ ->
        {:error, :missing_arrow}
    end
  end

  defp non_empty_side(str, reason) do
    if String.trim(str) == "" do
      {:error, reason}
    else
      {:ok, str}
    end
  end

  defp parse_field_list(str, kind, mode) do
    with {:ok, parts} <- validate_parts(split_fields(str)) do
      parts
      |> Enum.reduce_while({:ok, []}, &reduce_field(&1, &2, kind, mode))
      |> case do
        {:ok, fields} -> {:ok, Enum.reverse(fields)}
        err -> err
      end
    end
  end

  defp validate_parts(parts) do
    if Enum.any?(parts, &(String.trim(&1) == "")) do
      {:error, :empty_field}
    else
      {:ok, parts}
    end
  end

  defp reduce_field(part, {:ok, acc}, kind, mode) do
    case parse_field(String.trim(part), kind, mode) do
      {:ok, field} -> {:cont, {:ok, [field | acc]}}
      {:error, _} = err -> {:halt, err}
    end
  end

  defp split_fields(str) do
    str
    |> String.to_charlist()
    |> split_fields([], [], 0)
    |> Enum.map(&IO.iodata_to_binary/1)
  end

  defp split_fields([], current, acc, _depth), do: Enum.reverse([Enum.reverse(current) | acc])

  defp split_fields([?, | rest], current, acc, 0) do
    split_fields(rest, [], [Enum.reverse(current) | acc], 0)
  end

  defp split_fields([?[ | rest], current, acc, depth) do
    split_fields(rest, [?[ | current], acc, depth + 1)
  end

  defp split_fields([?] | rest], current, acc, depth) when depth > 0 do
    split_fields(rest, [?] | current], acc, depth - 1)
  end

  defp split_fields([ch | rest], current, acc, depth) do
    split_fields(rest, [ch | current], acc, depth)
  end

  defp parse_field(text, kind, mode) do
    case String.split(text, ":", parts: 2) do
      [name_str] -> build_field(name_str, "str", kind, mode)
      [name_str, type_str] -> build_field(name_str, String.trim(type_str), kind, mode)
    end
  end

  defp build_field(name_str, type_str, kind, mode) do
    with {:ok, name} <- valid_name(name_str, mode),
         {:ok, zoi} <- to_zoi(type_str) do
      {:ok, %Field{name: name, type: type_str, zoi: zoi, kind: kind, desc: nil}}
    end
  end

  defp valid_name(str, mode) do
    trimmed = String.trim(str)

    if Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, trimmed) do
      name_atom(trimmed, mode)
    else
      {:error, {:invalid_name, str}}
    end
  end

  defp name_atom(name, :create), do: {:ok, String.to_atom(name)}

  defp name_atom(name, :existing) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, {:unknown_field, name}}
  end

  defp to_zoi("str"), do: {:ok, Zoi.string()}
  defp to_zoi("int"), do: {:ok, Zoi.integer()}
  defp to_zoi("float"), do: {:ok, Zoi.float()}
  defp to_zoi("bool"), do: {:ok, Zoi.boolean()}
  defp to_zoi("dict"), do: {:ok, Zoi.map(Zoi.string(), Zoi.any(), [])}

  defp to_zoi(<<"list[", rest::binary>>) do
    case strip_trailing_bracket(rest) do
      {:ok, inner} ->
        with {:ok, inner_zoi} <- to_zoi(String.trim(inner)) do
          {:ok, Zoi.list(inner_zoi)}
        end

      :error ->
        {:error, {:unknown_type, "list[" <> rest}}
    end
  end

  defp to_zoi(other), do: {:error, {:unknown_type, other}}

  defp strip_trailing_bracket(str) do
    if String.ends_with?(str, "]") do
      {:ok, String.slice(str, 0, byte_size(str) - 1)}
    else
      :error
    end
  end
end
