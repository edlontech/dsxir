defmodule Dsxir.Optimizer.GEPA.SamplerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Population
  alias Dsxir.Optimizer.GEPA.Sampler

  defp sample_sampler do
    delta = %Delta{
      instructions: %{a: "x"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }

    seed = Individual.new(delta, [0.5], [nil], [], :seed, 0)

    %Sampler{
      population: Population.new(seed),
      frontier: [seed.id],
      devset: [],
      seed_program: %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}},
      decls: [],
      demo_table: %{},
      reflective_lm: {Dsxir.LM.Sycophant, []},
      proposer_calls: 0,
      total_devset_evals: 1,
      attempts: 0,
      generation: 0,
      rng_seed: 0,
      rng_state: :rand.seed_s(:exsplus, {1, 2, 3}),
      best_so_far: {seed.id, 0.5},
      degraded: false,
      config: %{num_trials: 1},
      total_planned_trials: 1
    }
  end

  test "serialize/deserialize round-trips" do
    s = sample_sampler()
    {:ok, blob, 1} = Sampler.serialize(s)
    assert {:ok, s2} = Sampler.deserialize(blob, 1)
    assert s2.attempts == s.attempts
    assert s2.best_so_far == s.best_so_far
  end

  test "version_mismatch for unknown version" do
    s = sample_sampler()
    {:ok, blob, 1} = Sampler.serialize(s)
    assert Sampler.deserialize(blob, 2) == {:error, :version_mismatch}
  end

  test "bad_sampler_shape for non-Sampler blob" do
    blob = :erlang.term_to_binary({:not, :a, :sampler})
    assert {:error, {:bad_sampler_shape, _}} = Sampler.deserialize(blob, 1)
  end

  test "corrupt_blob for random non-term-encoded bytes" do
    assert {:error, :corrupt_blob} = Sampler.deserialize(<<0, 1, 2, 3>>, 1)
  end

  test "build_stats reads canonical fields" do
    s = sample_sampler()
    stats = Sampler.build_stats(s)
    assert stats.best_score == 0.5
    assert stats.population_size == 1
    assert stats.frontier_size == 1
  end
end
