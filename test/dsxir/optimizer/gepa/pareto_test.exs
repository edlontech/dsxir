defmodule Dsxir.Optimizer.GEPA.ParetoTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Pareto
  alias Dsxir.Optimizer.GEPA.Population

  defp delta(suffix) do
    %Delta{
      instructions: %{a: "x_#{suffix}"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }
  end

  defp ind(suffix, scores) do
    Individual.new(
      delta(suffix),
      scores,
      Enum.map(scores, fn _ -> nil end),
      [],
      :seed,
      suffix
    )
  end

  describe "dominates?/2" do
    test "true when strictly better on at least one and >= on all" do
      a = ind(0, [0.9, 0.5])
      b = ind(1, [0.8, 0.5])
      assert Pareto.dominates?(a, b)
      refute Pareto.dominates?(b, a)
    end

    test "false when equal" do
      a = ind(0, [0.5, 0.5])
      b = ind(1, [0.5, 0.5])
      refute Pareto.dominates?(a, b)
      refute Pareto.dominates?(b, a)
    end

    test "nil acts as -infinity" do
      a = ind(0, [0.5, nil])
      b = ind(1, [0.5, 0.0])
      refute Pareto.dominates?(a, b)
      assert Pareto.dominates?(b, a)
    end

    test "antisymmetric on identical scores" do
      a = ind(0, [0.5, 0.5])
      b = ind(1, [0.5, 0.5])
      refute Pareto.dominates?(a, b) and Pareto.dominates?(b, a)
    end

    test "transitive" do
      a = ind(0, [0.9, 0.9])
      b = ind(1, [0.8, 0.8])
      c = ind(2, [0.7, 0.7])
      assert Pareto.dominates?(a, b)
      assert Pareto.dominates?(b, c)
      assert Pareto.dominates?(a, c)
    end
  end

  describe "frontier/1" do
    test "single individual is its own frontier" do
      pop = Population.new(ind(0, [0.5, 0.5]))
      assert Pareto.frontier(pop) == [Population.to_list(pop) |> List.first() |> Map.fetch!(:id)]
    end

    test "per-example winners: each best-on-some-example individual makes it" do
      i0 = ind(0, [1.0, 0.0])
      i1 = ind(1, [0.0, 1.0])
      i2 = ind(2, [0.5, 0.5])
      pop = Population.new(i0) |> Population.add(i1) |> Population.add(i2)
      frontier = Pareto.frontier(pop)
      assert i0.id in frontier
      assert i1.id in frontier
      refute i2.id in frontier
    end

    test "ties broken by birth order — older wins" do
      i0 = ind(0, [0.5])
      i1 = ind(1, [0.5])
      pop = Population.new(i0) |> Population.add(i1)
      assert Pareto.frontier(pop) == [i0.id]
    end
  end

  describe "would_join_frontier?/2" do
    test "true when candidate is unique-best on some example" do
      seed = ind(0, [0.5, 0.5])
      pop = Population.new(seed)
      child = ind(1, [0.6, 0.5])
      assert Pareto.would_join_frontier?(pop, child)
    end

    test "false when candidate is strictly dominated" do
      seed = ind(0, [0.9, 0.9])
      pop = Population.new(seed)
      child = ind(1, [0.8, 0.8])
      refute Pareto.would_join_frontier?(pop, child)
    end
  end

  describe "select_parent/3" do
    test "uniform fallback when all coverage weights are zero" do
      i0 = ind(0, [nil, nil, nil])
      i1 = ind(1, [nil, nil, nil])
      i2 = ind(2, [nil, nil, nil])
      pop = Population.new(i0) |> Population.add(i1) |> Population.add(i2)
      frontier = [i0.id, i1.id, i2.id]

      picks =
        Enum.map_reduce(1..3000, :rand.seed_s(:exsplus, {1, 2, 3}), fn _, rng ->
          {ind, rng2} = Pareto.select_parent(pop, frontier, rng)
          {ind.id, rng2}
        end)
        |> elem(0)

      i0_count = Enum.count(picks, &(&1 == i0.id))
      i1_count = Enum.count(picks, &(&1 == i1.id))
      i2_count = Enum.count(picks, &(&1 == i2.id))
      assert_in_delta i0_count, 1000, 200
      assert_in_delta i1_count, 1000, 200
      assert_in_delta i2_count, 1000, 200
    end

    test "weighted by coverage, deterministic with seeded rng" do
      i0 = ind(0, [1.0, 0.0, 0.0])
      i1 = ind(1, [0.0, 1.0, 1.0])
      pop = Population.new(i0) |> Population.add(i1)
      frontier = Pareto.frontier(pop)
      rng = :rand.seed_s(:exsplus, {1, 2, 3})

      picks =
        Stream.iterate(rng, fn s ->
          {_ind, s2} = Pareto.select_parent(pop, frontier, s)
          s2
        end)
        |> Enum.take(1000)
        |> Enum.map(fn s ->
          {ind, _} = Pareto.select_parent(pop, frontier, s)
          ind.id
        end)

      i0_count = Enum.count(picks, &(&1 == i0.id))
      i1_count = Enum.count(picks, &(&1 == i1.id))
      assert i1_count > i0_count
    end
  end
end
