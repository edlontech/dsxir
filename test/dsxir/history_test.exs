defmodule Dsxir.HistoryTest do
  use ExUnit.Case, async: false

  alias Dsxir.History
  alias Dsxir.Telemetry

  setup do
    :ets.delete_all_objects(History.table())
    History.disable()

    on_exit(fn ->
      History.disable()
      :ets.delete_all_objects(History.table())
    end)

    :ok
  end

  defp emit_stop(extra_meas \\ %{}, extra_meta \\ %{}) do
    measurements =
      Map.merge(
        %{duration: 1_000, tokens_in: 10, tokens_out: 20, cost: 0.001},
        extra_meas
      )

    metadata =
      Map.merge(
        %{
          predictor: Dsxir.Predictor.Predict,
          signature: SomeSignature,
          adapter: Dsxir.Adapter.Chat,
          prediction: %{answer: "42"},
          error_class: nil
        },
        extra_meta
      )

    Telemetry.emit(Telemetry.predictor_stop(), measurements, metadata)
  end

  describe "enable/0 + last/1" do
    test "captures predictor stop events newest-first" do
      :ok = History.enable()

      emit_stop(%{}, %{tenant_id: "t1"})
      emit_stop(%{}, %{tenant_id: "t2"})
      emit_stop(%{}, %{tenant_id: "t3"})

      rows = History.last(3)

      assert [
               %{metadata: %{tenant_id: "t3"}, adapter: Dsxir.Adapter.Chat, tokens_in: 10},
               %{metadata: %{tenant_id: "t2"}},
               %{metadata: %{tenant_id: "t1"}}
             ] = rows
    end

    test "metadata excludes structured top-level keys" do
      :ok = History.enable()
      emit_stop(%{}, %{tenant_id: "abc"})

      assert [row] = History.last(1)

      refute Map.has_key?(row.metadata, :predictor)
      refute Map.has_key?(row.metadata, :signature)
      refute Map.has_key?(row.metadata, :adapter)
      refute Map.has_key?(row.metadata, :prediction)
      refute Map.has_key?(row.metadata, :error_class)
      assert row.metadata.tenant_id == "abc"
    end

    test "last/0-with-zero returns empty list" do
      :ok = History.enable()
      emit_stop()
      assert [] = History.last(0)
    end
  end

  describe "last/2 :file" do
    @tag :tmp_dir
    test "dumps entries as JSON lines", %{tmp_dir: tmp_dir} do
      :ok = History.enable()
      emit_stop(%{}, %{tenant_id: "x"})
      emit_stop(%{}, %{tenant_id: "y"})

      path = Path.join(tmp_dir, "history.jsonl")
      rows = History.last(2, file: path)

      assert [%{metadata: %{tenant_id: "y"}}, %{metadata: %{tenant_id: "x"}}] = rows

      contents = File.read!(path)
      lines = String.split(contents, "\n", trim: true)
      assert length(lines) == 2
      assert [{:ok, _} | _] = Enum.map(lines, &Jason.decode/1)
    end
  end

  describe "enable/0 idempotency" do
    test "double enable is safe" do
      assert :ok = History.enable()
      assert :ok = History.enable()

      emit_stop()
      assert [_one] = History.last(10)
    end
  end

  describe "disable/0" do
    test "detaches handler so stop events do not land" do
      :ok = History.enable()
      :ok = History.disable()

      emit_stop()
      assert [] = History.last(10)
    end

    test "double disable is safe" do
      assert :ok = History.disable()
      assert :ok = History.disable()
    end
  end

  describe "cost tracking" do
    test "captures the Cost struct and expanded token measurements" do
      :ok = History.enable()

      cost = %Dsxir.Cost{
        input_tokens: 10,
        output_tokens: 20,
        cache_read_tokens: 4,
        total_cost: 0.001,
        calls: 1
      }

      Telemetry.emit(
        Telemetry.predictor_stop(),
        %{
          duration: 1,
          tokens_in: 10,
          tokens_out: 20,
          cache_read_tokens: 4,
          cache_write_tokens: nil,
          reasoning_tokens: nil,
          cost: 0.001
        },
        %{
          predictor: Dsxir.Predictor.Predict,
          signature: SomeSignature,
          adapter: Dsxir.Adapter.Chat,
          prediction: %{},
          error_class: nil,
          cost: cost,
          _cost_scope: []
        }
      )

      assert [%{source: :predictor, cost_breakdown: ^cost, cache_read_tokens: 4}] =
               History.last(1)
    end

    test "captures embed events with source :embed and model" do
      :ok = History.enable()

      cost = %Dsxir.Cost{input_tokens: 4, total_cost: 0.0002, calls: 1}

      Telemetry.emit(
        Telemetry.lm_embed_stop(),
        %{
          duration: 1,
          tokens_in: 4,
          tokens_out: nil,
          cache_read_tokens: nil,
          cache_write_tokens: nil,
          reasoning_tokens: nil,
          cost: 0.0002
        },
        %{model: "embed-model", cost: cost, _cost_scope: []}
      )

      assert [%{source: :embed, model: "embed-model", cost_breakdown: ^cost, tokens_in: 4}] =
               History.last(1)
    end
  end

  describe "counter-driven trim" do
    setup do
      prior = Application.get_env(:dsxir, Dsxir.History, [])
      Application.put_env(:dsxir, Dsxir.History, max_history_size: 100, trim_batch_size: 16)

      :ok = Supervisor.terminate_child(Dsxir.Supervisor, Dsxir.History)
      {:ok, _pid} = Supervisor.restart_child(Dsxir.Supervisor, Dsxir.History)

      on_exit(fn ->
        Application.put_env(:dsxir, Dsxir.History, prior)
        :ok = Supervisor.terminate_child(Dsxir.Supervisor, Dsxir.History)
        {:ok, _} = Supervisor.restart_child(Dsxir.Supervisor, Dsxir.History)
      end)

      :ok
    end

    test "keeps table bounded under sustained concurrent inserts" do
      :ok = History.enable()

      1..200
      |> Task.async_stream(
        fn i -> emit_stop(%{}, %{tenant_id: "t#{i}"}) end,
        max_concurrency: 16,
        ordered: false
      )
      |> Stream.run()

      size = :ets.info(History.table(), :size)
      assert size >= 100 - 16
      assert size <= 100 + 16
    end
  end
end
