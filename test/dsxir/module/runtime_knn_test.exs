defmodule Dsxir.Module.RuntimeKnnTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.DemoStrategy.KNN
  alias Dsxir.DemoStrategy.KNN.Entry
  alias Dsxir.Module.Runtime
  alias Dsxir.Program

  setup :verify_on_exit!
  setup :set_mimic_from_context

  defmodule TestSig do
    use Dsxir.Signature

    signature do
      instruction("Say something.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  defmodule TestProg do
    use Dsxir.Module

    predictor(:qa, Dsxir.Predictor.Predict, signature: Dsxir.Module.RuntimeKnnTest.TestSig)

    def forward(prog, %{question: q}) do
      Runtime.call(prog, :qa, question: q)
    end
  end

  defp stub_predict_call do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      {:ok, "[[ ## answer ## ]]\nfine\n", Dsxir.LM.empty_usage()}
    end)
  end

  test "nil demo_strategy => behavior unchanged; demos remain the static list" do
    prog = Program.new(TestProg)
    state = Program.get_state(prog, :qa)
    static = [%Dsxir.Example{data: %{question: "old", answer: "old-a"}}]
    prog = Program.put_state(prog, :qa, %{state | demos: static})

    stub_predict_call()

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "x"]}, adapter: Dsxir.Adapter.Chat],
      fn ->
        {_prog, pred} = Runtime.call(prog, :qa, question: "hi")
        assert pred[:answer] == "fine"
      end
    )
  end

  test "demo_strategy set => resolve is called and demos flow to predictor" do
    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:ok, [[1.0, 0.0]], Dsxir.LM.empty_usage()}
    end)

    test_pid = self()

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, msgs, _opts ->
      send(test_pid, {:user_msg, msgs})
      {:ok, "[[ ## answer ## ]]\nfine\n", Dsxir.LM.empty_usage()}
    end)

    strategy = %KNN{
      k: 1,
      embedder: {Dsxir.LM.Sycophant, [model: "test-embed"]},
      embedder_id: "test-embed",
      embed_fields: :all,
      entries: [
        %Entry{
          embedding: [1.0, 0.0],
          example: %Dsxir.Example{data: %{question: "near", answer: "near-a"}}
        }
      ]
    }

    prog = Program.new(TestProg)
    state = Program.get_state(prog, :qa)
    prog = Program.put_state(prog, :qa, %{state | demos: [], demo_strategy: strategy})

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "x"]}, adapter: Dsxir.Adapter.Chat],
      fn ->
        {_prog, _pred} = TestProg.forward(prog, %{question: "hi"})
      end
    )

    assert_receive {:user_msg, msgs}
    user_blob = Enum.find_value(msgs, fn %{role: r, content: c} -> if r == :user, do: c end)
    assert user_blob =~ "near-a"
  end

  @tag :capture_log
  test "both demos and demo_strategy => warning event fires, strategy wins" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:dsxir, :knn, :unexpected_static_demos]])

    expect(Dsxir.LM.Sycophant, :embed, fn _cfg, _texts, _opts ->
      {:ok, [[1.0, 0.0]], Dsxir.LM.empty_usage()}
    end)

    stub_predict_call()

    strategy = %KNN{
      k: 1,
      embedder: {Dsxir.LM.Sycophant, [model: "test-embed"]},
      embedder_id: "test-embed",
      embed_fields: :all,
      entries: [
        %Entry{
          embedding: [1.0, 0.0],
          example: %Dsxir.Example{data: %{question: "near", answer: "near-a"}}
        }
      ]
    }

    static = [%Dsxir.Example{data: %{question: "old", answer: "old-a"}}]

    prog = Program.new(TestProg)
    state = Program.get_state(prog, :qa)
    prog = Program.put_state(prog, :qa, %{state | demos: static, demo_strategy: strategy})

    Dsxir.Settings.context(
      [lm: {Dsxir.LM.Sycophant, [model: "x"]}, adapter: Dsxir.Adapter.Chat],
      fn ->
        Runtime.call(prog, :qa, question: "hi")
      end
    )

    assert_receive {[:dsxir, :knn, :unexpected_static_demos], ^ref, _meas,
                    %{predictor: :qa, static_demo_count: 1}}
  end
end
