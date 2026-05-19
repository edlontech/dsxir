defmodule Dsxir.Optimizer.CacheTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.Cache
  alias Dsxir.Program.State

  describe "with_compile_cache/2" do
    test "passes a tid to the function and destroys the table on normal exit" do
      tid_outside =
        Cache.with_compile_cache(true, fn tid ->
          assert is_reference(tid) or is_integer(tid)
          assert :ets.info(tid) != :undefined
          tid
        end)

      assert :ets.info(tid_outside) == :undefined
    end

    test "destroys the table even when fun raises" do
      tid_outside =
        try do
          Cache.with_compile_cache(true, fn tid ->
            send(self(), {:tid, tid})
            raise "boom"
          end)
        rescue
          _ ->
            receive do
              {:tid, t} -> t
            end
        end

      assert :ets.info(tid_outside) == :undefined
    end

    test "passes nil when enabled? is false" do
      assert Cache.with_compile_cache(false, fn nil -> :ok end) == :ok
    end
  end

  describe "get_or_put/3" do
    test "nil tid always invokes the fun" do
      ref = make_ref()
      assert Cache.get_or_put(nil, :anything, fn -> ref end) == ref
    end

    test "hit returns cached value, miss invokes fun and stores it" do
      Cache.with_compile_cache(true, fn tid ->
        first = Cache.get_or_put(tid, :k, fn -> :computed end)
        second = Cache.get_or_put(tid, :k, fn -> :never_called end)
        assert first == :computed
        assert second == :computed
      end)
    end
  end

  describe "fetch_or_put/3" do
    test "nil tid always reports :miss and invokes the fun" do
      ref = make_ref()
      assert {:miss, ^ref} = Cache.fetch_or_put(nil, :anything, fn -> ref end)
    end

    test "first call reports :miss, second :hit with the cached value" do
      Cache.with_compile_cache(true, fn tid ->
        assert {:miss, :computed} = Cache.fetch_or_put(tid, :k, fn -> :computed end)
        assert {:hit, :computed} = Cache.fetch_or_put(tid, :k, fn -> :never_called end)
      end)
    end
  end

  describe "tenant isolation" do
    test "two concurrent compile caches never share entries" do
      parent = self()

      task_a =
        Task.async(fn ->
          Cache.with_compile_cache(true, fn tid ->
            Cache.get_or_put(tid, :shared_key, fn -> :tenant_a end)
            send(parent, {:tenant_a_tid, tid})

            receive do
              :done -> :ok
            end
          end)
        end)

      task_b =
        Task.async(fn ->
          Cache.with_compile_cache(true, fn tid ->
            Cache.get_or_put(tid, :shared_key, fn -> :tenant_b end)
            send(parent, {:tenant_b_tid, tid})

            receive do
              :done -> :ok
            end
          end)
        end)

      tid_a =
        receive do
          {:tenant_a_tid, t} -> t
        end

      tid_b =
        receive do
          {:tenant_b_tid, t} -> t
        end

      assert tid_a != tid_b
      assert :ets.lookup(tid_a, :shared_key) == [{:shared_key, :tenant_a}]
      assert :ets.lookup(tid_b, :shared_key) == [{:shared_key, :tenant_b}]

      send(task_a.pid, :done)
      send(task_b.pid, :done)
      Task.await_many([task_a, task_b])
    end
  end

  describe "predictor_state_hash/1" do
    test "is stable under demo reordering" do
      a = %State{demos: [%{x: 1}, %{x: 2}], instructions_override: nil}
      b = %State{demos: [%{x: 2}, %{x: 1}], instructions_override: nil}
      assert Cache.predictor_state_hash(a) == Cache.predictor_state_hash(b)
    end

    test "differs when instruction override differs" do
      a = %State{demos: [], instructions_override: "be brief"}
      b = %State{demos: [], instructions_override: "be thorough"}
      refute Cache.predictor_state_hash(a) == Cache.predictor_state_hash(b)
    end
  end

  describe "input_hash/1" do
    test "is stable under key reordering" do
      assert Cache.input_hash(%{a: 1, b: 2}) == Cache.input_hash(%{b: 2, a: 1})
    end
  end
end
