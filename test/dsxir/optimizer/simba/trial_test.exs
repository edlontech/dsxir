defmodule Dsxir.Optimizer.SIMBA.TrialTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.SIMBA.Sampler
  alias Dsxir.Optimizer.SIMBA.Trial
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Signature.Compiled
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)
    :ok
  end

  @lm {Dsxir.LM.Sycophant, [model: "stub"]}

  defp stub_predict do
    Mimic.stub(Dsxir.Predictor.Predict, :forward, fn _state, signature, inputs, _opts ->
      if match?(%Compiled{source: {:offer_feedback, _}}, signature) do
        {%Program.State{},
         %Prediction{
           fields: %{discussion: "d", advice: [%{"module" => "answer", "advice" => "be terse"}]}
         }}
      else
        {%Program.State{}, %Prediction{fields: %{a: "ans-#{inputs[:q]}"}}}
      end
    end)
  end

  defp example(i, target) do
    Dsxir.Example.new(%{q: "q#{i}", a: "a#{i}", target: target}, input_keys: [:q])
  end

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        bsize: 8,
        num_candidates: 2,
        max_demos: 3,
        temperature_for_sampling: 0.2,
        temperature_for_candidates: 0.2,
        sampling_temperature: 1.0,
        demo_input_field_maxlen: 100_000,
        num_threads: 2,
        reflective_lm: @lm
      },
      overrides
    )
  end

  defp sampler(trainset, overrides \\ %{}) do
    prog = Program.new(QA.Prog)

    base = %Sampler{
      trainset: trainset,
      seed_program: prog,
      programs: [%{idx: 0, program: prog}],
      program_scores: %{0 => []},
      next_idx: 0,
      winning_programs: [prog],
      data_indices: Enum.to_list(0..(length(trainset) - 1)),
      instance_idx: 0,
      trial_logs: %{},
      best_so_far: nil,
      attempts: 0,
      rng_seed: 42,
      rng_state: :rand.seed_s(:exsss, {1, 2, 3}),
      degraded: false,
      config: config(),
      total_planned_trials: 4
    }

    struct(base, overrides)
  end

  defp graded_trainset do
    Enum.map(0..11, fn i -> example(i, i / 10.0) end)
  end

  defp run(sampler) do
    metric = fn ex, _pred, _trace -> ex.data.target end

    Dsxir.context([lm: @lm], fn ->
      Trial.run(%{sampler: sampler, trial_idx: 0, metric: metric})
    end)
  end

  test "consumes bsize examples and advances instance_idx" do
    stub_predict()
    s = sampler(graded_trainset())

    {:ok, updated, _trial} = run(s)

    assert updated.instance_idx == 8
    assert updated.data_indices == Enum.to_list(0..11)
    assert updated.attempts == 1
  end

  test "reshuffles and wraps the cursor when the batch would overrun" do
    stub_predict()
    s = sampler(graded_trainset(), %{instance_idx: 8})

    {:ok, updated, _trial} = run(s)

    assert updated.instance_idx == 8
    assert Enum.sort(updated.data_indices) == Enum.to_list(0..11)
  end

  test "trial_result reports status, best mean, populated stats, and grows the pool" do
    stub_predict()
    s = sampler(graded_trainset())

    {:ok, updated, trial} = run(s)

    assert trial.status == :ok
    assert trial.candidate_id == "step_0"
    assert_in_delta trial.score, 0.35, 1.0e-9
    assert_in_delta trial.stats.baseline, 0.35, 1.0e-9
    assert_in_delta trial.stats.p10, 0.05, 1.0e-9
    assert_in_delta trial.stats.p90, 0.65, 1.0e-9
    assert trial.stats.num_candidates == 3
    assert length(trial.stats.candidate_scores) == 3
    assert %Program{} = trial.candidate_program

    assert length(updated.programs) == 4
    assert length(updated.winning_programs) == 2
    assert map_size(updated.program_scores) == 4
    assert Map.has_key?(updated.trial_logs, 0)
  end

  test "candidate building stops at num_candidates + 1" do
    stub_predict()
    s = sampler(graded_trainset())

    {:ok, updated, trial} = run(s)

    assert trial.stats.num_candidates == s.config.num_candidates + 1
    assert length(updated.programs) == 1 + (s.config.num_candidates + 1)
  end

  test "all strategies skip yields nil score and an unchanged pool" do
    stub_predict()
    flat = Enum.map(0..11, fn i -> example(i, 0.5) end)
    s = sampler(flat)

    {:ok, updated, trial} = run(s)

    assert trial.score == nil
    assert trial.candidate_program == nil
    assert trial.stats.num_candidates == 0
    assert trial.stats.candidate_scores == []
    assert length(updated.programs) == 1
    assert length(updated.winning_programs) == 1
    assert updated.attempts == 1
  end

  test "drop_demos drops at least one position from every predictor when num_demos >= max_demos_tmp" do
    demo = Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])

    prog =
      Enum.reduce([:extract, :answer], Program.new(QA.TwoStep), fn name, p ->
        st = Program.get_state(p, name)
        Program.put_state(p, name, %{st | demos: List.duplicate(demo, 5)})
      end)

    {dropped, _rng} = Trial.drop_demos(prog, config(), :rand.seed_s(:exsss, {7, 8, 9}))

    extract_count = length(Program.get_state(dropped, :extract).demos)
    answer_count = length(Program.get_state(dropped, :answer).demos)

    assert extract_count < 5
    assert extract_count == answer_count
  end

  test "drop_demos leaves a demo-free program untouched" do
    {dropped, _rng} = Trial.drop_demos(Program.new(QA.Prog), config(), :rand.seed_s(:exsss, {1, 2, 3}))

    assert Program.get_state(dropped, :answer).demos == []
  end
end
