defmodule Dsxir.History do
  @moduledoc """
  ETS-backed `inspect_history` developer tool.

  Supervised owner of the `:dsxir_history` ETS table. Creates the table at boot
  and holds it for the lifetime of the application; a telemetry handler attached
  via `enable/0` writes entries on `[:dsxir, :predictor, :stop]`.

  The handler runs in the calling process (telemetry's design), so the GenServer
  never becomes a write bottleneck. Inserts use a monotonic unique integer key in
  an `:ordered_set` ETS table so the newest entry is always `:ets.last/1`.

  Trim is driven by an `:atomics`-backed `:counters` reference. On every insert
  the counter is incremented; once it exceeds `max_history_size + trim_batch_size`
  any caller may attempt a trim of the oldest `trim_batch_size` rows. Trim is
  race-tolerant: deletes are idempotent, so concurrent attempts cannot corrupt
  the table. Transient overshoot of up to `trim_batch_size` rows is acceptable.

  Configuration via `Application.get_env(:dsxir, Dsxir.History, [])`:

    * `:max_history_size` (default `10_000`)
    * `:trim_batch_size` (default `256`)

  Distinct from the multi-turn conversation value type `Dsxir.Primitives.History`
  (added separately by its own consumer). The name overlap is deliberate — each
  matches its DSPy counterpart (`dspy.inspect_history` debug helper vs.
  `dspy.History` value type).
  """

  use GenServer

  @table :dsxir_history
  @handler_id "dsxir-history-handler"
  @structured_keys [:predictor, :signature, :adapter, :prediction, :error_class]

  defstruct [:counter_ref, :max_size, :trim_batch]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the ETS table identifier for the dev-tool table. Stable across calls."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Attaches the telemetry handler to `[:dsxir, :predictor, :stop]`. Idempotent —
  calling again replaces the existing attachment with the current configuration.
  """
  @spec enable() :: :ok
  def enable, do: GenServer.call(__MODULE__, :enable)

  @doc "Detaches the telemetry handler. Idempotent."
  @spec disable() :: :ok
  def disable, do: GenServer.call(__MODULE__, :disable)

  @doc "Returns the last `n` entries, newest first."
  @spec last(non_neg_integer()) :: [map()]
  def last(n) when is_integer(n) and n >= 0, do: collect(n)

  @doc """
  Returns the last `n` entries, newest first.

  When `:file` is supplied the rows are also written to disk as one JSON-encoded
  entry per line. The `prediction` field is rendered via `inspect/1` so structs
  containing functions or PIDs do not break encoding.
  """
  @spec last(non_neg_integer(), keyword()) :: [map()]
  def last(n, opts) when is_integer(n) and n >= 0 and is_list(opts) do
    rows = collect(n)

    case Keyword.get(opts, :file) do
      nil ->
        rows

      path when is_binary(path) ->
        payload = Enum.map_join(rows, "\n", &(&1 |> row_for_file() |> Jason.encode!()))
        File.write!(path, payload)
        rows
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:public, :ordered_set, :named_table, write_concurrency: true])
    counter_ref = :counters.new(1, [:atomics])
    env = Application.get_env(:dsxir, __MODULE__, [])

    state = %__MODULE__{
      counter_ref: counter_ref,
      max_size: Keyword.get(env, :max_history_size, 10_000),
      trim_batch: Keyword.get(env, :trim_batch_size, 256)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        [:dsxir, :predictor, :stop],
        &__MODULE__.handle_event/4,
        state
      )

    {:reply, :ok, state}
  end

  def handle_call(:disable, _from, state) do
    _ = :telemetry.detach(@handler_id)
    {:reply, :ok, state}
  end

  @doc false
  def handle_event(_event, measurements, metadata, %__MODULE__{} = state) do
    key = :erlang.unique_integer([:monotonic, :positive])

    row = %{
      occurred_at: System.system_time(:microsecond),
      predictor: Map.get(metadata, :predictor),
      signature: Map.get(metadata, :signature),
      adapter: Map.get(metadata, :adapter),
      prediction: Map.get(metadata, :prediction),
      tokens_in: Map.get(measurements, :tokens_in),
      tokens_out: Map.get(measurements, :tokens_out),
      cost: Map.get(measurements, :cost),
      duration: Map.get(measurements, :duration),
      metadata: Map.drop(metadata, @structured_keys)
    }

    :ets.insert(@table, {key, row})
    :ok = :counters.add(state.counter_ref, 1, 1)
    new_count = :counters.get(state.counter_ref, 1)

    if new_count > state.max_size + state.trim_batch do
      maybe_trim(state)
    end

    :ok
  end

  defp maybe_trim(%__MODULE__{trim_batch: batch, counter_ref: ref}) do
    keys = oldest_keys(batch)

    removed =
      Enum.reduce(keys, 0, fn key, acc ->
        case :ets.take(@table, key) do
          [_] -> acc + 1
          [] -> acc
        end
      end)

    if removed > 0 do
      :ok = :counters.sub(ref, 1, removed)
    end

    :ok
  end

  defp oldest_keys(batch) do
    walk_forward(:ets.first(@table), batch, [])
  end

  defp walk_forward(:"$end_of_table", _n, acc), do: Enum.reverse(acc)
  defp walk_forward(_key, 0, acc), do: Enum.reverse(acc)

  defp walk_forward(key, n, acc) do
    walk_forward(:ets.next(@table, key), n - 1, [key | acc])
  end

  defp collect(0), do: []

  defp collect(n) do
    walk_back(:ets.last(@table), n, [])
  end

  defp walk_back(:"$end_of_table", _n, acc), do: Enum.reverse(acc)
  defp walk_back(_key, 0, acc), do: Enum.reverse(acc)

  defp walk_back(key, n, acc) do
    case :ets.lookup(@table, key) do
      [{^key, row}] -> walk_back(:ets.prev(@table, key), n - 1, [row | acc])
      [] -> walk_back(:ets.prev(@table, key), n, acc)
    end
  end

  defp row_for_file(row) do
    Map.update(row, :prediction, nil, fn
      nil -> nil
      value -> inspect(value)
    end)
  end
end
