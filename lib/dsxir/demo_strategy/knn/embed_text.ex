defmodule Dsxir.DemoStrategy.KNN.EmbedText do
  @moduledoc """
  Deterministic input-map rendering for KNN embedding.

  Used at both compile (embedding trainset examples) and inference (embedding
  the live query) so the two representations land in the same vector space.

  ## Rules

    * `embed_fields: :all` — every key in `inputs`, sorted alphabetically.
    * `embed_fields: [:a, :b]` — only those keys, in the declared order.

  Each field renders as `"<name>: <value>\\n"`. Values render via:

    * `to_string/1` for strings, atoms (including booleans), numbers.
    * `Jason.encode!/1` for lists and maps.
    * Raise `Dsxir.Errors.Invalid.Configuration{reason: :unembeddable_input}`
      for opaque structs that aren't enumerable.

  Missing fields render as `"<name>: nil\\n"`. The renderer never raises on
  missing keys — that is by design.
  """

  alias Dsxir.Errors

  @type fields :: :all | [atom()]

  @doc """
  Render `inputs` to the deterministic embed-text string used at both compile
  time and inference time. See the module doc for the field-selection rules
  and value-rendering policy.
  """
  @spec render(map(), fields()) :: String.t()
  def render(inputs, :all) when is_map(inputs) do
    inputs
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map_join("", fn {k, v} -> "#{k}: #{render_value(v, k)}\n" end)
  end

  def render(inputs, fields) when is_map(inputs) and is_list(fields) do
    Enum.map_join(fields, "", fn field ->
      value = Map.get(inputs, field)
      "#{field}: #{render_value(value, field)}\n"
    end)
  end

  defp render_value(nil, _key), do: "nil"
  defp render_value(v, _key) when is_binary(v), do: v
  defp render_value(v, _key) when is_atom(v), do: Atom.to_string(v)
  defp render_value(v, _key) when is_number(v), do: to_string(v)

  defp render_value(v, key) when is_list(v) or is_map(v) do
    case Jason.encode(v) do
      {:ok, json} ->
        json

      {:error, _} ->
        raise %Errors.Invalid.Configuration{
          key: :embed_inputs,
          value: %{field: key, type: inspect(Map.get(v, :__struct__, :unknown))},
          reason: :unembeddable_input
        }
    end
  end

  defp render_value(v, key) do
    raise %Errors.Invalid.Configuration{
      key: :embed_inputs,
      value: %{field: key, type: inspect(v)},
      reason: :unembeddable_input
    }
  end
end
