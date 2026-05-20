defmodule Dsxir.Trace do
  @moduledoc """
  Process-local trace accumulator for `Dsxir.with_trace/1`.

  Owns a single process-dict slot. When the slot is `nil`, `record/1` is a
  no-op. Inference paths (no `with_trace`) pay one `Process.get/1` per
  `Dsxir.Module.Runtime.call/4` and allocate nothing.

  The slot does not cross process boundaries. `Dsxir.Predictor.Parallel`,
  `Dsxir.Evaluate`, and any user-spawned task run with their own `nil` slot.
  Bootstrap optimization is single-process by design.

  Entries are pushed on the head (`[entry | acc]`) and reversed on `stop/1`,
  so callers see them in forward order.

  Entries are `%Dsxir.Trace.Entry{}` structs. `record/1` also accepts the
  legacy 4-tuple shape `{predictor, inputs, prediction, demos}` and wraps it
  with `degraded: false` via `Dsxir.Trace.Entry.from/1`; producers that
  predate the struct continue to work unchanged.
  """

  @key {__MODULE__, :collector}

  @type entry :: Dsxir.Trace.Entry.t()
  @type legacy_entry :: Dsxir.Trace.Entry.legacy_tuple()

  @doc "Open a fresh accumulator. Returns the prior slot value for `stop/1`."
  @spec start() :: nil | [entry()]
  def start do
    prior = Process.get(@key)
    Process.put(@key, [])
    prior
  end

  @doc "Close the accumulator, restore the prior slot, and return the trace."
  @spec stop(nil | [entry()]) :: [entry()]
  def stop(prior) do
    collected = Process.get(@key, []) |> Enum.reverse()

    case prior do
      nil -> Process.delete(@key)
      list when is_list(list) -> Process.put(@key, list)
    end

    collected
  end

  @doc """
  Append an entry. No-op when no `with_trace` is active.

  Accepts either a `%Dsxir.Trace.Entry{}` struct or the legacy 4-tuple shape
  `{predictor, inputs, prediction, demos}`. Tuples are wrapped with
  `degraded: false` for back-compat with producers that have not yet migrated.
  """
  @spec record(entry() | legacy_entry()) :: :ok
  def record(entry) do
    struct = Dsxir.Trace.Entry.from(entry)

    case Process.get(@key) do
      nil -> :ok
      list when is_list(list) -> Process.put(@key, [struct | list]) |> then(fn _ -> :ok end)
    end
  end

  @doc "True iff a `with_trace` block is currently open in this process."
  @spec active?() :: boolean()
  def active?, do: Process.get(@key) != nil
end
