defmodule Dsxir.Optimizer.SIMBA.Strategy.AppendRuleTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Errors
  alias Dsxir.Example
  alias Dsxir.Optimizer.SIMBA.Strategy.AppendRule
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Signature.Runtime
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Trace.Entry

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)
    :ok
  end

  defp program, do: Program.new(QA.TwoStep)

  defp base_instruction(program, name) do
    case Runtime.instruction(Program.Source.signature_for(program.source, name)) do
      nil -> ""
      instruction -> instruction
    end
  end

  defp expected_override(base, advice) do
    if base == "", do: advice, else: base <> "\n\n" <> advice
  end

  defp example, do: Example.new(%{q: "hi", a: "ans"}, input_keys: [:q])

  defp entry(predictor, inputs, output) do
    %Entry{predictor: predictor, inputs: inputs, prediction: Prediction.new(output), demos: []}
  end

  defp record(score, trace) do
    %{
      score: score,
      trace: trace,
      prediction: Prediction.new(%{a: "x"}),
      example: example(),
      metadata: %{}
    }
  end

  defp bucket(good, bad) do
    %{records: [good, bad], max_to_min_gap: 0.0, max_score: good.score, max_to_avg_gap: 0.0}
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        batch_p10: 0.1,
        batch_p90: 0.9,
        reflective_lm: {Dsxir.LM.Sycophant, []},
        source: nil,
        rng: :rand.seed_s(:exsss, {1, 2, 3}),
        demo_input_field_maxlen: 100_000
      },
      overrides
    )
  end

  defp stub_advice(advice_list) do
    stub(Dsxir.Predictor.Predict, :forward, fn _state, _sig, inputs, _opts ->
      send(self(), {:feedback_inputs, inputs})
      {%Program.State{}, %Prediction{fields: %{discussion: "...", advice: advice_list}}}
    end)
  end

  describe "skip guards" do
    test "skips when good score is at or below batch_p10" do
      good = record(0.1, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.0, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      assert :skip == AppendRule.apply(bucket(good, bad), program(), ctx())
    end

    test "skips when bad score is at or above batch_p90" do
      good = record(1.0, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.9, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      assert :skip == AppendRule.apply(bucket(good, bad), program(), ctx())
    end
  end

  describe "degenerate good <= bad blanking" do
    test "blanks the good trajectory when good score is not above batch_p90" do
      good = record(0.5, [entry(:extract, %{q: "hi"}, %{category: "good"})])
      bad = record(0.5, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      stub_advice([%{"module" => "answer", "advice" => "be terse"}])

      assert {:ok, _} = AppendRule.apply(bucket(good, bad), program(), ctx())

      assert_received {:feedback_inputs, inputs}
      assert inputs.better_program_trajectory == ""
      assert inputs.better_reward_value == "N/A"
      assert inputs.worse_program_trajectory =~ "answer"
      assert inputs.worse_reward_value == 0.5
    end
  end

  describe "happy path" do
    test "appends advice to each named predictor's effective instruction" do
      prog = program()

      good = record(0.8, [entry(:extract, %{q: "hi"}, %{category: "math"})])
      bad = record(0.2, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      stub_advice([
        %{"module" => "extract", "advice" => "name the topic precisely"},
        %{"module" => "answer", "advice" => "answer in one word"}
      ])

      {:ok, updated} = AppendRule.apply(bucket(good, bad), prog, ctx())

      extract_base = base_instruction(prog, :extract)
      answer_base = base_instruction(prog, :answer)

      assert extract_base == "",
             "expected :extract (ChainOfThought) to have no signature instruction, pinning the empty-base path"

      assert Program.get_state(updated, :extract).instructions_override ==
               expected_override(extract_base, "name the topic precisely")

      assert Program.get_state(updated, :answer).instructions_override ==
               expected_override(answer_base, "answer in one word")
    end

    test "appends onto an existing instructions_override rather than the signature instruction" do
      prog = program()
      state = %{Program.get_state(prog, :answer) | instructions_override: "PRIOR RULE"}
      prog = Program.put_state(prog, :answer, state)

      good = record(0.8, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.2, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      stub_advice([%{"module" => "answer", "advice" => "answer in one word"}])

      {:ok, updated} = AppendRule.apply(bucket(good, bad), prog, ctx())

      assert Program.get_state(updated, :answer).instructions_override ==
               "PRIOR RULE" <> "\n\n" <> "answer in one word"
    end

    test "ignores advice for names that are not real predictors" do
      prog = program()
      good = record(0.8, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.2, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      stub_advice([%{"module" => "answer", "advice" => "ok"}, %{"module" => "ghost", "advice" => "x"}])

      {:ok, updated} = AppendRule.apply(bucket(good, bad), prog, ctx())

      assert Program.get_state(updated, :answer).instructions_override =~ "ok"
    end
  end

  describe "failure handling" do
    test "skips when the reflective LM raises a recognized error" do
      stub(Dsxir.Predictor.Predict, :forward, fn _s, _sig, _i, _o ->
        raise %Errors.LM.RateLimited{model_id: "m"}
      end)

      good = record(0.8, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.2, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      assert :skip == AppendRule.apply(bucket(good, bad), program(), ctx())
    end

    test "skips when the advice output is unparseable" do
      stub(Dsxir.Predictor.Predict, :forward, fn _s, _sig, _i, _o ->
        {%Program.State{}, %Prediction{fields: %{discussion: "..."}}}
      end)

      good = record(0.8, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.2, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      assert :skip == AppendRule.apply(bucket(good, bad), program(), ctx())
    end

    test "skips when the advice list is empty" do
      stub_advice([])

      good = record(0.8, [entry(:answer, %{q: "hi"}, %{a: "good"})])
      bad = record(0.2, [entry(:answer, %{q: "hi"}, %{a: "bad"})])

      assert :skip == AppendRule.apply(bucket(good, bad), program(), ctx())
    end
  end
end
