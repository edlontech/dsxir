defmodule Dsxir.Optimizer.GEPA.EvaluatorTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Metric.ScoreWithFeedback
  alias Dsxir.Optimizer.GEPA.Evaluator

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Program)
    :ok
  end

  defmodule FakeProgram do
    def forward(program, inputs),
      do: {program, %Dsxir.Prediction{} |> Map.put(:echo, inputs)}
  end

  defp ex(map),
    do: %Dsxir.Example{data: map, input_keys: MapSet.new(Map.keys(map))}

  test "scores and feedback aligned with devset order" do
    devset = [ex(%{i: 1}), ex(%{i: 2}), ex(%{i: 3})]

    metric = fn example, _pred, _trace ->
      i = example.data.i

      %ScoreWithFeedback{
        score: i / 3.0,
        feedback: %{p1: "feedback_#{i}"}
      }
    end

    program = %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}}

    Mimic.stub(Dsxir.Program, :forward, &FakeProgram.forward/2)

    {scores, feedback} = Evaluator.run(program, devset, metric, 2)
    assert length(scores) == 3
    assert length(feedback) == 3
    assert_in_delta List.first(scores), 1.0 / 3.0, 1.0e-9
    assert List.first(feedback) == %{p1: "feedback_1"}
  end

  test "per-example exception absorbed to nil in both arrays" do
    devset = [ex(%{i: 1}), ex(%{i: :boom}), ex(%{i: 3})]

    metric = fn example, _pred, _trace ->
      case example.data.i do
        :boom -> raise %Dsxir.Errors.LM.RateLimited{model_id: "test", retry_after: nil}
        i -> %ScoreWithFeedback{score: i / 3.0, feedback: nil}
      end
    end

    Mimic.stub(Dsxir.Program, :forward, &FakeProgram.forward/2)

    program = %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}}
    {scores, feedback} = Evaluator.run(program, devset, metric, 2)

    assert Enum.at(scores, 1) == nil
    assert Enum.at(feedback, 1) == nil
    assert Enum.at(scores, 0) != nil
    assert Enum.at(scores, 2) != nil
  end

  test "scalar metric (no feedback) produces nil feedback slot" do
    devset = [ex(%{i: 1}), ex(%{i: 2})]
    metric = fn _, _, _ -> 0.5 end

    Mimic.stub(Dsxir.Program, :forward, &FakeProgram.forward/2)

    program = %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}}
    {scores, feedback} = Evaluator.run(program, devset, metric, 2)
    assert scores == [0.5, 0.5]
    assert feedback == [nil, nil]
  end
end
