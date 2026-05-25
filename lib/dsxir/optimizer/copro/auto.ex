defmodule Dsxir.Optimizer.COPRO.Auto do
  @moduledoc """
  Budget presets for `Dsxir.Optimizer.COPRO`. `expand/2` overlays user options
  on the chosen preset; user keys win. Mirrors `Dsxir.Optimizer.MIPROv2.Auto`.
  """

  @presets %{
    light: %{breadth: 4, depth: 2, init_temperature: 1.0},
    medium: %{breadth: 6, depth: 3, init_temperature: 1.2},
    heavy: %{breadth: 10, depth: 4, init_temperature: 1.4}
  }

  @type preset :: :light | :medium | :heavy

  @doc "Returns the preset map for an auto level. Raises on unknown preset."
  @spec preset(preset()) :: map()
  def preset(level) when level in [:light, :medium, :heavy], do: Map.fetch!(@presets, level)

  @doc """
  Merge user opts over the chosen preset. User-supplied keys override preset
  values; preset values fill in only when the user didn't set the key.
  """
  @spec expand(keyword(), preset()) :: map()
  def expand(opts, level) when is_list(opts) and level in [:light, :medium, :heavy] do
    level
    |> preset()
    |> Map.merge(Map.new(Keyword.take(opts, [:breadth, :depth, :init_temperature])))
  end
end
