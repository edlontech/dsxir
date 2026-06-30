defmodule Dsxir.Optimizer.SIMBA.EvaluatorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.SIMBA.Evaluator
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  defp ex(q), do: Dsxir.Example.new(%{q: q, a: "x"}, input_keys: [:q])

  defp stub_ok do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)
  end

  defp pairs(qs) do
    prog = Program.new(QA.Prog)
    Enum.map(qs, fn q -> {prog, ex(q)} end)
  end

  test "one record per pair, order-aligned with input" do
    stub_ok()
    metric = fn _ex, _pred, _trace -> 1.0 end

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      records = Evaluator.run(pairs(["a", "b", "c"]), metric, num_threads: 2)

      assert length(records) == 3
      assert Enum.map(records, & &1.example.data.q) == ["a", "b", "c"]
      assert Enum.all?(records, &(&1.score == 1.0))
    end)
  end

  test "captures a non-empty trace for a successful run" do
    stub_ok()
    metric = fn _ex, _pred, _trace -> 1.0 end

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      [record] = Evaluator.run(pairs(["a"]), metric, [])

      assert %Dsxir.Prediction{} = record.prediction
      assert [%Dsxir.Trace.Entry{predictor: :answer}] = record.trace
    end)
  end

  test "a recognized forward error yields score 0.0 with empty trace" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      raise %Dsxir.Errors.LM.RateLimited{model_id: "stub", retry_after: nil}
    end)

    metric = fn _ex, _pred, _trace -> 1.0 end

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      [record] = Evaluator.run(pairs(["a"]), metric, [])

      assert record.score == 0.0
      assert record.trace == []
      assert record.prediction == nil
      assert record.metadata == nil
    end)
  end

  test "sampling: true injects a distinct _dsxir_nonce per pair" do
    test_pid = self()

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn config, _messages, _opts ->
      send(test_pid, {:lm_config, config})
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    metric = fn _ex, _pred, _trace -> 1.0 end

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      Evaluator.run(pairs(["a", "b"]), metric, sampling: true, num_threads: 1)
    end)

    nonces =
      for _ <- 1..2 do
        assert_receive {:lm_config, config}
        assert config[:cache] == false
        assert config[:temperature] == 1.0
        config[:_dsxir_nonce]
      end

    assert Enum.all?(nonces, &(&1 != nil))
    assert Enum.uniq(nonces) == nonces
  end
end
