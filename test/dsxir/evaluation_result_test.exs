defmodule Dsxir.EvaluationResultTest do
  use ExUnit.Case, async: true

  alias Dsxir.EvaluationResult

  test "default struct has zeroed score and empty rows + errors" do
    r = %EvaluationResult{}
    assert r.score == 0.0
    assert r.results == []
    assert r.errors == %{count: 0, by_class: %{}, by_module: %{}, samples: []}
  end

  test "score_from averages and scales by 100, rounded to 1dp" do
    assert EvaluationResult.score_from([]) == 0.0
    assert EvaluationResult.score_from([1.0, 0.0]) == 50.0
    assert EvaluationResult.score_from([1.0, 1.0, 1.0]) == 100.0
    assert EvaluationResult.score_from([0.333, 0.667]) == 50.0
    assert EvaluationResult.score_from([0.123, 0.456, 0.789]) == 45.6
  end

  test "ok_row + error_row build well-shaped rows" do
    ex = Dsxir.Example.new(%{a: 1}, input_keys: [:a])
    pred = %Dsxir.Prediction{fields: %{a: 1}}
    err = %RuntimeError{message: "x"}

    assert %{example: ^ex, prediction: ^pred, metric: 0.5, error: nil} =
             EvaluationResult.ok_row(ex, pred, 0.5)

    assert %{example: ^ex, prediction: nil, metric: nil, error: ^err} =
             EvaluationResult.error_row(ex, err)
  end
end
