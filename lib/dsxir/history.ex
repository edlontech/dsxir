defmodule Dsxir.History do
  @moduledoc """
  ETS-backed `inspect_history` developer tool.

  Supervised owner of the `:dsxir_history` ETS table. Creates the table at boot
  and holds it for the lifetime of the application; a telemetry handler attached
  via the (future) `enable/0` API writes entries on `[:dsxir, :predictor, :stop]`.

  No public mailbox API. This module uses `GenServer` only to obtain a
  supervisor-compatible child spec; no `handle_call`/`handle_cast` is exposed.

  Distinct from the multi-turn conversation value type `Dsxir.Primitives.History`
  (added separately by its own consumer). The name overlap is deliberate — each
  matches its DSPy counterpart (`dspy.inspect_history` debug helper vs.
  `dspy.History` value type).
  """

  use GenServer

  @table :dsxir_history

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the ETS table identifier for the dev-tool table. Stable across calls."
  @spec table() :: atom()
  def table, do: @table

  @impl true
  def init(_opts) do
    :ets.new(@table, [:public, :ordered_set, :named_table, write_concurrency: true])
    {:ok, %{}}
  end
end
