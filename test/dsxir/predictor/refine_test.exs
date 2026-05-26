defmodule Dsxir.Predictor.RefineTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Predictor.Refine
  alias Dsxir.Program

  setup :set_mimic_global

  setup do
    Mimic.copy(Program)
    Mimic.copy(Dsxir.Predictor.Refine.Feedback)
    :ok
  end

  defp prog do
    %Program{
      source: %Program.Source.Module{module: Elixir.Nonexistent},
      predictors: %{answer: %Program.State{}}
    }
  end

  test "feeds advice into the next attempt and stops on threshold" do
    {:ok, scores} = Agent.start_link(fn -> [0.2, 0.95] end)
    {:ok, hints_seen} = Agent.start_link(fn -> [] end)

    stub(Program, :forward, fn p, _inputs, _opts ->
      h = Dsxir.Settings.resolve(:hints, %{})
      Agent.update(hints_seen, &[h | &1])
      s = Agent.get_and_update(scores, fn [head | t] -> {head, t} end)
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

    assert {_p, %Prediction{fields: %{score: 0.95}}} =
             Refine.run(prog(), %{q: "x"}, fn _i, %Prediction{fields: %{score: s}} -> s end,
               n: 3,
               threshold: 0.9
             )

    hints = Enum.reverse(Agent.get(hints_seen, & &1))
    assert [%{} = first, second] = hints
    assert map_size(first) == 0
    assert second == %{answer: "cite the source"}
  end

  test "no feedback when the first attempt already clears the threshold" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    stub(Program, :forward, fn p, _i, _o ->
      Agent.update(calls, &(&1 + 1))
      {p, %Prediction{fields: %{score: 0.99}}}
    end)

    reject(&Dsxir.Predictor.Refine.Feedback.advise/6)

    Refine.run(prog(), %{}, fn _i, %Prediction{fields: %{score: s}} -> s end,
      n: 3,
      threshold: 0.9
    )

    assert Agent.get(calls, & &1) == 1
  end
end
