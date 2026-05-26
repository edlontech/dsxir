defmodule Dsxir.Predictor.Refine.OfferFeedbackTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predictor.Refine.OfferFeedback
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Runtime
  alias Dsxir.Trace.Entry

  test "signature/0 exposes the feedback I/O fields" do
    sig = OfferFeedback.signature()
    assert %Compiled{} = sig
    names = sig |> Runtime.fields() |> Enum.map(& &1.name)
    assert :program_inputs in names
    assert :program_trajectory in names
    assert :program_outputs in names
    assert :reward_value in names
    assert :target_threshold in names
    assert :module_names in names
    assert :discussion in names
    assert :advice in names
  end

  test "render_trajectory/1 lists predictor names and is a string" do
    trace = [
      %Entry{
        predictor: :extract,
        inputs: %{q: "a"},
        prediction: %Dsxir.Prediction{fields: %{x: 1}},
        demos: []
      },
      %Entry{
        predictor: :summarize,
        inputs: %{x: 1},
        prediction: %Dsxir.Prediction{fields: %{s: "y"}},
        demos: []
      }
    ]

    rendered = OfferFeedback.render_trajectory(trace)
    assert is_binary(rendered)
    assert rendered =~ "extract"
    assert rendered =~ "summarize"
  end

  test "module_names/1 returns the unique predictor names from the trace" do
    trace = [
      %Entry{
        predictor: :extract,
        inputs: %{},
        prediction: %Dsxir.Prediction{fields: %{}},
        demos: []
      },
      %Entry{
        predictor: :extract,
        inputs: %{},
        prediction: %Dsxir.Prediction{fields: %{}},
        demos: []
      },
      %Entry{
        predictor: :summarize,
        inputs: %{},
        prediction: %Dsxir.Prediction{fields: %{}},
        demos: []
      }
    ]

    assert OfferFeedback.module_names(trace) == ["extract", "summarize"]
  end
end
