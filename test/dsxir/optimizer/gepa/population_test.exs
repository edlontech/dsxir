defmodule Dsxir.Optimizer.GEPA.PopulationTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Population

  defp ind(id_suffix) do
    delta = %Delta{
      instructions: %{a: "x_#{id_suffix}"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }

    Individual.new(delta, [1.0], [nil], [], :seed, id_suffix)
  end

  test "add preserves birth order; to_list returns oldest first" do
    pop = Population.new(ind(0)) |> Population.add(ind(1)) |> Population.add(ind(2))
    [a, b, c] = Population.to_list(pop)
    assert {a.generation, b.generation, c.generation} == {0, 1, 2}
  end

  test "add of duplicate id is a no-op" do
    seed = ind(0)
    pop = Population.new(seed) |> Population.add(seed)
    assert Population.size(pop) == 1
  end

  test "by_id finds and misses cleanly" do
    seed = ind(0)
    pop = Population.new(seed)
    assert Population.by_id(pop, seed.id) == seed
    assert Population.by_id(pop, "ind_nope") == nil
  end
end
