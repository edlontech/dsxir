defmodule Dsxir.RuntimeProgram.Store.ETSTest do
  use ExUnit.Case, async: false

  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Store.ETS
  alias Dsxir.Test.Fixtures.RuntimeProgramPayloads

  @table :rp_store_table_test

  setup_all do
    Code.ensure_loaded!(Dsxir.Test.Fixtures.AnswerQuestion)
    Code.ensure_loaded!(Dsxir.Predictor.Predict)
    _ = [:qa, :refine, :question, :answer, :required]
    :ok
  end

  setup do
    start_supervised!({ETS, name: :rp_store_test, table: @table})
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

  test "put + get round-trip yields the same struct" do
    rp = sample_rp()
    :ok = ETS.put(@table, rp)
    assert {:ok, ^rp} = ETS.get(@table, {rp.id, rp.version})
  end

  test "get/2 on missing key returns {:error, :not_found}" do
    assert {:error, :not_found} = ETS.get(@table, {"nope", <<0::256>>})
  end

  test "list/2 with empty filter returns all stored programs" do
    a = sample_rp(id: "qa/a")
    b = sample_rp(id: "qa/b")
    :ok = ETS.put(@table, a)
    :ok = ETS.put(@table, b)

    {:ok, listed} = ETS.list(@table, [])
    ids = listed |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["qa/a", "qa/b"]
  end

  test "list/2 filters by tenant_id with string metadata keys" do
    a = sample_rp(id: "qa/a", metadata: %{"tenant_id" => "t1"})
    b = sample_rp(id: "qa/b", metadata: %{"tenant_id" => "t2"})
    :ok = ETS.put(@table, a)
    :ok = ETS.put(@table, b)

    {:ok, [only]} = ETS.list(@table, tenant_id: "t1")
    assert only.id == "qa/a"
  end

  test "list/2 filters by tenant_id with atom metadata keys" do
    a = sample_rp(id: "qa/a", metadata: %{tenant_id: "t1"})
    b = sample_rp(id: "qa/b", metadata: %{tenant_id: "t2"})
    :ok = ETS.put(@table, a)
    :ok = ETS.put(@table, b)

    {:ok, [only]} = ETS.list(@table, tenant_id: "t1")
    assert only.id == "qa/a"
  end

  test "list/2 filters by id (exact match)" do
    a = sample_rp(id: "qa/a")
    b = sample_rp(id: "qa/b")
    :ok = ETS.put(@table, a)
    :ok = ETS.put(@table, b)

    {:ok, [only]} = ETS.list(@table, id: "qa/b")
    assert only.id == "qa/b"
  end

  test "list/2 combines tenant_id and id filters" do
    a = sample_rp(id: "qa/a", metadata: %{"tenant_id" => "t1"})
    b = sample_rp(id: "qa/b", metadata: %{"tenant_id" => "t1"})
    c = sample_rp(id: "qa/c", metadata: %{"tenant_id" => "t2"})
    :ok = ETS.put(@table, a)
    :ok = ETS.put(@table, b)
    :ok = ETS.put(@table, c)

    {:ok, results} = ETS.list(@table, tenant_id: "t1", id: "qa/a")
    assert Enum.map(results, & &1.id) == ["qa/a"]
  end

  describe "name vs table" do
    test "the :table opt is the ETS table; the :name opt is the GenServer name" do
      start_supervised!(
        {ETS, name: :my_store_owner, table: :my_store_table},
        id: :diverge_pair
      )

      rp = sample_rp(id: "qa/diverge")

      assert :ok = ETS.put(:my_store_table, rp)
      assert {:ok, ^rp} = ETS.get(:my_store_table, {rp.id, rp.version})

      assert_raise ArgumentError, fn ->
        ETS.put(:my_store_owner, rp)
      end
    end
  end
end
