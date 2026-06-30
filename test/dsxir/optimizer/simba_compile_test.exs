defmodule Dsxir.Optimizer.SIMBACompileTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.SIMBA
  alias Dsxir.Optimizer.SIMBA.Stats
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Test.TelemetryHandler

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)
    :ok
  end

  @lm {Dsxir.LM.Sycophant, [model: "stub"]}
  @opts [auto: :light, bsize: 2, max_steps: 2, num_candidates: 2, seed: 7, num_threads: 2]

  defp example(i), do: Dsxir.Example.new(%{q: "q#{i}", a: "a#{i}"}, input_keys: [:q])
  defp trainset(n), do: Enum.map(0..(n - 1), &example/1)

  defp stub_predict(fields_fun) do
    Mimic.stub(Dsxir.Predictor.Predict, :forward, fn _state, _signature, inputs, _opts ->
      {%Program.State{}, %Prediction{fields: fields_fun.(inputs)}}
    end)
  end

  defp run_compile(metric, opts \\ @opts) do
    Dsxir.context([lm: @lm], fn ->
      Dsxir.compile(SIMBA, Program.new(QA.Prog), trainset(4), metric, opts)
    end)
  end

  test "Dsxir.compile/5 returns {:ok, compiled, %Stats{}} with steps == max_steps" do
    stub_predict(fn inputs -> %{a: inputs[:q]} end)
    metric = fn ex, _pred, _trace -> if String.ends_with?(ex.data.q, "0"), do: 1.0, else: 0.0 end

    {:ok, compiled, stats} = run_compile(metric)

    assert %Stats{} = stats
    assert stats.steps == 2
    assert compiled.metadata.compiled_with == SIMBA
    assert is_float(stats.best_score)
  end

  test "finalize returns the baseline when only the baseline winner remains (all-skip)" do
    stub_predict(fn inputs -> %{a: inputs[:q]} end)
    metric = fn _ex, _pred, _trace -> 0.5 end

    {:ok, compiled, stats} = run_compile(metric)

    baseline = Program.new(QA.Prog)
    assert compiled.predictors == baseline.predictors
    assert stats.best_program_idx == 0
    assert length(stats.candidate_programs) == 1
  end

  test "emits exactly one start, one stop, and one :simba,:trial per step" do
    stub_predict(fn inputs -> %{a: inputs[:q]} end)
    metric = fn _ex, _pred, _trace -> 0.5 end

    parent = self()
    handler_id = "simba-compile-#{:erlang.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:dsxir, :optimizer, :start],
          [:dsxir, :optimizer, :stop],
          [:dsxir, :optimizer, :simba, :trial]
        ],
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :tel}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _compiled, _stats} = run_compile(metric)

    assert length(drain(:tel, [:dsxir, :optimizer, :start])) == 1
    assert length(drain(:tel, [:dsxir, :optimizer, :stop])) == 1
    assert length(drain(:tel, [:dsxir, :optimizer, :simba, :trial])) == 2
  end

  test "compile!/4 raises on an empty trainset" do
    metric = fn _ex, _pred, _trace -> 0.5 end

    assert_raise Dsxir.Errors.Invalid.Trainset, fn ->
      Dsxir.context([lm: @lm], fn ->
        SIMBA.compile!(Program.new(QA.Prog), [], metric, @opts)
      end)
    end
  end

  defp drain(tag, event, acc \\ []) do
    receive do
      {^tag, ^event, _meas, _meta} -> drain(tag, event, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
