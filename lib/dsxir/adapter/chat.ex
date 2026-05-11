defmodule Dsxir.Adapter.Chat do
  @moduledoc """
  Chat adapter: prompts the LM with `[[ ## field ## ]]` markers and parses the
  response by splitting on those markers, JSON-decoding typed fields, and
  validating each output through its Zoi schema.

  Returns `{:ok, map}` on success or `{:error, %Dsxir.Errors.Adapter.* {}}` on
  malformed output. No fallback to other adapters happens here.
  """

  @behaviour Dsxir.Adapter

  alias Dsxir.Signature.Runtime
  alias Sycophant.Message

  @marker ~r/\[\[\s*##\s*(?<name>[a-zA-Z0-9_]+)\s*##\s*\]\]/

  @impl Dsxir.Adapter
  def format(signature, inputs, demos, _opts) do
    [
      Message.system(system_prompt(signature)),
      Message.user(user_prompt(signature, inputs, demos))
    ]
  end

  @impl Dsxir.Adapter
  def parse(signature, response, _opts) when is_binary(response) do
    case extract_fields(signature, response) do
      {:ok, raw} ->
        validate_fields(signature, raw)

      {:error, reason} ->
        {:error,
         %Dsxir.Errors.Adapter.ParseError{
           adapter: __MODULE__,
           field: nil,
           reason: reason,
           raw_response: response
         }}
    end
  end

  defp system_prompt(signature) do
    instruction = Runtime.instruction(signature) || ""
    inputs_doc = render_field_list("Inputs:", Runtime.inputs(signature))
    outputs_doc = render_field_list("Outputs:", Runtime.outputs(signature))

    """
    #{instruction}

    Respond using the following marker protocol. For each output field, emit a
    line with `[[ ## field_name ## ]]` followed by the value on subsequent lines.
    Use JSON for non-string typed values (numbers, booleans, lists, objects).

    #{inputs_doc}
    #{outputs_doc}
    """
  end

  defp user_prompt(signature, inputs, demos) do
    demo_section = Enum.map_join(demos, "\n\n", &render_demo(signature, &1))

    input_section =
      Runtime.inputs(signature)
      |> Enum.map_join("\n", fn f ->
        "[[ ## #{f.name} ## ]]\n#{render_value(Map.fetch!(inputs, f.name))}"
      end)

    if demo_section == "" do
      input_section
    else
      "Examples:\n\n#{demo_section}\n\nNow your turn:\n\n#{input_section}"
    end
  end

  defp render_field_list(_label, []), do: ""

  defp render_field_list(label, fields) do
    bullets =
      Enum.map_join(fields, "\n", fn f ->
        desc = if f.desc, do: " — #{f.desc}", else: ""
        "  - #{f.name}#{desc}"
      end)

    "#{label}\n#{bullets}"
  end

  defp render_demo(signature, demo) when is_map(demo) do
    Runtime.fields(signature)
    |> Enum.map_join("\n", fn f ->
      value = Map.get(demo, f.name)
      "[[ ## #{f.name} ## ]]\n#{render_value(value)}"
    end)
  end

  defp render_value(v) when is_binary(v), do: v
  defp render_value(v), do: Jason.encode!(v)

  defp extract_fields(signature, response) do
    matches = Regex.scan(@marker, response, return: :index)
    declared = signature |> Runtime.fields() |> MapSet.new(& &1.name)

    case matches do
      [] -> {:error, :no_markers}
      _ -> build_field_map(response, matches, declared)
    end
  end

  defp build_field_map(response, matches, declared) do
    entries = collect_entries(response, matches, declared)

    case entries do
      [] -> {:error, :no_markers}
      _ -> {:ok, entries |> pair_values(response) |> Map.new()}
    end
  end

  defp collect_entries(response, matches, declared) do
    Enum.flat_map(matches, &match_to_entry(&1, response, declared))
  end

  defp match_to_entry([{full_start, full_len}, {name_start, name_len}], response, declared) do
    raw = binary_part(response, name_start, name_len)

    with {:ok, atom} <- safe_existing_atom(raw),
         true <- MapSet.member?(declared, atom) do
      [%{name: atom, value_start: full_start + full_len, marker_start: full_start}]
    else
      _ -> []
    end
  end

  defp pair_values(entries, response) do
    boundaries = Enum.map(entries, & &1.marker_start) ++ [byte_size(response)]

    entries
    |> Enum.with_index()
    |> Enum.map(fn {entry, idx} ->
      next_boundary = Enum.at(boundaries, idx + 1)

      value =
        response
        |> binary_part(entry.value_start, max(next_boundary - entry.value_start, 0))
        |> String.trim()

      {entry.name, value}
    end)
  end

  defp safe_existing_atom(s) do
    {:ok, String.to_existing_atom(s)}
  rescue
    ArgumentError -> :error
  end

  defp validate_fields(signature, raw) do
    outputs = Runtime.outputs(signature)

    Enum.reduce_while(outputs, {:ok, %{}}, fn field, {:ok, acc} ->
      case validate_field(field, raw) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field.name, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_field(field, raw) do
    case Map.fetch(raw, field.name) do
      {:ok, raw_value} ->
        field.zoi
        |> maybe_json_decode(raw_value)
        |> then(&Zoi.parse(field.zoi, &1))
        |> wrap_zoi_result(field)

      :error ->
        {:error,
         %Dsxir.Errors.Adapter.ParseError{
           adapter: __MODULE__,
           field: field.name,
           reason: :missing_field,
           raw_response: nil
         }}
    end
  end

  defp wrap_zoi_result({:ok, value}, _field), do: {:ok, value}

  defp wrap_zoi_result({:error, zoi_errors}, field) do
    {:error,
     %Dsxir.Errors.Adapter.ZoiValidation{
       adapter: __MODULE__,
       field: field.name,
       zoi_errors: zoi_errors
     }}
  end

  defp maybe_json_decode(zoi, raw) when is_binary(raw) do
    if string_schema?(zoi) do
      raw
    else
      case Jason.decode(raw, keys: :atoms) do
        {:ok, value} -> value
        {:error, _} -> raw
      end
    end
  end

  defp string_schema?(%Zoi.Types.String{}), do: true
  defp string_schema?(_), do: false
end
