defmodule Dsxir.PredictionTest do
  use ExUnit.Case, async: true

  test "new/1 stores fields and exposes Access" do
    pred = Dsxir.Prediction.new(%{answer: "42", confidence: 0.9})

    assert pred[:answer] == "42"
    assert pred.fields.confidence == 0.9
    assert get_in(pred, [:answer]) == "42"
  end

  test "Access.get_and_update/3 updates the fields map" do
    pred = Dsxir.Prediction.new(%{answer: "42"})
    {old, updated} = Access.get_and_update(pred, :answer, fn v -> {v, "43"} end)

    assert old == "42"
    assert updated[:answer] == "43"
  end

  test "lm_usage and completions ride alongside fields" do
    pred = Dsxir.Prediction.new(%{x: 1}, lm_usage: %{input_tokens: 10}, completions: ["raw"])
    assert pred.lm_usage == %{input_tokens: 10}
    assert pred.completions == ["raw"]
  end

  test "Access.pop/2 removes the key from fields" do
    pred = Dsxir.Prediction.new(%{answer: "42", confidence: 0.9})
    {popped, updated} = Access.pop(pred, :answer)

    assert popped == "42"
    refute Map.has_key?(updated.fields, :answer)
    assert updated.fields == %{confidence: 0.9}
  end

  test "Access.fetch/2 returns :error for unknown keys" do
    pred = Dsxir.Prediction.new(%{answer: "42"})

    assert Access.fetch(pred, :nonexistent) == :error
    assert pred[:nonexistent] == nil
  end
end
