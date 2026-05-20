defmodule Dsxir.Metric.ScoreWithFeedbackTest do
  use ExUnit.Case, async: false

  alias Dsxir.Metric
  alias Dsxir.Metric.ScoreWithFeedback

  setup do
    Process.delete(:__dsxir_gepa_feedback__)
    :ok
  end

  defp ex, do: Dsxir.Example.new(%{q: "x", a: "y"}, input_keys: [:q])
  defp pred, do: %Dsxir.Prediction{fields: %{a: "y"}}

  test "scalar score passes through, feedback drained on next call" do
    swf = %ScoreWithFeedback{score: 0.7, feedback: "ok"}
    metric = fn _, _, _ -> swf end

    assert Metric.apply(metric, ex(), pred(), nil) == 0.7
    assert Metric.drain_gepa_feedback() == swf
    assert Metric.drain_gepa_feedback() == nil
  end

  test "map score aggregates via :mean by default" do
    metric = fn _, _, _ ->
      %ScoreWithFeedback{score: %{correctness: 0.8, conciseness: 0.6}, feedback: nil}
    end

    assert_in_delta Metric.apply(metric, ex(), pred(), nil), 0.7, 1.0e-9
  end

  test ":min and :max aggregators" do
    Application.put_env(:dsxir, :objective_aggregator, :min)

    metric = fn _, _, _ ->
      %ScoreWithFeedback{score: %{a: 0.3, b: 0.9}, feedback: nil}
    end

    assert Metric.apply(metric, ex(), pred(), nil) == 0.3
    Application.put_env(:dsxir, :objective_aggregator, :max)
    assert Metric.apply(metric, ex(), pred(), nil) == 0.9
  after
    Application.delete_env(:dsxir, :objective_aggregator)
  end

  test "{module, fun} aggregator" do
    defmodule WeightedAgg do
      def call(%{a: a, b: b}), do: 0.7 * a + 0.3 * b
    end

    Application.put_env(:dsxir, :objective_aggregator, {WeightedAgg, :call})

    metric = fn _, _, _ ->
      %ScoreWithFeedback{score: %{a: 1.0, b: 0.0}, feedback: nil}
    end

    assert_in_delta Metric.apply(metric, ex(), pred(), nil), 0.7, 1.0e-9
  after
    Application.delete_env(:dsxir, :objective_aggregator)
  end

  test "scalar metrics unchanged" do
    metric = fn _, _, _ -> 0.42 end
    assert Metric.apply(metric, ex(), pred(), nil) == 0.42
    assert Metric.drain_gepa_feedback() == nil
  end

  test "bad aggregator config raises Invalid.Configuration" do
    Application.put_env(:dsxir, :objective_aggregator, :bogus)

    metric = fn _, _, _ -> %ScoreWithFeedback{score: %{a: 1.0}, feedback: nil} end

    assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
      Metric.apply(metric, ex(), pred(), nil)
    end
  after
    Application.delete_env(:dsxir, :objective_aggregator)
  end
end
