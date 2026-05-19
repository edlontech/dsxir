defmodule Dsxir.Optimizer.Search.TPETest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.Search.TPE

  describe "cold start" do
    test "below cold_start_trials delegates to Random" do
      state = TPE.init(%{x: {:categorical, [0, 1, 2]}}, seed: 1, cold_start_trials: 10)
      {configs, _} = TPE.suggest(state, [], 5)
      assert length(configs) == 5
    end

    test "is deterministic under a fixed seed" do
      space = %{x: {:categorical, [0, 1, 2, 3]}}
      {c1, _} = TPE.init(space, seed: 7) |> TPE.suggest([], 3)
      {c2, _} = TPE.init(space, seed: 7) |> TPE.suggest([], 3)
      assert c1 == c2
    end
  end

  describe "engaged TPE" do
    test "concentrates on a known-good region after enough observations" do
      space = %{x: {:categorical, [0, 1, 2, 3]}, y: {:categorical, [0, 1, 2, 3]}}
      target = %{x: 3, y: 3}

      history =
        for i <- 0..3, j <- 0..3 do
          score = -(:math.pow(i - target.x, 2) + :math.pow(j - target.y, 2))
          %{config: %{x: i, y: j}, score: score}
        end

      state = TPE.init(space, seed: 11, cold_start_trials: 0, n_ei_candidates: 200)
      {suggestions, _} = TPE.suggest(state, history, 50)
      hits = Enum.count(suggestions, &(&1 == target))
      assert hits > 8, "expected TPE to favor target; only #{hits}/50 hits"
    end

    test "Laplace smoothing prevents zero probabilities" do
      space = %{x: {:categorical, [0, 1, 2]}}
      history = [%{config: %{x: 0}, score: 1.0}, %{config: %{x: 0}, score: 1.0}]
      state = TPE.init(space, seed: 13, cold_start_trials: 0, alpha: 1.0)
      {suggestions, _} = TPE.suggest(state, history, 100)
      values = MapSet.new(suggestions, & &1.x)
      assert MapSet.size(values) > 1, "smoothing should allow non-observed choices"
    end
  end

  describe "observe/2" do
    test "is a no-op (state rebuilt from history each suggest)" do
      state = TPE.init(%{x: {:categorical, [0, 1]}}, seed: 1)
      assert state == TPE.observe(state, [%{config: %{x: 0}, score: 0.5}])
    end
  end

  describe "Inspect" do
    test "renders compact tag with hyperparameters" do
      state =
        TPE.init(%{x: {:categorical, [0, 1, 2]}, y: {:categorical, [0, 1]}},
          seed: 1,
          gamma: 0.2,
          alpha: 1.0,
          n_ei_candidates: 24,
          cold_start_trials: 10
        )

      rendered = inspect(state)
      assert rendered =~ "#Dsxir.Optimizer.Search.TPE<"
      assert rendered =~ "dims: 2"
      assert rendered =~ "gamma: 0.2"
      assert rendered =~ "alpha: 1.0"
      assert rendered =~ "n_ei: 24"
      assert rendered =~ "cold_start: 10"
    end

    test "does not dump rand_state or random_delegate" do
      state = TPE.init(%{x: {:categorical, [0, 1]}}, seed: 1)
      rendered = inspect(state)
      refute rendered =~ "rand_state"
      refute rendered =~ "random_delegate"
    end
  end
end
