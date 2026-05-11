defmodule Dsxir.Predictor.ParallelTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.Parallel
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.ThreePredictors

  setup :set_mimic_global

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "fans out three predictors and preserves settings scope in each worker" do
    stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:ok, "[[ ## answer ## ]]\nanswer-text", Dsxir.LM.empty_usage()}
    end)

    parent = self()
    handler_id = {__MODULE__, :tenant_propagation_handler}
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_stop(),
      fn _e, _meas, meta, _ -> send(parent, {:telemetry_stop, meta}) end,
      nil
    )

    Dsxir.Settings.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "stub"]},
        metadata: %{tenant_id: "t1"}
      ],
      fn ->
        prog = Program.new(ThreePredictors)

        {%Program{} = _prog2, results} =
          Parallel.run(prog, [
            {:a, %{question: "qa"}},
            {:b, %{question: "qb"}},
            {:c, %{question: "qc"}}
          ])

        assert [{:ok, _}, {:ok, _}, {:ok, _}] = results
      end
    )

    for _ <- 1..3 do
      assert_receive {:telemetry_stop, %{tenant_id: "t1"}}, 1000
    end
  end

  test "returns errors as {:error, exception} without raising" do
    stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:error, %Dsxir.Errors.LM.Authentication{model_id: "stub", reason: :nope}}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      prog = Program.new(ThreePredictors)

      {%Program{}, results} = Parallel.run(prog, [{:a, %{question: "qa"}}])

      assert [{:error, %Dsxir.Errors.LM.Authentication{}}] = results
    end)
  end

  test "preserves request ordering in the result list" do
    stub(Dsxir.LM.Sycophant, :generate_text, fn _config, msgs, _opts ->
      tag =
        msgs
        |> Enum.map_join(" ", &Map.get(&1, :content, ""))
        |> case do
          s when is_binary(s) ->
            cond do
              s =~ "qa" -> "a-answer"
              s =~ "qb" -> "b-answer"
              s =~ "qc" -> "c-answer"
              true -> "unknown"
            end
        end

      {:ok, "[[ ## answer ## ]]\n#{tag}", Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      prog = Program.new(ThreePredictors)

      {%Program{}, results} =
        Parallel.run(prog, [
          {:a, %{question: "qa"}},
          {:b, %{question: "qb"}},
          {:c, %{question: "qc"}}
        ])

      assert [
               {:ok, %Dsxir.Prediction{fields: %{answer: "a-answer"}}},
               {:ok, %Dsxir.Prediction{fields: %{answer: "b-answer"}}},
               {:ok, %Dsxir.Prediction{fields: %{answer: "c-answer"}}}
             ] = results
    end)
  end

  test "mismatched-name predictor surfaces as Invalid.Module in the result list" do
    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      prog = Program.new(ThreePredictors)

      {%Program{}, results} =
        Parallel.run(prog, [{:no_such_predictor, %{question: "x"}}])

      assert [{:error, %Dsxir.Errors.Invalid.Module{reason: :undeclared_predictor}}] = results
    end)
  end
end
