defmodule Dsxir.Optimizer.SIMBA.SessionCallbacksTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer
  alias Dsxir.Optimizer.SIMBA
  alias Dsxir.Optimizer.SIMBA.Sampler
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)
    :ok
  end

  @lm {Dsxir.LM.Sycophant, [model: "stub"]}

  defp stub_predict do
    Mimic.stub(Dsxir.Predictor.Predict, :forward, fn _state, _signature, inputs, _opts ->
      {%Program.State{}, %Prediction{fields: %{a: "ans-#{inputs[:q]}"}}}
    end)
  end

  defp example(i), do: Dsxir.Example.new(%{q: "q#{i}", a: "a#{i}"}, input_keys: [:q])

  defp trainset(n), do: Enum.map(0..(n - 1), &example/1)

  @opts [auto: :light, bsize: 2, max_steps: 2, num_candidates: 2, seed: 7, num_threads: 2]

  defp run_step(sampler, idx, metric) do
    Dsxir.context([lm: @lm], fn ->
      SIMBA.step(sampler, idx, sampler.seed_program, sampler.trainset, metric, @opts)
    end)
  end

  test "checkpointable? recognizes the four session callbacks" do
    assert Optimizer.checkpointable?(SIMBA) == {:ok, SIMBA}
  end

  test "init_session plants the baseline at pool index 0 and shuffles the cursor" do
    ts = trainset(4)
    {:ok, sampler, planned} = SIMBA.init_session(Program.new(QA.Prog), ts, fn _, _, _ -> 1.0 end, @opts)

    assert planned == 2
    assert sampler.total_planned_trials == 2
    assert [%{idx: 0, program: %Program{}}] = sampler.programs
    assert sampler.program_scores == %{0 => []}
    assert sampler.next_idx == 0
    assert [%Program{}] = sampler.winning_programs
    assert sampler.attempts == 0
    assert Enum.sort(sampler.data_indices) == Enum.to_list(0..3)
    assert sampler.data_indices != Enum.to_list(0..3)
  end

  test "init_session rejects an empty trainset" do
    assert {:error, %Dsxir.Errors.Invalid.Trainset{reason: :empty}} =
             SIMBA.init_session(Program.new(QA.Prog), [], fn _, _, _ -> 1.0 end, @opts)
  end

  test "init_session rejects a trainset smaller than bsize" do
    assert {:error, %Dsxir.Errors.Invalid.Trainset{reason: :too_small}} =
             SIMBA.init_session(Program.new(QA.Prog), trainset(1), fn _, _, _ -> 1.0 end, @opts)
  end

  test "step returns {:cont, sampler, trial} and increments attempts" do
    stub_predict()
    metric = fn _ex, _pred, _trace -> 0.5 end
    {:ok, sampler, _} = SIMBA.init_session(Program.new(QA.Prog), trainset(4), metric, @opts)

    {:cont, s2, trial} = run_step(sampler, 0, metric)

    assert %Sampler{} = s2
    assert s2.attempts == 1
    assert trial.trial_idx == 0
    assert trial.status == :ok
  end

  test "step halts with :budget_exhausted once attempts reach the budget" do
    stub_predict()
    metric = fn _ex, _pred, _trace -> 0.5 end
    {:ok, sampler, _} = SIMBA.init_session(Program.new(QA.Prog), trainset(4), metric, @opts)

    exhausted = %{sampler | attempts: sampler.total_planned_trials}

    assert {:halt, ^exhausted, :budget_exhausted} = run_step(exhausted, 2, metric)
  end

  test "serialize_state/deserialize_state round-trip a mid-run sampler" do
    stub_predict()
    metric = fn _ex, _pred, _trace -> 0.5 end
    {:ok, sampler, _} = SIMBA.init_session(Program.new(QA.Prog), trainset(4), metric, @opts)
    {:cont, mid, _trial} = run_step(sampler, 0, metric)

    {:ok, blob, version} = SIMBA.serialize_state(mid)
    assert {:ok, ^mid} = SIMBA.deserialize_state(blob, version)
  end
end
