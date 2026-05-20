defmodule Dsxir.Optimizer.GEPASettingsTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Metric.ScoreWithFeedback
  alias Dsxir.OptimizerSession

  setup :set_mimic_global

  setup do
    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  def forward_event(_event, _meas, meta, test_pid) do
    send(test_pid, {:session_trial, meta})
  end

  defmodule MTSig do
    use Dsxir.Signature

    signature do
      instruction("Echo.")
      input(:x, :string)
      output(:y, :string)
    end
  end

  defmodule MTProbe do
    use Dsxir.Module

    predictor(:p, Dsxir.Predictor.Predict, signature: MTSig)

    def forward(prog, %{x: x}) do
      {prog, r} = call(prog, :p, %{x: x})
      {prog, r}
    end
  end

  test "tenant_id propagates through OptimizerSession telemetry when running GEPA" do
    Mimic.copy(Dsxir.LM.Sycophant)
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:ok, "rewrite", %{}} end)

    Mimic.copy(Dsxir.Program)

    Mimic.stub(Dsxir.Program, :forward, fn p, %{x: x} ->
      {p, %Dsxir.Prediction{fields: %{y: "y_#{x}"}}}
    end)

    test_pid = self()
    handler_id = "gepa-mt-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:dsxir, :optimizer_session, :trial],
      &__MODULE__.forward_event/4,
      test_pid
    )

    program = Dsxir.Program.new(MTProbe)

    trainset =
      for i <- 1..4 do
        %Dsxir.Example{
          data: %{x: "x_#{i}", y: "y_x_#{i}"},
          input_keys: MapSet.new([:x])
        }
      end

    metric = fn ex, pred, _trace ->
      y = Map.get(pred.fields, :y)

      %ScoreWithFeedback{
        score: if(y == ex.data.y, do: 1.0, else: 0.0),
        feedback: nil
      }
    end

    try do
      Dsxir.context(
        [lm: {Dsxir.LM.Sycophant, [model: "stub"]}, metadata: %{tenant_id: "t-42"}],
        fn ->
          {:ok, _compiled, _stats} =
            OptimizerSession.compile(Dsxir.Optimizer.GEPA, program, trainset, metric,
              auto: :light,
              num_trials: 2,
              reflective_lm: {Dsxir.LM.Sycophant, [model: "stub"]}
            )
        end
      )

      assert_receive {:session_trial, %{tenant_id: "t-42"}}, 5_000
    after
      :telemetry.detach(handler_id)
    end
  end
end
