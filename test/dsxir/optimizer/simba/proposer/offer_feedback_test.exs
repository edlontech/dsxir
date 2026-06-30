defmodule Dsxir.Optimizer.SIMBA.Proposer.OfferFeedbackTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.SIMBA.Proposer.OfferFeedback
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Runtime
  alias Dsxir.Trace.Entry

  test "signature/0 exposes the contrastive feedback input fields" do
    sig = OfferFeedback.signature()
    assert %Compiled{} = sig

    fields = Runtime.fields(sig)
    inputs = fields |> Enum.filter(&(&1.kind == :input)) |> Enum.map(& &1.name)

    for name <- [
          :program_inputs,
          :oracle_metadata,
          :better_program_trajectory,
          :better_program_outputs,
          :better_reward_value,
          :better_reward_info,
          :worse_program_trajectory,
          :worse_program_outputs,
          :worse_reward_value,
          :worse_reward_info,
          :module_names
        ] do
      assert name in inputs
    end
  end

  test "signature/0 reward values are numbers and module_names is a list of strings" do
    by_name = OfferFeedback.signature() |> Runtime.fields() |> Map.new(&{&1.name, &1})

    assert by_name[:better_reward_value].type == :number
    assert by_name[:worse_reward_value].type == :number
    assert by_name[:module_names].type == {:list, :string}
  end

  test "signature/0 exposes discussion and advice output fields" do
    fields = OfferFeedback.signature() |> Runtime.fields()
    outputs = fields |> Enum.filter(&(&1.kind == :output)) |> Enum.map(& &1.name)

    assert :discussion in outputs
    assert :advice in outputs
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

  test "module_names/1 returns unique predictor names in first-seen order" do
    trace = [
      entry(:extract),
      entry(:extract),
      entry(:summarize)
    ]

    assert OfferFeedback.module_names(trace) == ["extract", "summarize"]
  end

  test "parse/1 builds a map from a string-keyed advice list" do
    advice = [
      %{"module" => "extract", "advice" => "be precise"},
      %{"module" => "summarize", "advice" => "be brief"}
    ]

    assert OfferFeedback.parse(advice) == %{
             "extract" => "be precise",
             "summarize" => "be brief"
           }
  end

  test "parse/1 builds a map from an atom-keyed advice list" do
    advice = [
      %{module: "extract", advice: "be precise"},
      %{module: "summarize", advice: "be brief"}
    ]

    assert OfferFeedback.parse(advice) == %{
             "extract" => "be precise",
             "summarize" => "be brief"
           }
  end

  test "parse/1 returns %{} on garbage without raising" do
    assert OfferFeedback.parse([]) == %{}
    assert OfferFeedback.parse(nil) == %{}
    assert OfferFeedback.parse("nope") == %{}
    assert OfferFeedback.parse([%{"x" => 1}, "junk", 42]) == %{}
    assert OfferFeedback.parse([%{"module" => "m"}]) == %{}
  end

  test "recursive_mask/1 masks non-serializable terms and preserves structures" do
    masked = OfferFeedback.recursive_mask(%{a: [1, "two", self()], b: %{c: 3}})

    assert %{a: [1, "two", placeholder], b: %{c: 3}} = masked
    assert placeholder =~ "<non-serializable: PID>"
  end

  test "recursive_mask/1 masks a function and recurses into tuples" do
    masked = OfferFeedback.recursive_mask({1, fn -> :x end, "ok"})

    assert {1, fn_placeholder, "ok"} = masked
    assert fn_placeholder =~ "<non-serializable: Function>"
  end

  defp entry(name) do
    %Entry{predictor: name, inputs: %{}, prediction: %Dsxir.Prediction{fields: %{}}, demos: []}
  end
end
