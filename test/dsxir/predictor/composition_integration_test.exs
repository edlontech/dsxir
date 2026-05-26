defmodule Dsxir.Predictor.CompositionIntegrationTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Predictor.BestOfN
  alias Dsxir.Predictor.Refine
  alias Dsxir.Program

  setup :set_mimic_global

  setup do
    Mimic.copy(Program)
    Mimic.copy(Dsxir.Predictor.Refine.Feedback)
    :ok
  end

  defp stub_prog,
    do: %Program{
      source: %Program.Source.Module{module: Elixir.Nonexistent},
      predictors: %{answer: %Program.State{}}
    }

  describe "multi-tenant telemetry" do
    test "every BestOfN attempt event carries the scoped tenant_id" do
      {:ok, scores} = Agent.start_link(fn -> [0.1, 0.8, 0.4] end)

      stub(Program, :forward, fn p, _inputs, _opts ->
        s = Agent.get_and_update(scores, fn [h | t] -> {h, t} end)
        {p, %Prediction{fields: %{score: s}}}
      end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:dsxir, :predictor, :best_of_n, :attempt]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      Dsxir.context([metadata: %{tenant_id: "t-7"}], fn ->
        BestOfN.run(
          stub_prog(),
          %{},
          fn _i, %Prediction{fields: %{score: s}} -> s end,
          n: 3,
          threshold: nil
        )
      end)

      attempts = drain_attempts(ref, [:dsxir, :predictor, :best_of_n, :attempt])

      assert length(attempts) == 3

      for {_event, _measurements, meta} <- attempts do
        assert meta.tenant_id == "t-7"
      end
    end

    test "every Refine attempt event carries the scoped tenant_id" do
      {:ok, scores} = Agent.start_link(fn -> [0.2, 0.95] end)

      stub(Program, :forward, fn p, _inputs, _opts ->
        s = Agent.get_and_update(scores, fn [h | t] -> {h, t} end)
        {p, %Prediction{fields: %{score: s}}}
      end)

      stub(Dsxir.Predictor.Refine.Feedback, :advise, fn _prog,
                                                        _inputs,
                                                        _pred,
                                                        _reward,
                                                        _trace,
                                                        _opts ->
        %{answer: "cite the source"}
      end)

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:dsxir, :predictor, :refine, :attempt]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      Dsxir.context([metadata: %{tenant_id: "t-7"}], fn ->
        Refine.run(
          stub_prog(),
          %{q: "x"},
          fn _i, %Prediction{fields: %{score: s}} -> s end,
          n: 3,
          threshold: 0.9
        )
      end)

      attempts = drain_attempts(ref, [:dsxir, :predictor, :refine, :attempt])

      assert length(attempts) == 2

      for {_event, _measurements, meta} <- attempts do
        assert meta.tenant_id == "t-7"
      end
    end
  end

  defmodule ProbeQA do
    @moduledoc false
    use Dsxir.Module

    predictor :draft, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
    predictor :polish, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

    def forward(prog, %{question: q}) do
      {prog, draft} = call(prog, :draft, %{question: q})
      call(prog, :polish, %{question: draft.fields.answer})
    end
  end

  describe "real-LM composition" do
    @describetag :integration

    defp non_empty_reward(_inputs, %Prediction{fields: fields}) do
      answer = Map.get(fields, :answer, "")

      if is_binary(answer) and answer != "" do
        1.0
      else
        0.0
      end
    end

    test "BestOfN over a 2-predictor program returns a prediction and a numeric best_reward" do
      api_key = System.fetch_env!("OPENAI_API_KEY")

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:dsxir, :predictor, :best_of_n, :stop]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      Dsxir.Settings.context(
        [lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini", api_key: api_key]}],
        fn ->
          assert {%Program{}, %Prediction{}} =
                   BestOfN.run(
                     Dsxir.Program.new(ProbeQA),
                     %{question: "What is the capital of France?"},
                     &non_empty_reward/2,
                     n: 3,
                     threshold: 1.0
                   )
        end
      )

      assert_received {[:dsxir, :predictor, :best_of_n, :stop], ^ref, %{best_reward: best_reward},
                       _}

      assert is_number(best_reward)
    end

    test "Refine over a 2-predictor program returns a prediction and a numeric best_reward" do
      api_key = System.fetch_env!("OPENAI_API_KEY")

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:dsxir, :predictor, :refine, :stop]
        ])

      on_exit(fn -> :telemetry.detach(ref) end)

      Dsxir.Settings.context(
        [lm: {Dsxir.LM.Sycophant, [model: "openai:gpt-4o-mini", api_key: api_key]}],
        fn ->
          assert {%Program{}, %Prediction{}} =
                   Refine.run(
                     Dsxir.Program.new(ProbeQA),
                     %{question: "What is the capital of France?"},
                     &non_empty_reward/2,
                     n: 3,
                     threshold: 1.0
                   )
        end
      )

      assert_received {[:dsxir, :predictor, :refine, :stop], ^ref, %{best_reward: best_reward}, _}
      assert is_number(best_reward)
    end
  end

  defp drain_attempts(ref, event, acc \\ []) do
    receive do
      {^event, ^ref, measurements, meta} ->
        drain_attempts(ref, event, [{event, measurements, meta} | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
