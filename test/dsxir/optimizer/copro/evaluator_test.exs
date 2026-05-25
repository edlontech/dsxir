defmodule Dsxir.Optimizer.COPRO.EvaluatorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.COPRO.Evaluator

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defmodule Sig do
    use Dsxir.Signature

    signature do
      input(:q, :string)
      output(:a, :string)
    end
  end

  defmodule TwoPredictorProg do
    use Dsxir.Module

    predictor(:first, Dsxir.Predictor.Predict, signature: Sig)
    predictor(:second, Dsxir.Predictor.Predict, signature: Sig)

    def forward(p, inputs), do: call(p, :first, inputs)
  end

  defp ex(q, a), do: Dsxir.Example.new(%{q: q, a: a}, input_keys: [:q])

  defp metric(_e, %Dsxir.Prediction{fields: %{a: actual}}, _t) do
    if actual == "correct", do: 1.0, else: 0.0
  end

  describe "run/4" do
    test "returns mean score and empty errors on fully passing run" do
      Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
        {:ok, "[[ ## a ## ]]\ncorrect", Dsxir.LM.empty_usage()}
      end)

      evalset = Enum.map(1..4, &ex("q#{&1}", "correct"))
      program = Dsxir.Program.new(TwoPredictorProg)

      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        assert {:ok, score, errors} = Evaluator.run(program, evalset, &metric/3, %{})
        assert score == 100.0
        assert errors.count == 0
      end)
    end

    test "partial score is the mean of metric values times 100" do
      call_count = :counters.new(1, [])

      Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)
        answer = if rem(n, 2) == 0, do: "correct", else: "wrong"
        {:ok, "[[ ## a ## ]]\n#{answer}", Dsxir.LM.empty_usage()}
      end)

      evalset = Enum.map(1..4, &ex("q#{&1}", "correct"))
      program = Dsxir.Program.new(TwoPredictorProg)

      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        assert {:ok, score, errors} = Evaluator.run(program, evalset, &metric/3, %{})
        assert score == 50.0
        assert errors.count == 0
      end)
    end

    test "all-failing run yields score 0.0 and errors.count == length(evalset)" do
      Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
        {:ok, "no markers at all", Dsxir.LM.empty_usage()}
      end)

      evalset = Enum.map(1..3, &ex("q#{&1}", "correct"))
      program = Dsxir.Program.new(TwoPredictorProg)

      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        assert {:ok, score, errors} = Evaluator.run(program, evalset, &metric/3, %{})
        assert score == 0.0
        assert errors.count == length(evalset)
      end)
    end

    test "_cfg argument is accepted and ignored" do
      Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _c, _msgs, _opts ->
        {:ok, "[[ ## a ## ]]\ncorrect", Dsxir.LM.empty_usage()}
      end)

      evalset = [ex("q1", "correct")]
      program = Dsxir.Program.new(TwoPredictorProg)

      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        assert {:ok, _score, _errors} =
                 Evaluator.run(program, evalset, &metric/3, %{some: "config"})
      end)
    end
  end
end
