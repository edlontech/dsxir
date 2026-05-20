defmodule Dsxir.RuntimeProgram.Store.ETS do
  @moduledoc """
  ETS-backed in-memory implementation of `Dsxir.RuntimeProgram.Store`.

  A `GenServer` is used solely to own the named ETS table so that it is
  anchored to a supervisor: ETS tables die with their owner. All reads and
  writes go directly through `:ets`, bypassing the `GenServer` message
  queue (the table is `:public` with `:read_concurrency`).

  The store is opt-in: it is not started by the dsxir application. Users
  start it under their own supervision tree:

      children = [
        {Dsxir.RuntimeProgram.Store.ETS,
         name: MyStore, table: :my_runtime_program_table}
      ]

  ## `:name` vs `:table`

  The two options are intentionally distinct:

    * `:name` is the registered name of the owning `GenServer` process
      (defaults to `__MODULE__`).
    * `:table` is the ETS table atom that callers pass as `ref` to
      `put/2`, `get/2`, and `list/2` (defaults to
      `:dsxir_runtime_program_store`).

  The `ref` argument forwarded to `Dsxir.RuntimeProgram.from_map/2` via
  `store: {Dsxir.RuntimeProgram.Store.ETS, ref}` MUST be the **table** atom
  (`:table` opt), NOT the GenServer name. The two are kept separate so the
  table can be referenced and queried independently of the owner process
  (and the owner can be restarted under supervision without callers having
  to know its pid).
  """

  use GenServer

  @behaviour Dsxir.RuntimeProgram.Store

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Store

  @default_table :dsxir_runtime_program_store

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, @default_table)
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl Dsxir.RuntimeProgram.Store
  def put(table, %RuntimeProgram{} = rp) do
    true = :ets.insert(table, {{rp.id, rp.version}, rp})
    :ok
  end

  @impl Dsxir.RuntimeProgram.Store
  def get(table, {id, version}) do
    case :ets.lookup(table, {id, version}) do
      [{_key, %RuntimeProgram{} = rp}] -> {:ok, rp}
      [] -> {:error, :not_found}
    end
  end

  @impl Dsxir.RuntimeProgram.Store
  def list(table, filter) do
    rps =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {_key, rp} -> rp end)
      |> Store.apply_filter(filter)

    {:ok, rps}
  end
end
