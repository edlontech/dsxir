defmodule Dsxir.OptimizerSession.MultiTenantTest do
  use ExUnit.Case, async: false

  alias Dsxir.OptimizerSession
  alias Dsxir.Settings
  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.Fixtures.MimicOptimizer

  setup do
    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defp dummy_program, do: Dsxir.Program.new(AnswerProgram)
  defp dummy_metric, do: fn _ex, _pred, _trace -> 0.0 end

  test "two concurrent sessions carry distinct tenant_id metadata in telemetry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:dsxir, :optimizer_session, :trial]])
    on_exit(fn -> :telemetry.detach(ref) end)

    t1 =
      Task.async(fn ->
        Settings.context([metadata: %{tenant_id: "tenant_a"}], fn ->
          OptimizerSession.compile(
            MimicOptimizer,
            dummy_program(),
            [%{x: 1}],
            dummy_metric(),
            scripted_scores: [0.5, 0.6]
          )
        end)
      end)

    t2 =
      Task.async(fn ->
        Settings.context([metadata: %{tenant_id: "tenant_b"}], fn ->
          OptimizerSession.compile(
            MimicOptimizer,
            dummy_program(),
            [%{x: 1}],
            dummy_metric(),
            scripted_scores: [0.7, 0.8]
          )
        end)
      end)

    {:ok, _, _} = Task.await(t1, 5000)
    {:ok, _, _} = Task.await(t2, 5000)

    tenant_ids =
      ref
      |> collect_trial_metadata([])
      |> Enum.map(& &1[:tenant_id])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert tenant_ids == ["tenant_a", "tenant_b"]
  end

  test ":stop telemetry event fires on terminal transition with duration and best_score" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:dsxir, :optimizer_session, :stop]])
    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, _, _} =
      OptimizerSession.compile(
        MimicOptimizer,
        dummy_program(),
        [%{x: 1}],
        dummy_metric(),
        scripted_scores: [0.5, 0.6]
      )

    assert_receive {[:dsxir, :optimizer_session, :stop], ^ref, meas, meta}, 2000
    assert Map.has_key?(meas, :duration_ms)
    assert is_integer(meas.duration_ms)
    assert meas.trials_completed == 2
    assert meas.best_score == 0.6
    assert meta.status == :completed
    assert is_binary(meta.session_id)
  end

  defp collect_trial_metadata(ref, acc) do
    receive do
      {[:dsxir, :optimizer_session, :trial], ^ref, _meas, meta} ->
        collect_trial_metadata(ref, [meta | acc])
    after
      200 -> acc
    end
  end
end
