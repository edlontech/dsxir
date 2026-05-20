defmodule Dsxir.RuntimeProgram.Store.FileTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Store.File, as: FileStore
  alias Dsxir.Test.Fixtures.RuntimeProgramPayloads

  @moduletag :tmp_dir

  setup_all do
    Code.ensure_loaded!(Dsxir.Test.Fixtures.AnswerQuestion)
    Code.ensure_loaded!(Dsxir.Predictor.Predict)
    _ = [:qa, :refine, :question, :answer, :required]
    :ok
  end

  defp sample_rp(opts \\ []) do
    id = Keyword.get(opts, :id, "qa/valid")
    metadata = Keyword.get(opts, :metadata, %{"description" => "valid two-stage qa"})

    payload =
      RuntimeProgramPayloads.valid()
      |> Map.put("id", id)
      |> Map.put("metadata", metadata)

    {:ok, rp} = RuntimeProgram.from_map(payload)
    rp
  end

  test "put + get round-trip yields the same struct", %{tmp_dir: dir} do
    rp = sample_rp()
    :ok = FileStore.put(dir, rp)
    assert {:ok, ^rp} = FileStore.get(dir, {rp.id, rp.version})
  end

  test "get/2 on missing key returns {:error, :not_found}", %{tmp_dir: dir} do
    assert {:error, :not_found} = FileStore.get(dir, {"nope", <<0::256>>})
  end

  test "list/2 with empty filter returns all stored programs", %{tmp_dir: dir} do
    a = sample_rp(id: "qa/a")
    b = sample_rp(id: "qa/b")
    :ok = FileStore.put(dir, a)
    :ok = FileStore.put(dir, b)

    {:ok, listed} = FileStore.list(dir, [])
    ids = listed |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["qa/a", "qa/b"]
  end

  test "list/2 filters by tenant_id with string metadata keys", %{tmp_dir: dir} do
    a = sample_rp(id: "qa/a", metadata: %{"tenant_id" => "t1"})
    b = sample_rp(id: "qa/b", metadata: %{"tenant_id" => "t2"})
    :ok = FileStore.put(dir, a)
    :ok = FileStore.put(dir, b)

    {:ok, [only]} = FileStore.list(dir, tenant_id: "t1")
    assert only.id == "qa/a"
  end

  test "list/2 filters by tenant_id with atom metadata keys", %{tmp_dir: dir} do
    a = sample_rp(id: "qa/a", metadata: %{tenant_id: "t1"})
    b = sample_rp(id: "qa/b", metadata: %{tenant_id: "t2"})
    :ok = FileStore.put(dir, a)
    :ok = FileStore.put(dir, b)

    {:ok, [only]} = FileStore.list(dir, tenant_id: "t1")
    assert only.id == "qa/a"
  end

  test "list/2 filters by id", %{tmp_dir: dir} do
    a = sample_rp(id: "qa/a")
    b = sample_rp(id: "qa/b")
    :ok = FileStore.put(dir, a)
    :ok = FileStore.put(dir, b)

    {:ok, [only]} = FileStore.list(dir, id: "qa/b")
    assert only.id == "qa/b"
  end

  test "list/2 returns empty list when dir does not exist" do
    missing =
      Path.join(System.tmp_dir!(), "dsxir-rp-store-missing-#{System.unique_integer([:positive])}")

    assert {:ok, []} = FileStore.list(missing, [])
  end

  test "atomic write: no .tmp sibling remains after successful put", %{tmp_dir: dir} do
    rp = sample_rp()
    :ok = FileStore.put(dir, rp)
    files = File.ls!(dir)
    assert Enum.any?(files, &String.ends_with?(&1, ".json"))
    refute Enum.any?(files, &String.contains?(&1, ".tmp"))
  end

  test "atomic write: failed rename leaves prior version intact", %{tmp_dir: dir} do
    rp = sample_rp()
    :ok = FileStore.put(dir, rp)

    {:ok, loaded_before} = FileStore.get(dir, {rp.id, rp.version})

    rp_mutated = %{rp | metadata: %{"changed" => true}}

    Mimic.expect(File, :rename!, fn _tmp, _path ->
      raise %File.RenameError{
        action: "rename",
        reason: :enospc,
        source: "x",
        destination: "y"
      }
    end)

    assert_raise File.RenameError, fn ->
      FileStore.put(dir, rp_mutated)
    end

    {:ok, loaded_after} = FileStore.get(dir, {rp.id, rp.version})
    assert loaded_after == loaded_before

    files = File.ls!(dir)
    refute Enum.any?(files, &String.contains?(&1, ".tmp"))
  end

  describe "path traversal" do
    @traversal_ids [
      "../../etc/passwd",
      "../leak",
      "..",
      "../../..",
      "/etc/passwd",
      "/absolute/path",
      "\\\\windows\\\\style",
      "~/.ssh/id_rsa",
      "subdir/../escape",
      "..\\..\\winleak"
    ]

    for id <- @traversal_ids do
      test "put/2 with id #{inspect(id)} writes inside root_dir", %{tmp_dir: dir} do
        rp = sample_rp(id: unquote(id))
        :ok = FileStore.put(dir, rp)

        root_canon = Path.expand(dir)

        written =
          Path.wildcard(Path.join(dir, "*.json"))
          |> Enum.map(&Path.expand/1)

        assert written != [], "expected at least one file under #{inspect(dir)}"

        for file <- written do
          assert String.starts_with?(file, root_canon <> "/") or file == root_canon,
                 "file #{inspect(file)} escaped root #{inspect(root_canon)}"

          assert Path.dirname(file) == root_canon,
                 "file #{inspect(file)} not directly under root #{inspect(root_canon)}"
        end
      end
    end
  end
end
