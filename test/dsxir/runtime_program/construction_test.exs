defmodule Dsxir.RuntimeProgram.ConstructionTest do
  use ExUnit.Case, async: false

  alias Dsxir.Errors.Halted
  alias Dsxir.Errors.Invalid
  alias Dsxir.ProgramContext
  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Store.ETS, as: ETSStore
  alias Dsxir.Test.Fixtures.RuntimeProgramPayloads

  @log_table :rp_construction_test_log

  setup_all do
    Code.ensure_loaded!(Dsxir.Test.Fixtures.AnswerQuestion)
    Code.ensure_loaded!(Dsxir.Predictor.Predict)
    _ = [:qa, :refine, :question, :answer, :required]
    :ok
  end

  setup do
    case :ets.info(@log_table) do
      :undefined -> :ets.new(@log_table, [:named_table, :public, :ordered_set])
      _ -> :ets.delete_all_objects(@log_table)
    end

    :ok
  end

  defp log_plug(tag) do
    fn _ctx ->
      idx = :ets.update_counter(@log_table, :counter, {2, 1}, {:counter, 0})
      :ets.insert(@log_table, {{:call, idx}, tag})
      :ok
    end
  end

  defp call_log do
    @log_table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{:call, _}, tag} -> [tag]
      _ -> []
    end)
  end

  test "program_plugs run in declared order on construction" do
    plug_a = log_plug(:a)
    plug_b = log_plug(:b)
    plug_c = log_plug(:c)

    Dsxir.context([program_plugs: [plug_a, plug_b, plug_c]], fn ->
      assert {:ok, %RuntimeProgram{}} =
               RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
    end)

    assert call_log() == [:a, :b, :c]
  end

  test "first halt wins; subsequent plugs do not run" do
    plug_a = log_plug(:a)
    halting = fn _ctx -> {:halt, :over_quota} end
    plug_c = log_plug(:c)

    err =
      assert_raise Halted.ProgramPlug, fn ->
        Dsxir.context([program_plugs: [plug_a, halting, plug_c]], fn ->
          RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
        end)
      end

    assert err.reason == :over_quota
    assert err.plug == halting
    assert %ProgramContext{runtime_program: %RuntimeProgram{}} = err.context

    assert call_log() == [:a]
  end

  test "validation errors surface before program_plugs run" do
    plug = fn _ctx -> flunk("plug must not run when validation fails") end

    bad_payload =
      RuntimeProgramPayloads.valid()
      |> Map.put("nodes", [
        %{
          "name" => "qa",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => "Elixir.Dsxir.Test.Fixtures.AnswerQuestion"
        },
        %{
          "name" => "qa",
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => "Elixir.Dsxir.Test.Fixtures.AnswerQuestion"
        }
      ])

    Dsxir.context([program_plugs: [plug]], fn ->
      assert {:error, %Invalid.RuntimeProgram{errors: errors}} =
               RuntimeProgram.from_map(bad_payload)

      assert Enum.any?(errors, &(&1.code == :duplicate_node_name))
    end)
  end

  test "from_map/2 with :store option persists the program via the store" do
    table = :rp_construction_store_table
    start_supervised!({ETSStore, name: :rp_construction_store, table: table})

    {:ok, rp} =
      RuntimeProgram.from_map(RuntimeProgramPayloads.valid(), store: {ETSStore, table})

    assert {:ok, fetched} = ETSStore.get(table, {rp.id, rp.version})
    assert fetched == rp
  end

  test "passing plugs let from_map return {:ok, rp}" do
    passing = fn _ctx -> :ok end

    Dsxir.context([program_plugs: [passing]], fn ->
      assert {:ok, %RuntimeProgram{id: "qa/valid"}} =
               RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
    end)
  end

  test "program_plugs is scoped via Dsxir.context and does not leak globally" do
    counter = :counters.new(1, [])
    plug = fn _ctx -> :counters.add(counter, 1, 1) end

    Dsxir.context([program_plugs: [plug]], fn ->
      assert {:ok, _} = RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
    end)

    assert :counters.get(counter, 1) == 1

    assert {:ok, _} = RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
    assert :counters.get(counter, 1) == 1
  end

  test "from_map/1 delegates to from_map/2 with empty opts" do
    assert {:ok, %RuntimeProgram{id: "qa/valid"}} =
             RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
  end

  defp fresh_atoms_payload(suffix) do
    node_name = "fresh_node_#{suffix}"
    input_name = "fresh_in_#{suffix}"
    output_name = "fresh_out_#{suffix}"
    sig_in = "fresh_sig_in_#{suffix}"
    sig_out = "fresh_sig_out_#{suffix}"

    payload = %{
      "id" => "fresh/program_#{suffix}",
      "inputs" => [%{"name" => input_name, "type" => "str"}],
      "outputs" => [%{"name" => output_name, "type" => "str"}],
      "nodes" => [
        %{
          "name" => node_name,
          "impl" => "Elixir.Dsxir.Predictor.Predict",
          "signature" => %{
            "fields" => [
              %{"name" => sig_in, "type" => "str", "kind" => "input"},
              %{"name" => sig_out, "type" => "str", "kind" => "output"}
            ]
          }
        }
      ],
      "edges" => [
        %{
          "from" => ["program_input", input_name],
          "to" => ["node", node_name, sig_in],
          "kind" => "required"
        },
        %{
          "from" => ["node", node_name, sig_out],
          "to" => ["program_output", output_name],
          "kind" => "required"
        }
      ],
      "metadata" => %{}
    }

    {payload, [node_name, input_name, output_name, sig_in, sig_out]}
  end

  test "from_map/2 with atoms: :create mints fresh node, field, and inline-signature field names" do
    suffix = System.unique_integer([:positive])
    {payload, fresh_names} = fresh_atoms_payload(suffix)

    for name <- fresh_names do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    assert_raise ArgumentError, fn -> RuntimeProgram.from_map(payload) end

    assert {:ok, %RuntimeProgram{}} = RuntimeProgram.from_map(payload, atoms: :create)
  end

  test "from_map/2 with atoms: :bogus raises ArgumentError" do
    assert_raise ArgumentError, fn ->
      RuntimeProgram.from_map(RuntimeProgramPayloads.valid(), atoms: :bogus)
    end
  end

  test "resolve_impl still rejects an unknown module string under atoms: :create" do
    ghost_impl = "Elixir.Dsxir.Test.Fixtures.GhostImpl#{System.unique_integer([:positive])}"
    payload = put_in(RuntimeProgramPayloads.valid(), ["nodes", Access.at(0), "impl"], ghost_impl)

    assert_raise ArgumentError, fn -> RuntimeProgram.from_map(payload, atoms: :create) end
  end

  test "from_map/2 with atoms: :create does not mint a fresh node opts key" do
    ghost_key = "ghost_opt_#{System.unique_integer([:positive])}"

    payload =
      put_in(RuntimeProgramPayloads.valid(), ["nodes", Access.at(0), "opts"], %{ghost_key => 1})

    assert_raise ArgumentError, fn -> RuntimeProgram.from_map(payload, atoms: :create) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(ghost_key) end
  end

  test "from_map/2 with atoms: :create does not mint a fresh signature module string" do
    ghost_sig =
      "Elixir.Dsxir.Test.Fixtures.GhostSignature#{System.unique_integer([:positive])}"

    payload =
      put_in(RuntimeProgramPayloads.valid(), ["nodes", Access.at(0), "signature"], ghost_sig)

    assert_raise ArgumentError, fn -> RuntimeProgram.from_map(payload, atoms: :create) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(ghost_sig) end
  end

  test "plug raising an exception is wrapped in %Halted.ProgramPlug{}" do
    raising_plug = fn _ctx -> raise "boom from a plug" end

    err =
      assert_raise Halted.ProgramPlug, fn ->
        Dsxir.context([program_plugs: [raising_plug]], fn ->
          RuntimeProgram.from_map(RuntimeProgramPayloads.valid())
        end)
      end

    assert err.plug == raising_plug
    assert {:plug_exception, message} = err.reason
    assert message =~ "boom from a plug"
    assert %ProgramContext{runtime_program: %RuntimeProgram{}} = err.context
  end
end
