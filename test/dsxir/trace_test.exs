defmodule Dsxir.TraceTest do
  use ExUnit.Case, async: true

  alias Dsxir.Trace

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

    assert [{:a, _, _, _}, {:b, _, _, _}] = Trace.stop(prior)
    refute Trace.active?()
  end

  test "stop/1 restores a nested prior collector" do
    outer = Trace.start()
    :ok = Trace.record({:outer, %{}, pred(), []})

    inner = Trace.start()
    :ok = Trace.record({:inner, %{}, pred(), []})
    assert [{:inner, _, _, _}] = Trace.stop(inner)

    :ok = Trace.record({:outer_again, %{}, pred(), []})
    assert [{:outer, _, _, _}, {:outer_again, _, _, _}] = Trace.stop(outer)
    refute Trace.active?()
  end

  test "stop/1 clears the slot when there was no prior collector" do
    prior = Trace.start()
    assert prior == nil
    :ok = Trace.record({:x, %{}, pred(), []})
    _ = Trace.stop(prior)
    assert Process.get({Dsxir.Trace, :collector}) == nil
  end
end
