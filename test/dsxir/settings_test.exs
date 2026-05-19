defmodule Dsxir.SettingsTest do
  use ExUnit.Case, async: false

  setup do
    prior = Dsxir.Settings.snapshot()
    :persistent_term.put({Dsxir.Settings, :globals}, Dsxir.Settings.default_globals())
    Process.delete({Dsxir.Settings, :stack})
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "resolve/2 returns default globals out of the box" do
    assert Dsxir.Settings.resolve(:cache) == true
    assert Dsxir.Settings.resolve(:metadata) == %{}
  end

  test "context/2 frame overrides globals and is restored after fun" do
    assert Dsxir.Settings.resolve(:cache) == true

    result =
      Dsxir.Settings.context([cache: false], fn ->
        Dsxir.Settings.resolve(:cache)
      end)

    assert result == false
    assert Dsxir.Settings.resolve(:cache) == true
  end

  test "context/2 stack is restored even when fun raises" do
    assert_raise RuntimeError, "boom", fn ->
      Dsxir.Settings.context([cache: false], fn -> raise "boom" end)
    end

    assert Dsxir.Settings.resolve(:cache) == true
  end

  test "nested context/2 frames resolve top-down" do
    Dsxir.Settings.context([cache: false], fn ->
      assert Dsxir.Settings.resolve(:cache) == false

      Dsxir.Settings.context([cache: true], fn ->
        assert Dsxir.Settings.resolve(:cache) == true
      end)

      assert Dsxir.Settings.resolve(:cache) == false
    end)
  end

  test "configure/1 merges into globals and rejects unknown keys" do
    assert :ok = Dsxir.Settings.configure(cache: false)
    assert Dsxir.Settings.resolve(:cache) == false

    assert_raise Dsxir.Errors.Invalid.Configuration, fn ->
      Dsxir.Settings.configure(nonsense: 1)
    end
  end

  test "configure/1 drops tenant_* keys with a warning" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Dsxir.Settings.configure(tenant_id: "t1")
      end)

    assert log =~ "rejected tenant_* key"
  end

  test "configure/1 drops :lm when its config carries a non-nil api_key" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Dsxir.Settings.configure(lm: {SomeImpl, [model: "x", api_key: "leaked"]})
      end)

    assert log =~ "rejected :lm with non-nil api_key"
    assert Dsxir.Settings.resolve(:lm) == nil
  end

  test "configure/1 keeps :lm tuples that carry no api_key" do
    assert :ok = Dsxir.Settings.configure(lm: {SomeImpl, [model: "x"]})
    assert {SomeImpl, [model: "x"]} = Dsxir.Settings.resolve(:lm)
  end

  test "snapshot/0 + run/2 replays globals and stack in another process" do
    Dsxir.Settings.context([cache: false], fn ->
      snap = Dsxir.Settings.snapshot()
      parent = self()

      Task.start(fn ->
        result = Dsxir.Settings.run(snap, fn -> Dsxir.Settings.resolve(:cache) end)
        send(parent, {:result, result})
      end)

      assert_receive {:result, false}, 500
    end)
  end

  test "configure/1 strips tenant_* keys nested inside :metadata with a warning" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Dsxir.Settings.configure(metadata: %{tenant_id: "t1", request_id: "r1"})
      end)

    assert log =~ "rejected tenant_* keys inside :metadata"
    assert Dsxir.Settings.resolve(:metadata) == %{request_id: "r1"}
  end

  test "configure/1 leaves :metadata untouched when it carries no tenant_* keys" do
    assert :ok = Dsxir.Settings.configure(metadata: %{request_id: "r1"})
    assert Dsxir.Settings.resolve(:metadata) == %{request_id: "r1"}
  end

  describe "run/2 process-local globals override" do
    test "never writes to :persistent_term, even when snapshot globals differ from live" do
      snap = Dsxir.Settings.snapshot()
      Dsxir.Settings.configure(cache: false)

      put_count =
        with_persistent_term_put_trace(fn ->
          for _ <- 1..100 do
            Dsxir.Settings.run(snap, fn -> :ok end)
          end
        end)

      assert put_count == 0,
             "expected zero :persistent_term.put calls inside run/2, got #{put_count}"
    end

    test "snapshot globals are visible to resolve/2 only inside the run/2 block" do
      snap = Dsxir.Settings.snapshot()
      Dsxir.Settings.configure(cache: false)

      assert Dsxir.Settings.resolve(:cache) == false

      inside =
        Dsxir.Settings.run(snap, fn ->
          Dsxir.Settings.resolve(:cache)
        end)

      assert inside == true
      assert Dsxir.Settings.resolve(:cache) == false
    end

    test "nested run/2 restores the outer override" do
      outer = %{
        Dsxir.Settings.snapshot()
        | globals: %{Dsxir.Settings.default_globals() | cache: false}
      }

      inner = %{
        Dsxir.Settings.snapshot()
        | globals: %{Dsxir.Settings.default_globals() | cache: true}
      }

      Dsxir.Settings.run(outer, fn ->
        assert Dsxir.Settings.resolve(:cache) == false

        Dsxir.Settings.run(inner, fn ->
          assert Dsxir.Settings.resolve(:cache) == true
        end)

        assert Dsxir.Settings.resolve(:cache) == false
      end)
    end

    test "override is restored even when fun raises" do
      Dsxir.Settings.configure(cache: false)

      snap = %{
        Dsxir.Settings.snapshot()
        | globals: %{Dsxir.Settings.default_globals() | cache: true}
      }

      assert_raise RuntimeError, "boom", fn ->
        Dsxir.Settings.run(snap, fn -> raise "boom" end)
      end

      assert Dsxir.Settings.resolve(:cache) == false
    end

    test "concurrent workers replaying different snapshot globals do not leak" do
      live_default = Dsxir.Settings.default_globals()
      Dsxir.Settings.configure(cache: true)

      snap_a = %{globals: %{live_default | cache: false}, stack: []}
      snap_b = %{globals: %{live_default | cache: true}, stack: []}

      parent = self()
      barrier = make_ref()

      t_a =
        Task.async(fn ->
          Dsxir.Settings.run(snap_a, fn ->
            send(parent, {barrier, :a_ready})
            assert_receive {^barrier, :go}, 500
            Dsxir.Settings.resolve(:cache)
          end)
        end)

      t_b =
        Task.async(fn ->
          Dsxir.Settings.run(snap_b, fn ->
            send(parent, {barrier, :b_ready})
            assert_receive {^barrier, :go}, 500
            Dsxir.Settings.resolve(:cache)
          end)
        end)

      assert_receive {^barrier, :a_ready}, 500
      assert_receive {^barrier, :b_ready}, 500
      send(t_a.pid, {barrier, :go})
      send(t_b.pid, {barrier, :go})

      assert Task.await(t_a) == false
      assert Task.await(t_b) == true
      assert Dsxir.Settings.resolve(:cache) == true
    end
  end

  defp with_persistent_term_put_trace(fun) do
    parent = self()
    ref = make_ref()
    key = {Dsxir.Settings, :globals}

    {:ok, tracer} =
      Task.start(fn ->
        loop = fn loop, n ->
          receive do
            {:trace, _, :call, {:persistent_term, :put, [^key, _]}} ->
              loop.(loop, n + 1)

            {:stop, from} ->
              send(from, {ref, :count, n})
          end
        end

        loop.(loop, 0)
      end)

    1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])
    :erlang.trace_pattern({:persistent_term, :put, 2}, true, [:global])

    try do
      fun.()
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({:persistent_term, :put, 2}, false, [:global])
    end

    send(tracer, {:stop, parent})

    receive do
      {^ref, :count, count} -> count
    after
      500 -> flunk("tracer did not report put count")
    end
  end
end
