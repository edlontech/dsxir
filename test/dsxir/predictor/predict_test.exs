defmodule Dsxir.Predictor.PredictTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.Predict
  alias Dsxir.Test.Fixtures.AnswerQuestion

  setup :set_mimic_from_context

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "forward/4 returns a %Prediction{} from a stubbed LM" do
    markered = """
    [[ ## answer ## ]]
    A dynamic, functional language.
    """

    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:ok, markered}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      state = %Dsxir.Program.State{}

      {^state, prediction} =
        Predict.forward(state, AnswerQuestion, %{question: "What is Elixir?"}, [])

      assert %Dsxir.Prediction{} = prediction
      assert prediction[:answer] == "A dynamic, functional language."
    end)
  end

  test "forward/4 emits start/stop telemetry with predictor metadata" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\nx"}
    end)

    parent = self()
    handler_id = {__MODULE__, :start_stop_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach_many(
      handler_id,
      [
        Dsxir.Telemetry.predictor_start(),
        Dsxir.Telemetry.predictor_stop()
      ],
      fn event, meas, meta, _ -> send(parent, {:telemetry, event, meas, meta}) end,
      nil
    )

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
    end)

    assert_receive {:telemetry, [:dsxir, :predictor, :start], _,
                    %{
                      predictor: Dsxir.Predictor.Predict,
                      signature: AnswerQuestion,
                      adapter: Dsxir.Adapter.Chat
                    }}

    assert_receive {:telemetry, [:dsxir, :predictor, :stop], %{duration: _},
                    %{prediction: %Dsxir.Prediction{}, error_class: nil}}
  end

  test "forward/4 propagates settings.metadata into telemetry" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "[[ ## answer ## ]]\ny"}
    end)

    parent = self()
    handler_id = {__MODULE__, :metadata_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_stop(),
      fn _e, _m, meta, _ -> send(parent, {:telemetry, meta}) end,
      nil
    )

    Dsxir.Settings.context(
      [
        lm: {Dsxir.LM.Sycophant, [model: "stub"]},
        metadata: %{tenant_id: "t1"}
      ],
      fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "y"}, [])
      end
    )

    assert_receive {:telemetry, %{tenant_id: "t1"}}
  end

  test "forward/4 raises Adapter.ParseError when LM output has no markers" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:ok, "no markers here"} end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.Adapter.ParseError, fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
      end
    end)
  end

  test "forward/4 emits exception telemetry on parse error" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:ok, "no markers here"} end)

    parent = self()
    handler_id = {__MODULE__, :exception_handler}

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :telemetry.attach(
      handler_id,
      Dsxir.Telemetry.predictor_exception(),
      fn _e, _m, meta, _ -> send(parent, {:telemetry, meta}) end,
      nil
    )

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.Adapter.ParseError, fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
      end
    end)

    assert_receive {:telemetry, %{error_class: :adapter, kind: :error}}
  end

  test "forward/4 raises LM.Authentication when transport fails" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:error, %Dsxir.Errors.LM.Authentication{model_id: "stub", reason: :nope}}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      assert_raise Dsxir.Errors.LM.Authentication, fn ->
        Predict.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "x"}, [])
      end
    end)
  end
end
