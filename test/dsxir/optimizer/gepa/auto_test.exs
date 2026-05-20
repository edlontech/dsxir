defmodule Dsxir.Optimizer.GEPA.AutoTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Auto

  test "light preset has expected shape" do
    cfg = Auto.expand([], :light)
    assert cfg.num_trials == 20
    assert cfg.operator_weights.mutate_instr == 0.7
    assert cfg.devset_fraction == 0.3
  end

  test "user opts override preset" do
    cfg = Auto.expand([num_trials: 5, seed: 42], :medium)
    assert cfg.num_trials == 5
    assert cfg.seed == 42
    assert cfg.devset_fraction == 0.3
  end

  test ":auto and :reflective_lm are dropped from user merge" do
    cfg = Auto.expand([auto: :light, reflective_lm: {Some, []}], :light)
    refute Map.has_key?(cfg, :auto)
    refute Map.has_key?(cfg, :reflective_lm)
  end
end
