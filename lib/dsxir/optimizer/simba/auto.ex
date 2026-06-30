defmodule Dsxir.Optimizer.SIMBA.Auto do
  @moduledoc """
  Budget presets for `Dsxir.Optimizer.SIMBA`. `expand/2` overlays user options
  on the chosen preset; user keys win.
  """

  @presets %{
    light:  %{bsize: 16, num_candidates: 4, max_steps: 4,  max_demos: 3},
    medium: %{bsize: 32, num_candidates: 6, max_steps: 8,  max_demos: 4},
    heavy:  %{bsize: 48, num_candidates: 8, max_steps: 12, max_demos: 6}
  }

  @knobs [
    :bsize,
    :num_candidates,
    :max_steps,
    :max_demos,
    :temperature_for_sampling,
    :temperature_for_candidates,
    :sampling_temperature,
    :demo_input_field_maxlen,
    :num_threads,
    :reflective_lm
  ]

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
    |> Map.merge(Map.new(Keyword.take(opts, @knobs)))
  end
end
