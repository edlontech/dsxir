defmodule Dsxir.Optimizer.Cache do
  @moduledoc """
  Compile-scoped LM cache for optimizers that run a program many times.

  An anonymous ETS table is created at the start of `with_compile_cache/2` and
  deleted via `try/after` on exit (normal or raised). `heir: :none` ensures
  owner-process death also reclaims the table. The table is never globally
  registered; only the tid escapes, passed explicitly to workers.

  Used by search-based optimizers to skip duplicate
  `(lm, predictor_state, input)` evaluations within a compile. Tenant-safe by
  construction: each `Dsxir.compile/5` call inside a `Dsxir.context/2` block
  gets its own table; nothing crosses tenants.
  """

  @type key :: term()
  @type tid :: :ets.tid() | nil

  @doc """
  Run `fun.(tid)` with a fresh ETS cache when `enabled?` is true; pass `nil` and
  skip the cache when false. The table is destroyed on exit, including raises.
  """
  @spec with_compile_cache(boolean(), (tid() -> result)) :: result when result: var
  def with_compile_cache(true, fun) when is_function(fun, 1) do
    tid =
      :ets.new(:dsxir_compile_cache, [
        :set,
        :public,
        {:write_concurrency, true},
        {:read_concurrency, true},
        {:heir, :none}
      ])

    try do
      fun.(tid)
    after
      :ets.delete(tid)
    end
  end

  def with_compile_cache(false, fun) when is_function(fun, 1) do
    fun.(nil)
  end

  @doc """
  Lookup `key` in `tid`; on miss, call `fun.()`, store the result, return it.
  A `nil` tid always calls `fun.()` and skips storage.
  """
  @spec get_or_put(tid(), key(), (-> result)) :: result when result: var
  def get_or_put(nil, _key, fun) when is_function(fun, 0), do: fun.()

  def get_or_put(tid, key, fun) when is_function(fun, 0) do
    case :ets.lookup(tid, key) do
      [{^key, cached}] ->
        cached

      [] ->
        value = fun.()
        :ets.insert(tid, {key, value})
        value
    end
  end

  @doc """
  Like `get_or_put/3` but reports whether the value was already present.

  Returns `{:hit, cached}` when `key` was in `tid`, `{:miss, value}` after
  computing and storing. A `nil` tid always reports `:miss` so callers that
  count cache effectiveness see a consistent shape regardless of whether the
  cache is enabled.
  """
  @spec fetch_or_put(tid(), key(), (-> result)) :: {:hit | :miss, result} when result: var
  def fetch_or_put(nil, _key, fun) when is_function(fun, 0), do: {:miss, fun.()}

  def fetch_or_put(tid, key, fun) when is_function(fun, 0) do
    case :ets.lookup(tid, key) do
      [{^key, cached}] ->
        {:hit, cached}

      [] ->
        value = fun.()
        :ets.insert(tid, {key, value})
        {:miss, value}
    end
  end

  @doc """
  Hash a predictor's `Dsxir.Program.State` into a 32-bit integer suitable as
  part of a cache key. The `:demo_strategy` field is excluded because by the
  time the LM is invoked the strategy has already produced concrete demos.
  Demo order does not affect the hash.
  """
  @spec predictor_state_hash(Dsxir.Program.State.t()) :: non_neg_integer()
  def predictor_state_hash(%Dsxir.Program.State{} = state) do
    canonical = %{
      instructions_override: state.instructions_override,
      signature_override: state.signature_override,
      demos: state.demos |> Enum.map(&:erlang.phash2/1) |> Enum.sort()
    }

    :erlang.phash2(canonical)
  end

  @doc """
  Hash an input map into a 32-bit integer. Keys are sorted before hashing so
  map ordering does not change the key.
  """
  @spec input_hash(map()) :: non_neg_integer()
  def input_hash(input) when is_map(input) do
    sorted = input |> Enum.to_list() |> Enum.sort_by(&elem(&1, 0))
    :erlang.phash2(sorted)
  end

  @doc """
  Hash an LM config keyword list. Keys are sorted so option order is irrelevant;
  `:api_key` and `:model` are included so tenants with different credentials
  never collide on a shared key.
  """
  @spec lm_config_hash(keyword()) :: non_neg_integer()
  def lm_config_hash(config) when is_list(config) do
    :erlang.phash2(Enum.sort(config))
  end
end
