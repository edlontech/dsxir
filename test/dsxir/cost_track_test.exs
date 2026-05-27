defmodule Dsxir.CostTrackTest do
  use ExUnit.Case, async: false

  alias Dsxir.Cost
  alias Dsxir.Settings
  alias Dsxir.Telemetry

  defp emit_embed(%Cost{} = cost) do
    Telemetry.emit(
      Telemetry.lm_embed_stop(),
      Map.put(Cost.to_measurements(cost), :duration, 1),
      %{
        model: "embed-model",
        cost: cost,
        _cost_scope: Settings.resolve(:_cost_scope, [])
      }
    )
  end

  defp emit_call(%Cost{} = cost) do
    Telemetry.emit(
      Telemetry.predictor_stop(),
      Map.put(Cost.to_measurements(cost), :duration, 1),
      %{
        predictor: Dsxir.Predictor.Predict,
        error_class: nil,
        cost: cost,
        _cost_scope: Settings.resolve(:_cost_scope, [])
      }
    )
  end

  test "sums costs from synchronous calls inside the block" do
    {result, cost} =
      Cost.track(fn ->
        emit_call(%Cost{input_tokens: 10, total_cost: 0.001, calls: 1})
        emit_call(%Cost{input_tokens: 20, total_cost: 0.002, calls: 1})
        :done
      end)

    assert result == :done
    assert %Cost{input_tokens: 30, total_cost: 0.003, calls: 2} = cost
  end

  test "ignores calls emitted outside the block" do
    emit_call(%Cost{input_tokens: 999, total_cost: 9.9, calls: 1})

    {_r, cost} =
      Cost.track(fn -> emit_call(%Cost{input_tokens: 10, total_cost: 0.001, calls: 1}) end)

    assert %Cost{input_tokens: 10, calls: 1} = cost
  end

  test "captures costs from fan-out workers that replay the settings snapshot" do
    {_r, cost} =
      Cost.track(fn ->
        snapshot = Settings.snapshot()

        1..4
        |> Task.async_stream(fn _ ->
          Settings.run(snapshot, fn ->
            emit_call(%Cost{input_tokens: 5, total_cost: 0.001, calls: 1})
          end)
        end)
        |> Stream.run()
      end)

    assert %Cost{input_tokens: 20, total_cost: 0.004, calls: 4} = cost
  end

  test "tears down and returns partial cost even when the block raises" do
    assert_raise RuntimeError, "boom", fn ->
      Cost.track(fn ->
        emit_call(%Cost{input_tokens: 10, calls: 1})
        raise "boom"
      end)
    end

    emit_call(%Cost{input_tokens: 1, calls: 1})
    {_r, cost} = Cost.track(fn -> emit_call(%Cost{input_tokens: 2, calls: 1}) end)
    assert %Cost{input_tokens: 2, calls: 1} = cost
  end

  test "captures embedding cost alongside predictor cost" do
    {_r, cost} =
      Cost.track(fn ->
        emit_call(%Cost{input_tokens: 10, total_cost: 0.003, calls: 1})
        emit_embed(%Cost{input_tokens: 4, total_cost: 0.002, calls: 1})
      end)

    assert %Cost{input_tokens: 14, total_cost: 0.005, calls: 2} = cost
  end

  test "embed cost emitted outside a track is ignored" do
    emit_embed(%Cost{input_tokens: 999, total_cost: 9.9, calls: 1})
    {_r, cost} = Cost.track(fn -> emit_embed(%Cost{input_tokens: 4, calls: 1}) end)
    assert %Cost{input_tokens: 4, calls: 1} = cost
  end

  test "nested track blocks each capture their own calls" do
    {_r, outer} =
      Cost.track(fn ->
        emit_call(%Cost{input_tokens: 10, calls: 1})

        {_r2, inner} = Cost.track(fn -> emit_call(%Cost{input_tokens: 5, calls: 1}) end)
        assert %Cost{input_tokens: 5, calls: 1} = inner

        emit_call(%Cost{input_tokens: 3, calls: 1})
      end)

    assert %Cost{input_tokens: 18, calls: 3} = outer
  end
end
