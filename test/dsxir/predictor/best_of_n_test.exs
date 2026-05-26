defmodule Dsxir.Predictor.BestOfNTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Prediction
  alias Dsxir.Predictor.BestOfN
  alias Dsxir.Program

  setup :set_mimic_global

  setup do
    Mimic.copy(Program)
    :ok
  end

  defp prog,
    do: %Program{source: %Program.Source.Module{module: Elixir.Nonexistent}, predictors: %{}}

  test "returns the best of n attempts and emits one attempt event each + one stop" do
    {:ok, agent} = Agent.start_link(fn -> [0.1, 0.8, 0.4] end)

    stub(Program, :forward, fn p, _i, _o ->
      s = Agent.get_and_update(agent, fn [h | t] -> {h, t} end)
      {p, %Prediction{fields: %{score: s}}}
    end)

    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:dsxir, :predictor, :best_of_n, :attempt],
        [:dsxir, :predictor, :best_of_n, :stop]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    assert {_p, %Prediction{fields: %{score: 0.8}}} =
             BestOfN.run(
               prog(),
               %{},
               fn _i, %Prediction{fields: %{score: s}} -> s end,
               n: 3,
               threshold: nil
             )

    assert_received {[:dsxir, :predictor, :best_of_n, :attempt], ^ref, _, _}
    assert_received {[:dsxir, :predictor, :best_of_n, :stop], ^ref, %{best_reward: 0.8}, _}
  end
end
