defmodule Dsxir.Optimizer.GEPA.TrialTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Evaluator
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators
  alias Dsxir.Optimizer.GEPA.Population
  alias Dsxir.Optimizer.GEPA.Sampler
  alias Dsxir.Optimizer.GEPA.Trial

  setup :set_mimic_global

  defmodule IdentityOp do
    @behaviour Dsxir.Optimizer.GEPA.Operators
    def kind, do: :mutate_instr
    def parent_count, do: 1
    def apply(parent, _ctx), do: {:ok, parent.delta, 0}
  end

  defp delta(suffix) do
    %Delta{
      instructions: %{a: "x_#{suffix}"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }
  end

  defp ind(suffix, scores) do
    Individual.new(delta(suffix), scores, Enum.map(scores, fn _ -> nil end), [], :seed, suffix)
  end

  defp sampler_with(seed, overrides \\ %{}) do
    pop = Population.new(seed)

    base = %Sampler{
      population: pop,
      frontier: [seed.id],
      devset: [],
      seed_program: %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}},
      decls: [],
      demo_table: %{},
      reflective_lm: {Dsxir.LM.Sycophant, []},
      proposer_calls: 0,
      total_devset_evals: 0,
      attempts: 0,
      generation: 0,
      rng_seed: 0,
      rng_state: :rand.seed_s(:exsplus, {1, 2, 3}),
      best_so_far: nil,
      degraded: false,
      config: %{
        num_trials: 1,
        operator_weights: %{mutate_instr: 1.0, mutate_demos: 0.0, crossover: 0.0},
        rollout_k_success: 1,
        rollout_k_fail: 1
      },
      total_planned_trials: 1
    }

    Map.merge(base, overrides)
  end

  defp stub_operators_to(op_mod, parent) do
    Mimic.copy(Operators)
    Mimic.stub(Operators, :sample, fn _f, _p, _w, rng -> {op_mod, parent, rng} end)
  end

  describe "update_best/2 (via on_success)" do
    test "nil best_so_far with nil-aggregated child stays nil" do
      seed = ind(0, [nil])
      s = sampler_with(seed)
      stub_operators_to(IdentityOp, seed)

      assert {:ok, s2, trial} = Trial.run(%{sampler: s, trial_idx: 0, metric: nil})
      assert trial.status == :ok
      assert s2.best_so_far == nil
    end

    test "nil best_so_far with scored child replaces with child" do
      seed = ind(0, [0.5])
      s = sampler_with(seed, %{devset: [example()]})
      stub_operators_to(IdentityOp, seed)

      Mimic.copy(Evaluator)
      Mimic.stub(Evaluator, :run_or_nils, fn _, _, _ -> {[0.7], [nil]} end)

      assert {:ok, s2, _trial} = Trial.run(%{sampler: s, trial_idx: 0, metric: nil})
      assert {_id, 0.7} = s2.best_so_far
    end

    test "non-nil best_so_far retained when child aggregated is nil" do
      seed = ind(0, [0.7])
      best = {seed.id, 0.7}
      s = sampler_with(seed, %{best_so_far: best})
      stub_operators_to(IdentityOp, seed)

      assert {:ok, s2, _trial} = Trial.run(%{sampler: s, trial_idx: 0, metric: nil})
      assert s2.best_so_far == best
    end

    test "non-nil best_so_far retained when child scores lower" do
      seed = ind(0, [0.9])
      best = {seed.id, 0.9}
      s = sampler_with(seed, %{devset: [example()], best_so_far: best})
      stub_operators_to(IdentityOp, seed)

      Mimic.copy(Evaluator)
      Mimic.stub(Evaluator, :run_or_nils, fn _, _, _ -> {[0.1], [nil]} end)

      assert {:ok, s2, _trial} = Trial.run(%{sampler: s, trial_idx: 0, metric: nil})
      assert s2.best_so_far == best
    end

    test "non-nil best_so_far replaced when child scores higher" do
      seed = ind(0, [0.5])
      best = {seed.id, 0.5}
      s = sampler_with(seed, %{devset: [example()], best_so_far: best})
      stub_operators_to(IdentityOp, seed)

      Mimic.copy(Evaluator)
      Mimic.stub(Evaluator, :run_or_nils, fn _, _, _ -> {[0.9], [nil]} end)

      assert {:ok, s2, _trial} = Trial.run(%{sampler: s, trial_idx: 0, metric: nil})
      assert {_id, 0.9} = s2.best_so_far
      refute s2.best_so_far == best
    end
  end

  describe "rescue path" do
    test "recognised exception surfaces as :error trial; sampler.degraded=true" do
      seed = ind(0, [0.5])
      s = sampler_with(seed)

      Mimic.copy(Operators)

      Mimic.stub(Operators, :sample, fn _f, _p, _w, _rng ->
        raise %Dsxir.Errors.LM.RateLimited{model_id: "stub", retry_after: 0}
      end)

      assert {:ok, s2, trial} = Trial.run(%{sampler: s, trial_idx: 0, metric: nil})
      assert trial.status == :error
      assert %Dsxir.Errors.LM.RateLimited{} = trial.error
      assert trial.error_class == :lm
      assert s2.degraded == true
      assert s2.attempts == s.attempts + 1
    end
  end

  defp example do
    %Dsxir.Example{data: %{text: "t", summary: "s"}, input_keys: MapSet.new([:text])}
  end
end
