defmodule Dsxir.MetricTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Invalid.Metric, as: MetricErr

  defp ex, do: Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
  defp pred, do: %Dsxir.Prediction{fields: %{a: "y"}}

  test "true coerces to 1.0" do
    metric = fn _e, _p, _t -> true end
    assert Dsxir.Metric.apply(metric, ex(), pred(), nil) == 1.0
  end

  test "false coerces to 0.0" do
    metric = fn _e, _p, _t -> false end
    assert Dsxir.Metric.apply(metric, ex(), pred(), nil) == 0.0
  end

  test "integer coerces to float" do
    metric = fn _e, _p, _t -> 1 end
    assert Dsxir.Metric.apply(metric, ex(), pred(), nil) === 1.0
  end

  test "float passes through" do
    metric = fn _e, _p, _t -> 0.42 end
    assert Dsxir.Metric.apply(metric, ex(), pred(), nil) === 0.42
  end

  test "garbage return raises Invalid.Metric with the offending value" do
    metric = fn _e, _p, _t -> :ok end

    assert_raise MetricErr, fn ->
      Dsxir.Metric.apply(metric, ex(), pred(), nil)
    end
  end

  test "trace is forwarded as positional argument and may be a list" do
    metric = fn _e, _p, trace -> if is_list(trace), do: 1.0, else: 0.0 end
    assert Dsxir.Metric.apply(metric, ex(), pred(), [{:p, %{}, %{}, []}]) == 1.0
    assert Dsxir.Metric.apply(metric, ex(), pred(), nil) == 0.0
  end
end
