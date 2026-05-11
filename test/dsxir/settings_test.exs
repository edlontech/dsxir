defmodule Dsxir.SettingsTest do
  use ExUnit.Case, async: false

  setup do
    prior = Dsxir.Settings.snapshot()
    :persistent_term.put({Dsxir.Settings, :globals}, Dsxir.Settings.default_globals())
    Process.delete({Dsxir.Settings, :stack})
    on_exit(fn -> Dsxir.Settings.run(prior, fn -> :ok end) end)
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
end
