defmodule Dsxir.OptimizerSession.Store.ETSTest do
  use ExUnit.Case, async: false

  alias Dsxir.OptimizerSession.Checkpoint
  alias Dsxir.OptimizerSession.Store.ETS

  setup do
    case Process.whereis(ETS) do
      nil -> {:ok, _} = ETS.start_link([])
      _ -> :ok
    end

    on_exit(fn ->
      try do
        :ets.delete_all_objects(:dsxir_optimizer_sessions)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ets.delete_all_objects(:dsxir_optimizer_sessions)
    :ok
  end

  defp fresh_checkpoint(id, status \\ :running, opt \\ FooOptimizer) do
    Checkpoint.new(
      session_id: id,
      optimizer: opt,
      optimizer_opts: [],
      trainset_hash: <<0::256>>,
      program_module: MyApp,
      sampler_blob: <<>>,
      sampler_format: {opt, 1}
    )
    |> Map.put(:status, status)
  end

  test "put/get round-trip" do
    cp = fresh_checkpoint("sess_a")
    :ok = ETS.put_checkpoint([], "sess_a", cp)
    assert {:ok, ^cp} = ETS.get_checkpoint([], "sess_a")
  end

  test "get/2 returns :not_found for missing id" do
    assert {:error, :not_found} = ETS.get_checkpoint([], "sess_missing")
  end

  test "list_sessions/2 filters by status" do
    :ok = ETS.put_checkpoint([], "sess_r", fresh_checkpoint("sess_r", :running))
    :ok = ETS.put_checkpoint([], "sess_c", fresh_checkpoint("sess_c", :completed))

    assert {:ok, [%{session_id: "sess_r"}]} = ETS.list_sessions([], status: :running)
    assert {:ok, [%{session_id: "sess_c"}]} = ETS.list_sessions([], status: :completed)
  end

  test "list_sessions/2 filters by optimizer" do
    :ok = ETS.put_checkpoint([], "sess_a", fresh_checkpoint("sess_a", :running, FooOpt))
    :ok = ETS.put_checkpoint([], "sess_b", fresh_checkpoint("sess_b", :running, BarOpt))

    assert {:ok, [%{session_id: "sess_a"}]} = ETS.list_sessions([], optimizer: FooOpt)
  end

  test "list_sessions/2 filters by updated_since" do
    cp_old = fresh_checkpoint("sess_old") |> Map.put(:updated_at, ~U[2020-01-01 00:00:00Z])
    cp_new = fresh_checkpoint("sess_new") |> Map.put(:updated_at, ~U[2030-01-01 00:00:00Z])
    :ok = ETS.put_checkpoint([], "sess_old", cp_old)
    :ok = ETS.put_checkpoint([], "sess_new", cp_new)

    assert {:ok, [%{session_id: "sess_new"}]} =
             ETS.list_sessions([], updated_since: ~U[2025-01-01 00:00:00Z])
  end

  test "delete_checkpoint/2 is idempotent" do
    :ok = ETS.put_checkpoint([], "sess_d", fresh_checkpoint("sess_d"))
    :ok = ETS.delete_checkpoint([], "sess_d")
    :ok = ETS.delete_checkpoint([], "sess_d")
    assert {:error, :not_found} = ETS.get_checkpoint([], "sess_d")
  end
end
