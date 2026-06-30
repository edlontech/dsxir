defmodule Dsxir.Optimizer.SIMBATest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.SIMBA
  alias Dsxir.Optimizer.SIMBA.Stats
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Program.State
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)
    :ok
  end

  @lm {Dsxir.LM.Sycophant, [model: "stub"]}
  @opts [auto: :light, bsize: 3, max_steps: 2, num_candidates: 2, seed: 1, num_threads: 2]

  # q0,q2,q4 score for the seed; q1,q3,q5 do not. A mutated program (one that
  # carries demos or an instruction override) answers every example correctly.
  defp trainset do
    for i <- 0..5, do: Dsxir.Example.new(%{q: "q#{i}", a: "good"}, input_keys: [:q])
  end

  defp metric do
    fn _ex, %Prediction{fields: fields}, _trace ->
      if Map.get(fields, :a) == "good", do: 1.0, else: 0.0
    end
  end

  defp guidance?(%State{demos: demos, instructions_override: override}) do
    demos != [] or not is_nil(override)
  end

  defp stub_lms do
    Mimic.stub(Dsxir.Predictor.Predict, :forward, fn %State{} = state, _sig, inputs, _opts ->
      fields =
        cond do
          Map.has_key?(inputs, :module_names) ->
            %{
              discussion: "compare",
              advice: [
                %{"module" => "answer", "advice" => "Answer like the better trajectory."},
                %{"module" => "extract", "advice" => "Classify the question precisely."}
              ]
            }

          Map.has_key?(inputs, :category) ->
            %{a: answer_for(state, inputs)}

          true ->
            %{category: "general", reasoning: "step by step"}
        end

      {state, %Prediction{fields: fields}}
    end)
  end

  defp answer_for(state, %{q: q}) do
    cond do
      guidance?(state) -> "good"
      even_q?(q) -> "good"
      true -> "bad"
    end
  end

  defp even_q?(q) do
    q |> String.trim_leading("q") |> String.to_integer() |> rem(2) == 0
  end

  defp seed_baseline(seed, ts, metric) do
    Dsxir.context([lm: @lm], fn ->
      ts
      |> Enum.map(fn ex ->
        {_p, pred} = Program.forward(seed, Dsxir.Example.inputs(ex))
        metric.(ex, pred, nil)
      end)
      |> mean()
    end)
  end

  defp mean(xs), do: Enum.sum(xs) / length(xs)

  defp run(metric, opts \\ @opts) do
    Dsxir.context([lm: @lm], fn ->
      Dsxir.compile(SIMBA, Program.new(QA.TwoStep), trainset(), metric, opts)
    end)
  end

  test "compiles a two-predictor program above baseline and mutates a predictor" do
    stub_lms()
    metric = metric()
    seed = Program.new(QA.TwoStep)
    baseline = seed_baseline(seed, trainset(), metric)

    {:ok, compiled, stats} = run(metric)

    assert %Program{} = compiled
    assert %Stats{} = stats
    assert stats.steps == Keyword.fetch!(@opts, :max_steps)
    assert is_float(stats.best_score)
    assert stats.best_score >= baseline
    assert compiled.metadata.compiled_with == SIMBA

    mutated? = compiled.predictors |> Map.values() |> Enum.any?(&guidance?/1)
    assert mutated?, "expected at least one compiled predictor to carry demos or an override"
  end

  test "is deterministic: same seed yields the same best_score" do
    stub_lms()
    metric = metric()

    {:ok, _c1, stats1} = run(metric)
    {:ok, _c2, stats2} = run(metric)

    assert stats1.best_score == stats2.best_score
  end
end
