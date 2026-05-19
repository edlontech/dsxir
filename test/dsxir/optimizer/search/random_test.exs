defmodule Dsxir.Optimizer.Search.RandomTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.Search.Random

  describe "init/2" do
    test "produces a deterministic state under a fixed seed" do
      a = Random.init(%{x: {:categorical, [0, 1, 2, 3]}}, seed: 42)
      b = Random.init(%{x: {:categorical, [0, 1, 2, 3]}}, seed: 42)
      assert a == b
    end
  end

  describe "suggest/3" do
    test "returns n configs" do
      state = Random.init(%{x: {:categorical, [0, 1, 2]}}, seed: 1)
      {configs, _} = Random.suggest(state, [], 5)
      assert length(configs) == 5
      assert Enum.all?(configs, &Map.has_key?(&1, :x))
    end

    test "is approximately uniform over a 4-choice dimension (chi-square at p > 0.01)" do
      state = Random.init(%{x: {:categorical, [0, 1, 2, 3]}}, seed: 7)
      n = 10_000
      {configs, _} = Random.suggest(state, [], n)
      counts = Enum.frequencies_by(configs, & &1.x)
      expected = n / 4

      chi_sq =
        Enum.reduce(0..3, 0.0, fn k, acc ->
          observed = Map.get(counts, k, 0)
          acc + :math.pow(observed - expected, 2) / expected
        end)

      assert chi_sq < 11.34, "chi-square #{chi_sq} too high; sampler not uniform"
    end

    test "batched draws are independent (duplicates within a batch are possible)" do
      state = Random.init(%{x: {:categorical, [0, 1]}}, seed: 2)
      {configs, _} = Random.suggest(state, [], 100)
      values = Enum.map(configs, & &1.x)
      assert values |> Enum.uniq() |> Enum.sort() == [0, 1]
    end
  end

  describe "observe/2" do
    test "is a no-op" do
      state = Random.init(%{x: {:categorical, [0, 1]}}, seed: 3)
      same = Random.observe(state, [%{config: %{x: 0}, score: 1.0}])
      assert state == same
    end
  end

  describe "Inspect" do
    test "renders compact tag with dimension count" do
      state = Random.init(%{x: {:categorical, [0, 1]}, y: {:categorical, [0, 1]}}, seed: 1)
      assert inspect(state) == "#Dsxir.Optimizer.Search.Random<dims: 2>"
    end

    test "does not dump opaque rand_state" do
      state = Random.init(%{x: {:categorical, [0, 1]}}, seed: 1)
      rendered = inspect(state)
      refute rendered =~ "rand_state"
      refute rendered =~ "exsplus"
    end
  end
end
