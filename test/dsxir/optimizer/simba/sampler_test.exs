defmodule Dsxir.Optimizer.SIMBA.SamplerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.SIMBA.Sampler

  defp dummy_program(tag), do: %Dsxir.Program{source: tag, predictors: %{}, metadata: %{}}

  defp sampler_with_scores(scores) do
    programs = for {idx, _} <- scores, do: %{idx: idx, program: dummy_program(idx)}
    program_scores = Map.new(scores)

    %Sampler{
      trainset: [],
      seed_program: dummy_program(0),
      programs: programs,
      program_scores: program_scores,
      next_idx: Enum.max(Map.keys(program_scores)),
      winning_programs: [dummy_program(0)],
      data_indices: [],
      instance_idx: 0,
      trial_logs: %{},
      best_so_far: nil,
      attempts: 0,
      rng_seed: 0,
      rng_state: :rand.seed_s(:exsss, {1, 2, 3}),
      degraded: false,
      config: %{num_candidates: 6},
      total_planned_trials: 8
    }
  end

  describe "calc_average_score/2" do
    test "averages the score list and returns 0.0 when empty" do
      s = sampler_with_scores(%{0 => [], 1 => [1.0, 0.0], 2 => [0.5]})
      assert Sampler.calc_average_score(s, 0) == 0.0
      assert Sampler.calc_average_score(s, 1) == 0.5
      assert Sampler.calc_average_score(s, 2) == 0.5
    end
  end

  describe "top_k_plus_baseline/2" do
    test "always includes baseline 0 and dedups, replacing the last element (DSPy quirk)" do
      # avg scores: 3 -> 0.9, 2 -> 0.8, 1 -> 0.7, 0 -> 0.1
      s = sampler_with_scores(%{0 => [0.1], 1 => [0.7], 2 => [0.8], 3 => [0.9]})
      # k = 2 takes [3, 2]; 0 not present, non-empty -> replace last -> [3, 0]
      assert Sampler.top_k_plus_baseline(s, 2) == [3, 0]
    end

    test "keeps baseline when already in top_k" do
      s = sampler_with_scores(%{0 => [0.9], 1 => [0.7], 2 => [0.1]})
      assert Sampler.top_k_plus_baseline(s, 2) == [0, 1]
    end

    test "dedups while preserving order" do
      s = sampler_with_scores(%{0 => [0.5], 1 => [0.4]})
      result = Sampler.top_k_plus_baseline(s, 5)
      assert result == Enum.uniq(result)
      assert 0 in result
    end
  end

  describe "softmax_sample/4" do
    test "is deterministic for a fixed rng_state and returns a valid pool index" do
      s = sampler_with_scores(%{0 => [0.1], 1 => [0.7], 2 => [0.8], 3 => [0.9]})
      idxs = [0, 1, 2, 3]
      rng = :rand.seed_s(:exsss, {7, 7, 7})

      {pick_a, rng_a} = Sampler.softmax_sample(s, idxs, 0.2, rng)
      {pick_b, rng_b} = Sampler.softmax_sample(s, idxs, 0.2, rng)

      assert pick_a == pick_b
      assert rng_a == rng_b
      assert pick_a in idxs
    end

    test "advances rng_state across calls" do
      s = sampler_with_scores(%{0 => [0.1], 1 => [0.9]})
      idxs = [0, 1]
      rng = :rand.seed_s(:exsss, {3, 3, 3})

      {_p1, rng1} = Sampler.softmax_sample(s, idxs, 0.2, rng)
      {_p2, _rng2} = Sampler.softmax_sample(s, idxs, 0.2, rng1)

      assert rng1 != rng
    end
  end

  describe "poisson/2" do
    test "is deterministic given the same rng_state" do
      rng = :rand.seed_s(:exsss, {5, 5, 5})
      assert Sampler.poisson(2.0, rng) == Sampler.poisson(2.0, rng)
    end

    test "lambda 0 always yields 0" do
      rng = :rand.seed_s(:exsss, {9, 9, 9})
      assert {0, _} = Sampler.poisson(0.0, rng)
    end

    test "mean over many draws approximates lambda" do
      lambda = 3.0
      n = 5000

      {sum, _rng} =
        Enum.reduce(1..n, {0, :rand.seed_s(:exsss, {1, 1, 1})}, fn _, {acc, rng} ->
          {k, rng2} = Sampler.poisson(lambda, rng)
          {acc + k, rng2}
        end)

      mean = sum / n
      assert_in_delta mean, lambda, 0.2
    end
  end

  describe "register_new_program/3" do
    test "grows the pool, increments next_idx, and records the score list" do
      s = sampler_with_scores(%{0 => []})
      prog = dummy_program(:new)

      s2 = Sampler.register_new_program(s, prog, [0.4, 0.6])

      assert s2.next_idx == 1
      assert Enum.find(s2.programs, &(&1.idx == 1)).program == prog
      assert s2.program_scores[1] == [0.4, 0.6]
    end
  end

  describe "serialize/deserialize" do
    test "round-trips an identical struct (including rng_state)" do
      s = sampler_with_scores(%{0 => [0.1], 1 => [0.9]})
      s = %{s | best_so_far: {1, 0.9}, attempts: 3}

      {:ok, blob, 1} = Sampler.serialize(s)
      assert {:ok, s2} = Sampler.deserialize(blob, 1)
      assert s2 == s
      assert s2.rng_state == s.rng_state
    end

    test "wrong version -> :version_mismatch" do
      s = sampler_with_scores(%{0 => []})
      {:ok, blob, 1} = Sampler.serialize(s)
      assert Sampler.deserialize(blob, 2) == {:error, :version_mismatch}
    end

    test "non-Sampler blob -> {:bad_sampler_shape, _}" do
      blob = :erlang.term_to_binary({:not, :a, :sampler})
      assert {:error, {:bad_sampler_shape, _}} = Sampler.deserialize(blob, 1)
    end

    test "corrupt bytes -> :corrupt_blob" do
      assert {:error, :corrupt_blob} = Sampler.deserialize(<<0, 1, 2, 3>>, 1)
    end
  end

  describe "build_stats/1" do
    test "projects best_so_far, steps, and candidate count" do
      s = sampler_with_scores(%{0 => [], 1 => [0.9]})
      s = %{s | best_so_far: {1, 0.9}, attempts: 4, next_idx: 1, degraded: true}

      stats = Sampler.build_stats(s)

      assert stats.best_score == 0.9
      assert stats.best_program_idx == 1
      assert stats.steps == 4
      assert stats.num_candidates_total == 1
      assert stats.degraded == true
      assert stats.candidate_programs == []
      assert stats.wall_clock_ms == 0
    end
  end
end
