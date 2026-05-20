defmodule Dsxir.TraceTest do
  use ExUnit.Case, async: true

  alias Dsxir.Trace
  alias Dsxir.Trace.Entry

  defp pred, do: %Dsxir.Prediction{fields: %{a: "x"}}

  test "record/1 is a no-op when no collector is open" do
    refute Trace.active?()
    assert :ok = Trace.record({:p, %{}, pred(), []})
    refute Trace.active?()
  end

  test "start/0 + stop/1 yields entries in push order" do
    prior = Trace.start()
    assert Trace.active?()

    :ok = Trace.record({:a, %{}, pred(), []})
    :ok = Trace.record({:b, %{}, pred(), []})

    assert [%Entry{predictor: :a}, %Entry{predictor: :b}] = Trace.stop(prior)
    refute Trace.active?()
  end

  test "stop/1 restores a nested prior collector" do
    outer = Trace.start()
    :ok = Trace.record({:outer, %{}, pred(), []})

    inner = Trace.start()
    :ok = Trace.record({:inner, %{}, pred(), []})
    assert [%Entry{predictor: :inner}] = Trace.stop(inner)

    :ok = Trace.record({:outer_again, %{}, pred(), []})

    assert [%Entry{predictor: :outer}, %Entry{predictor: :outer_again}] =
             Trace.stop(outer)

    refute Trace.active?()
  end

  test "stop/1 clears the slot when there was no prior collector" do
    prior = Trace.start()
    assert prior == nil
    :ok = Trace.record({:x, %{}, pred(), []})
    _ = Trace.stop(prior)
    assert Process.get({Dsxir.Trace, :collector}) == nil
  end

  test "legacy tuple input is auto-wrapped with degraded: false" do
    prior = Trace.start()
    :ok = Trace.record({:legacy, %{}, pred(), []})

    assert [%Entry{predictor: :legacy, degraded: false}] = Trace.stop(prior)
  end
end
