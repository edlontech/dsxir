defmodule Dsxir.Optimizer.MIPROv2.Auto do
  @moduledoc """
  Pure-data preset table for MIPROv2's `auto: :light | :medium | :heavy` knob.

  Each preset is a fixed map of `num_trials`, `num_instruction_candidates`,
  `num_demo_sets`, and `minibatch_size`. `expand/2` merges a preset into a user
  opts list while keeping user-supplied values intact.
  """

  @presets %{
    light: %{
      num_trials: 6,
      num_instruction_candidates: 3,
      num_demo_sets: 2,
      minibatch_size: 25
    },
    medium: %{
      num_trials: 18,
      num_instruction_candidates: 5,
      num_demo_sets: 4,
      minibatch_size: 25
    },
    heavy: %{
      num_trials: 42,
      num_instruction_candidates: 10,
      num_demo_sets: 6,
      minibatch_size: 50
    }
  }

  @type preset :: :light | :medium | :heavy

  @doc "Returns the preset map for an auto level. Raises on unknown preset."
  @spec preset(preset()) :: %{
          num_trials: pos_integer(),
          num_instruction_candidates: pos_integer(),
          num_demo_sets: pos_integer(),
          minibatch_size: pos_integer()
        }
  def preset(level) when level in [:light, :medium, :heavy], do: Map.fetch!(@presets, level)

  @doc """
  Merge an auto preset into an opts keyword list. User-supplied keys override
  preset values; preset values fill in only when the user didn't set the key.
  """
  @spec expand(keyword(), preset()) :: keyword()
  def expand(opts, level) when is_list(opts) and level in [:light, :medium, :heavy] do
    preset_map = preset(level)
    Enum.reduce(preset_map, opts, fn {k, v}, acc -> Keyword.put_new(acc, k, v) end)
  end
end
