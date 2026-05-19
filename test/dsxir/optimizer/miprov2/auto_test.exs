defmodule Dsxir.Optimizer.MIPROv2.AutoTest do
  use ExUnit.Case, async: true
  alias Dsxir.Optimizer.MIPROv2.Auto

  test "presets match the design spec exactly" do
    assert Auto.preset(:light).num_trials == 6
    assert Auto.preset(:light).num_instruction_candidates == 3
    assert Auto.preset(:light).num_demo_sets == 2
    assert Auto.preset(:light).minibatch_size == 25

    assert Auto.preset(:medium).num_trials == 18
    assert Auto.preset(:medium).minibatch_size == 25

    assert Auto.preset(:heavy).num_trials == 42
    assert Auto.preset(:heavy).minibatch_size == 50
  end

  test "expand/2 fills missing keys but never overrides user values" do
    opts = [num_trials: 99]
    expanded = Auto.expand(opts, :medium)
    assert Keyword.get(expanded, :num_trials) == 99
    assert Keyword.get(expanded, :minibatch_size) == 25
  end
end
