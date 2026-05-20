defmodule Dsxir.Optimizer.GEPA.FeedbackPoolTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.FeedbackPool
  alias Dsxir.Optimizer.GEPA.Individual

  defp ind(scores, feedback) do
    delta = %Delta{
      instructions: %{a: "x"},
      demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}
    }

    Individual.new(delta, scores, feedback, [], :seed, 0)
  end

  test "K best + K worst, skipping nil feedback" do
    i =
      ind(
        [1.0, 0.9, 0.5, 0.1, 0.0],
        ["best", "second", nil, "worst-second", "worst"]
      )

    {rollouts, _} = FeedbackPool.sample_rollouts(i, 2, 2, :rand.seed_s(:exsplus, {1, 2, 3}))
    feedback_strings = Enum.map(rollouts, & &1.feedback)
    assert "best" in feedback_strings
    assert "second" in feedback_strings
    assert "worst" in feedback_strings
    assert "worst-second" in feedback_strings
    refute nil in feedback_strings
  end

  test "deduplicates by example_idx when best and worst overlap on a small array" do
    i = ind([1.0, 0.5], ["a", "b"])
    {rollouts, _} = FeedbackPool.sample_rollouts(i, 3, 3, :rand.seed_s(:exsplus, {1, 2, 3}))
    idx_list = Enum.map(rollouts, & &1.example_idx)
    assert Enum.uniq(idx_list) == idx_list
    assert length(rollouts) == 2
  end

  test "empty eligible set returns empty list" do
    i = ind([nil, nil], [nil, nil])
    {rollouts, _} = FeedbackPool.sample_rollouts(i, 4, 4, :rand.seed_s(:exsplus, {1, 2, 3}))
    assert rollouts == []
  end
end
