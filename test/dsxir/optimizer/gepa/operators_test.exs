defmodule Dsxir.Optimizer.GEPA.OperatorsTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators
  alias Dsxir.Optimizer.GEPA.Population

  defp ind(suffix, scores) do
    delta = %Delta{
      instructions: %{a: "x_#{suffix}"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }

    Individual.new(delta, scores, Enum.map(scores, fn _ -> nil end), [], :seed, suffix)
  end

  test "sample/4 uniform fallback over operators when all weights are zero" do
    seed = ind(0, [1.0])
    pop = Population.new(seed)
    frontier = [seed.id]
    weights = %{mutate_instr: 0.0, mutate_demos: 0.0, crossover: 0.0}

    picks =
      Enum.map_reduce(1..3000, :rand.seed_s(:exsplus, {1, 2, 3}), fn _, rng ->
        {op_mod, _parents, rng2} = Operators.sample(frontier, pop, weights, rng)
        {op_mod, rng2}
      end)
      |> elem(0)

    mi = Enum.count(picks, &(&1 == Operators.MutateInstr))
    md = Enum.count(picks, &(&1 == Operators.MutateDemos))
    cx = Enum.count(picks, &(&1 == Operators.Crossover))
    assert_in_delta mi, 1000, 200
    assert_in_delta md, 1000, 200
    assert_in_delta cx, 1000, 200
  end
end
