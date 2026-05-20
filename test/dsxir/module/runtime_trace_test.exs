defmodule Dsxir.Module.RuntimeTraceTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Trace

  setup :set_mimic_global

  setup do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\nstubbed", Dsxir.LM.empty_usage()}
    end)

    :ok
  end

  test "no with_trace: collector stays nil after a forward call" do
    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {_p, _pred} = QA.Prog.forward(Program.new(QA.Prog), %{q: "x"})
    end)

    refute Trace.active?()
  end

  test "with an active Trace collector: one entry per inner predictor call" do
    prior = Trace.start()

    try do
      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        QA.Prog.forward(Program.new(QA.Prog), %{q: "x"})
      end)

      assert [
               %Dsxir.Trace.Entry{
                 predictor: :answer,
                 inputs: %{q: "x"},
                 prediction: %Dsxir.Prediction{},
                 demos: [],
                 degraded: false
               }
             ] = Trace.stop(prior)
    rescue
      e ->
        _ = Trace.stop(prior)
        reraise e, __STACKTRACE__
    end
  end
end
