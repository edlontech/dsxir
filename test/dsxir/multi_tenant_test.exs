defmodule Dsxir.MultiTenantTest do
  use ExUnit.Case, async: false

  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.TelemetryHandler

  setup do
    table = :ets.new(:tenant_recorder, [:public, :duplicate_bag])
    :ets.delete_all_objects(Dsxir.History.table())
    Dsxir.History.enable()

    on_exit(fn ->
      Dsxir.History.disable()
      :ets.delete_all_objects(Dsxir.History.table())
    end)

    {:ok, table: table}
  end

  test "two tenants see only their own telemetry, credentials, and history", %{table: table} do
    handler_id = "tenant-iso-#{:erlang.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:dsxir, :predictor, :stop],
        &TelemetryHandler.forward/4,
        %{parent: parent, tag: :stop}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    snapshot_parent = Dsxir.Settings.snapshot()

    t1 =
      Task.async(fn ->
        Dsxir.Settings.run(snapshot_parent, fn ->
          Dsxir.context(
            [
              lm:
                {Dsxir.Test.Fixtures.TenantLM,
                 [model: "test", api_key: "key-t1", recorder_table: table]},
              metadata: %{tenant_id: "t1"},
              cache: false
            ],
            fn ->
              prog = Dsxir.Program.new(AnswerProgram)
              for _ <- 1..3, do: AnswerProgram.forward(prog, %{question: "q"})
              :ok
            end
          )
        end)
      end)

    t2 =
      Task.async(fn ->
        Dsxir.Settings.run(snapshot_parent, fn ->
          Dsxir.context(
            [
              lm:
                {Dsxir.Test.Fixtures.TenantLM,
                 [model: "test", api_key: "key-t2", recorder_table: table]},
              metadata: %{tenant_id: "t2"},
              cache: false
            ],
            fn ->
              prog = Dsxir.Program.new(AnswerProgram)
              for _ <- 1..3, do: AnswerProgram.forward(prog, %{question: "q"})
              :ok
            end
          )
        end)
      end)

    :ok = Task.await(t1)
    :ok = Task.await(t2)

    rows = :ets.tab2list(table)
    by_tenant = Enum.group_by(rows, fn {_, tid, _, _} -> tid end)

    assert Enum.count(Map.get(by_tenant, "t1", [])) == 3
    assert Enum.count(Map.get(by_tenant, "t2", [])) == 3

    Enum.each(Map.fetch!(by_tenant, "t1"), fn {_, _tid, api_key, _ts} ->
      assert api_key == "key-t1"
    end)

    Enum.each(Map.fetch!(by_tenant, "t2"), fn {_, _tid, api_key, _ts} ->
      assert api_key == "key-t2"
    end)

    stop_events = drain_stops()
    tenants_in_events = Enum.map(stop_events, fn {:stop, _, _, meta} -> Map.get(meta, :tenant_id) end)
    assert Enum.count(tenants_in_events, &(&1 == "t1")) == 3
    assert Enum.count(tenants_in_events, &(&1 == "t2")) == 3

    history_rows = Dsxir.History.last(6)
    tenants_in_history = Enum.map(history_rows, &get_in(&1, [:metadata, :tenant_id]))
    assert Enum.count(tenants_in_history, &(&1 == "t1")) == 3
    assert Enum.count(tenants_in_history, &(&1 == "t2")) == 3
  end

  defp drain_stops(acc \\ []) do
    receive do
      {:stop, _, _, _} = msg -> drain_stops([msg | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
