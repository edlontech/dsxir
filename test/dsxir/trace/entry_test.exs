defmodule Dsxir.Trace.EntryTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA
  alias Dsxir.Trace
  alias Dsxir.Trace.Entry

  setup :set_mimic_global

  test "from/1 wraps a legacy 4-tuple with degraded: false" do
    pred = %Prediction{fields: %{a: "x"}}

    assert %Entry{
             predictor: :foo,
             inputs: %{q: "x"},
             prediction: ^pred,
             demos: [],
             degraded: false
           } = Entry.from({:foo, %{q: "x"}, pred, []})
  end

  test "from/1 is identity on a struct" do
    entry = %Entry{
      predictor: :a,
      inputs: %{},
      prediction: %Prediction{},
      demos: [],
      degraded: true
    }

    assert ^entry = Entry.from(entry)
  end

  test "Trace.record/1 accepts struct entries and exposes degraded flag" do
    prior = Trace.start()

    try do
      :ok =
        Trace.record(%Entry{
          predictor: :p,
          inputs: %{},
          prediction: %Prediction{},
          demos: [],
          degraded: true
        })

      assert [%Entry{predictor: :p, degraded: true}] = Trace.stop(prior)
    rescue
      e ->
        _ = Trace.stop(prior)
        reraise e, __STACKTRACE__
    end
  end

  test "Trace.record/1 still accepts legacy tuples (auto-wraps with degraded: false)" do
    prior = Trace.start()

    try do
      :ok = Trace.record({:legacy, %{q: "x"}, %Prediction{}, []})

      assert [%Entry{predictor: :legacy, degraded: false}] = Trace.stop(prior)
    rescue
      e ->
        _ = Trace.stop(prior)
        reraise e, __STACKTRACE__
    end
  end

  test "Module.Runtime.call/4 propagates :degraded opt onto the trace entry" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\nstubbed", Dsxir.LM.empty_usage()}
    end)

    prior = Trace.start()

    try do
      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        Dsxir.Module.Runtime.call(Program.new(QA.Prog), :answer, %{q: "x"}, degraded: true)
      end)

      assert [%Entry{predictor: :answer, degraded: true}] = Trace.stop(prior)
    rescue
      e ->
        _ = Trace.stop(prior)
        reraise e, __STACKTRACE__
    end
  end

  test "Module.Runtime.call/4 defaults degraded to false when opt absent" do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      {:ok, "[[ ## a ## ]]\nstubbed", Dsxir.LM.empty_usage()}
    end)

    prior = Trace.start()

    try do
      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        Dsxir.Module.Runtime.call(Program.new(QA.Prog), :answer, %{q: "x"})
      end)

      assert [%Entry{predictor: :answer, degraded: false}] = Trace.stop(prior)
    rescue
      e ->
        _ = Trace.stop(prior)
        reraise e, __STACKTRACE__
    end
  end
end
