defmodule Dsxir.Predictor.Refine.FeedbackTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Predictor.Refine.Feedback
  alias Dsxir.Program
  alias Dsxir.Trace.Entry

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)
    :ok
  end

  defp prog do
    %Program{
      source: %Program.Source.Module{module: Elixir.Nonexistent},
      predictors: %{extract: %Program.State{}, summarize: %Program.State{}}
    }
  end

  defp trace do
    [
      %Entry{predictor: :extract, inputs: %{}, prediction: %Prediction{fields: %{}}, demos: []},
      %Entry{predictor: :summarize, inputs: %{}, prediction: %Prediction{fields: %{}}, demos: []}
    ]
  end

  test "returns a map keyed by real predictor atoms, dropping unknown modules" do
    stub(Dsxir.Predictor.Predict, :forward, fn _state, _sig, _inputs, _opts ->
      {%Program.State{},
       %Prediction{
         fields: %{
           discussion: "...",
           advice: [
             %{"module" => "extract", "instruction" => "pull dates too"},
             %{"module" => "ghost", "instruction" => "ignored"}
           ]
         }
       }}
    end)

    advice =
      Feedback.advise(prog(), %{q: "x"}, %Prediction{fields: %{a: 1}}, 0.3, trace(),
        threshold: 0.9
      )

    assert advice == %{extract: "pull dates too"}
  end

  test "degrades to %{} when the feedback LM raises" do
    stub(Dsxir.Predictor.Predict, :forward, fn _s, _sig, _i, _o ->
      raise %Dsxir.Errors.LM.RateLimited{model_id: "m"}
    end)

    assert %{} ==
             Feedback.advise(prog(), %{}, %Prediction{fields: %{}}, 0.1, trace(), threshold: 0.9)
  end

  test "degrades to %{} when advice is missing or malformed" do
    stub(Dsxir.Predictor.Predict, :forward, fn _s, _sig, _i, _o ->
      {%Program.State{}, %Prediction{fields: %{discussion: "..."}}}
    end)

    assert %{} ==
             Feedback.advise(prog(), %{}, %Prediction{fields: %{}}, 0.1, trace(), threshold: 0.9)
  end

  test "handles advice entries with atom keys" do
    stub(Dsxir.Predictor.Predict, :forward, fn _s, _sig, _i, _o ->
      {%Program.State{},
       %Prediction{fields: %{advice: [%{module: "summarize", instruction: "tighten it"}]}}}
    end)

    advice = Feedback.advise(prog(), %{}, %Prediction{fields: %{}}, 0.2, trace(), threshold: 0.9)
    assert advice == %{summarize: "tighten it"}
  end

  test "degrades to %{} when the trace is malformed" do
    stub(Dsxir.Predictor.Predict, :forward, fn _s, _sig, _i, _o ->
      {%Program.State{}, %Prediction{fields: %{advice: []}}}
    end)

    assert %{} ==
             Feedback.advise(prog(), %{}, %Prediction{fields: %{}}, 0.1, [:not_an_entry],
               threshold: 0.9
             )
  end
end
