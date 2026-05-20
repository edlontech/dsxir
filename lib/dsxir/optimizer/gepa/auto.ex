defmodule Dsxir.Optimizer.GEPA.Auto do
  @moduledoc """
  Preset → resolved config for GEPA. Mirrors `Dsxir.Optimizer.MIPROv2.Auto`.
  User-supplied opts override the preset.
  """

  @presets %{
    light: %{
      num_trials: 20,
      operator_weights: %{mutate_instr: 0.7, mutate_demos: 0.2, crossover: 0.1},
      rollout_k_success: 3,
      rollout_k_fail: 3,
      num_demo_bundles: 4,
      devset_fraction: 0.3,
      seed: 0
    },
    medium: %{
      num_trials: 60,
      operator_weights: %{mutate_instr: 0.6, mutate_demos: 0.2, crossover: 0.2},
      rollout_k_success: 4,
      rollout_k_fail: 4,
      num_demo_bundles: 6,
      devset_fraction: 0.3,
      seed: 0
    },
    heavy: %{
      num_trials: 150,
      operator_weights: %{mutate_instr: 0.5, mutate_demos: 0.2, crossover: 0.3},
      rollout_k_success: 6,
      rollout_k_fail: 6,
      num_demo_bundles: 10,
      devset_fraction: 0.3,
      seed: 0
    }
  }

  @doc """
  Resolves `preset` to a config map and merges user-supplied `opts` on top.
  `:auto` and `:reflective_lm` are stripped before merging.
  """
  @spec expand(keyword(), :light | :medium | :heavy) :: map()
  def expand(opts, preset) when preset in [:light, :medium, :heavy] and is_list(opts) do
    base = Map.fetch!(@presets, preset)

    user =
      opts
      |> Keyword.drop([:auto, :reflective_lm])
      |> Map.new()

    Map.merge(base, user)
  end
end
