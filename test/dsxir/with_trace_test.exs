defmodule Dsxir.WithTraceTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  test "returns {program, prediction, trace} for a vanilla forward" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## a ## ]]\nok", Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {prog, pred, trace} =
        Dsxir.with_trace(fn ->
          QA.Prog.forward(Program.new(QA.Prog), %{q: "x"})
        end)

      assert %Program{} = prog
      assert %Dsxir.Prediction{} = pred
      assert [{:answer, %{q: "x"}, ^pred, []}] = trace
    end)
  end

  test "raises pass through and clear the accumulator" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "no markers", Dsxir.LM.empty_usage()}
    end)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_object, fn _, _, _, _ ->
      {:ok, %{}, Dsxir.LM.empty_usage()}
    end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.Adapter.FallbackExhausted, fn ->
        Dsxir.with_trace(fn ->
          QA.Prog.forward(Program.new(QA.Prog), %{q: "x"})
        end)
      end
    end)

    refute Dsxir.Trace.active?()
  end

  test "throws clear the accumulator" do
    prior_active = Dsxir.Trace.active?()

    assert catch_throw(
             Dsxir.with_trace(fn ->
               throw(:boom)
             end)
           ) == :boom

    assert Dsxir.Trace.active?() == prior_active
  end

  test "exits clear the accumulator" do
    prior_active = Dsxir.Trace.active?()

    assert catch_exit(
             Dsxir.with_trace(fn ->
               exit(:boom)
             end)
           ) == :boom

    assert Dsxir.Trace.active?() == prior_active
  end
end
