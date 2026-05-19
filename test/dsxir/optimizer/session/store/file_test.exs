defmodule Dsxir.OptimizerSession.Store.FileTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Dsxir.OptimizerSession.Checkpoint
  alias Dsxir.OptimizerSession.Store.File, as: FileStore

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "dsxir-session-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp fresh(id, status \\ :running, opt \\ FooOpt) do
    Checkpoint.new(
      session_id: id,
      optimizer: opt,
      optimizer_opts: [],
      trainset_hash: <<1::256>>,
      program_module: MyApp,
      sampler_blob: <<10, 20, 30>>,
      sampler_format: {opt, 1}
    )
    |> Map.put(:status, status)
  end

  test "binary format round-trips", %{dir: dir} do
    cp = fresh("sess_b1")
    opts = [dir: dir, format: :binary]
    :ok = FileStore.put_checkpoint(opts, "sess_b1", cp)
    assert {:ok, ^cp} = FileStore.get_checkpoint(opts, "sess_b1")
  end

  test "json format round-trips", %{dir: dir} do
    cp = fresh("sess_j1")
    opts = [dir: dir, format: :json]
    :ok = FileStore.put_checkpoint(opts, "sess_j1", cp)
    {:ok, loaded} = FileStore.get_checkpoint(opts, "sess_j1")
    assert loaded.session_id == cp.session_id
    assert loaded.sampler_blob == cp.sampler_blob
    assert loaded.sampler_format == cp.sampler_format
    assert loaded.optimizer == cp.optimizer
    assert loaded.program_module == cp.program_module
    assert loaded.trainset_hash == cp.trainset_hash
    assert DateTime.diff(loaded.created_at, cp.created_at, :microsecond) == 0
    assert DateTime.diff(loaded.updated_at, cp.updated_at, :microsecond) == 0
  end

  test "json format round-trips non-JSON-safe optimizer_opts (tuples, atoms)", %{dir: dir} do
    opts_with_tuple = [
      seed: 42,
      range: {0.1, 0.9},
      mode: :greedy,
      nested: %{ratio: {1, 2}}
    ]

    cp =
      "sess_j_opts"
      |> fresh()
      |> Map.put(:optimizer_opts, opts_with_tuple)

    store_opts = [dir: dir, format: :json]
    :ok = FileStore.put_checkpoint(store_opts, "sess_j_opts", cp)
    {:ok, loaded} = FileStore.get_checkpoint(store_opts, "sess_j_opts")
    assert loaded.optimizer_opts == opts_with_tuple
  end

  test "get_checkpoint/2 returns :not_found for missing id", %{dir: dir} do
    opts = [dir: dir, format: :binary]
    assert {:error, :not_found} = FileStore.get_checkpoint(opts, "missing")
  end

  test "list_sessions/2 returns empty list when dir does not exist", %{dir: dir} do
    opts = [dir: dir, format: :binary]
    assert {:ok, []} = FileStore.list_sessions(opts, [])
  end

  test "list_sessions/2 filters by status", %{dir: dir} do
    opts = [dir: dir, format: :binary]
    :ok = FileStore.put_checkpoint(opts, "a", fresh("a", :running))
    :ok = FileStore.put_checkpoint(opts, "b", fresh("b", :completed))

    {:ok, run} = FileStore.list_sessions(opts, status: :running)
    assert Enum.map(run, & &1.session_id) == ["a"]

    {:ok, done} = FileStore.list_sessions(opts, status: :completed)
    assert Enum.map(done, & &1.session_id) == ["b"]
  end

  test "list_sessions/2 filters by optimizer", %{dir: dir} do
    opts = [dir: dir, format: :binary]
    :ok = FileStore.put_checkpoint(opts, "a", fresh("a", :running, FooOpt))
    :ok = FileStore.put_checkpoint(opts, "b", fresh("b", :running, BarOpt))

    {:ok, foo} = FileStore.list_sessions(opts, optimizer: FooOpt)
    assert Enum.map(foo, & &1.session_id) == ["a"]
  end

  test "list_sessions/2 filters by updated_since", %{dir: dir} do
    opts = [dir: dir, format: :binary]
    cp_old = fresh("sess_old") |> Map.put(:updated_at, ~U[2020-01-01 00:00:00Z])
    cp_new = fresh("sess_new") |> Map.put(:updated_at, ~U[2030-01-01 00:00:00Z])
    :ok = FileStore.put_checkpoint(opts, "sess_old", cp_old)
    :ok = FileStore.put_checkpoint(opts, "sess_new", cp_new)

    {:ok, listings} =
      FileStore.list_sessions(opts, updated_since: ~U[2025-01-01 00:00:00Z])

    assert Enum.map(listings, & &1.session_id) == ["sess_new"]
  end

  test "delete_checkpoint/2 is idempotent", %{dir: dir} do
    opts = [dir: dir, format: :binary]
    :ok = FileStore.put_checkpoint(opts, "x", fresh("x"))
    :ok = FileStore.delete_checkpoint(opts, "x")
    :ok = FileStore.delete_checkpoint(opts, "x")
    assert {:error, :not_found} = FileStore.get_checkpoint(opts, "x")
  end

  test "atomic write: simulated crash between tmp write and rename leaves canonical intact",
       %{dir: dir} do
    cp_v1 = fresh("sess_atomic")
    opts = [dir: dir, format: :binary]
    :ok = FileStore.put_checkpoint(opts, "sess_atomic", cp_v1)

    Mimic.copy(File)

    Mimic.expect(File, :rename!, fn _tmp, _path ->
      raise %File.RenameError{
        action: "rename",
        reason: :enospc,
        source: "x",
        destination: "y"
      }
    end)

    cp_v2 = %{cp_v1 | updated_at: DateTime.add(cp_v1.updated_at, 60, :second)}

    assert_raise File.RenameError, fn ->
      FileStore.put_checkpoint(opts, "sess_atomic", cp_v2)
    end

    {:ok, loaded} = FileStore.get_checkpoint(opts, "sess_atomic")
    assert loaded.updated_at == cp_v1.updated_at
  end
end
