defmodule Dsxir.OptimizerSession.Store.ETS do
  @moduledoc """
  ETS-backed Store. Named table `:dsxir_optimizer_sessions`, `:public, :set,
  write_concurrency: true`. Survives session crashes; does NOT survive node
  restarts. Default in `Mix.env() == :test`.
  """

  @behaviour Dsxir.OptimizerSession.Store

  use GenServer

  alias Dsxir.OptimizerSession.Checkpoint

  @table :dsxir_optimizer_sessions

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, %{}}
  end

  @impl Dsxir.OptimizerSession.Store
  def put_checkpoint(_opts, session_id, %Checkpoint{} = cp) do
    ensure_table!()
    true = :ets.insert(@table, {session_id, cp})
    :ok
  end

  @impl Dsxir.OptimizerSession.Store
  def get_checkpoint(_opts, session_id) do
    ensure_table!()

    case :ets.lookup(@table, session_id) do
      [{^session_id, %Checkpoint{} = cp}] -> {:ok, cp}
      [] -> {:error, :not_found}
    end
  end

  @impl Dsxir.OptimizerSession.Store
  def list_sessions(_opts, filter) do
    ensure_table!()

    status_filter = Keyword.get(filter, :status)
    optimizer_filter = Keyword.get(filter, :optimizer)
    updated_since = Keyword.get(filter, :updated_since)

    listings =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {_id, cp} -> to_listing(cp) end)
      |> Enum.filter(fn l ->
        (is_nil(status_filter) or l.status == status_filter) and
          (is_nil(optimizer_filter) or l.optimizer == optimizer_filter) and
          (is_nil(updated_since) or DateTime.compare(l.updated_at, updated_since) != :lt)
      end)

    {:ok, listings}
  end

  @impl Dsxir.OptimizerSession.Store
  def delete_checkpoint(_opts, session_id) do
    ensure_table!()
    true = :ets.delete(@table, session_id)
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        raise "Dsxir.OptimizerSession.Store.ETS table not started; add to your supervision tree"

      _ ->
        :ok
    end
  end

  defp to_listing(%Checkpoint{} = cp) do
    %{
      session_id: cp.session_id,
      status: cp.status,
      updated_at: cp.updated_at,
      optimizer: cp.optimizer,
      best_score: cp.progress.best_score
    }
  end
end
