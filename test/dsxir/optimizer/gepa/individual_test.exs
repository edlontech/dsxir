defmodule Dsxir.Optimizer.GEPA.IndividualTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual

  defp delta do
    %Delta{instructions: %{a: "x"}, demo_bundle_refs: %{a: %{seed: 0, kind: :labeled}}}
  end

  test "id deterministic from {parent_ids, delta, generation}" do
    a = Individual.new(delta(), [1.0, 0.5], [nil, nil], [], :seed, 0)
    b = Individual.new(delta(), [0.9, 0.4], [nil, nil], [], :seed, 0)
    assert a.id == b.id
  end

  test "aggregated = mean of non-nil scores" do
    ind = Individual.new(delta(), [1.0, nil, 0.5, 0.0], [nil, nil, nil, nil], [], :seed, 0)
    assert_in_delta ind.aggregated, 0.5, 1.0e-9
  end

  test "all-nil scores then aggregated is nil" do
    ind = Individual.new(delta(), [nil, nil], [nil, nil], [], :seed, 0)
    assert ind.aggregated == nil
  end

  test "scores/feedback length mismatch raises" do
    assert_raise FunctionClauseError, fn ->
      Individual.new(delta(), [1.0, 0.5], [nil], [], :seed, 0)
    end
  end
end
