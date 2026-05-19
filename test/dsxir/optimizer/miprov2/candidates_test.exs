defmodule Dsxir.Optimizer.MIPROv2.CandidatesTest do
  use ExUnit.Case, async: true
  alias Dsxir.Optimizer.MIPROv2.Candidates

  test "produces N+1 instruction indices and 2K+1 demo indices per predictor" do
    c =
      Candidates.build(
        %{a: "current"},
        %{a: ["i1", "i2", "i3"]},
        %{a: [[:b1], [:b2], [:b3], [:b4]]}
      )

    assert c.space[{:a, :instruction}] == {:categorical, [0, 1, 2, 3]}
    assert c.space[{:a, :demos}] == {:categorical, [0, 1, 2, 3, 4]}
  end

  test "index 0 always resolves to the baseline" do
    c =
      Candidates.build(
        %{a: "current"},
        %{a: ["i1"]},
        %{a: [[:demo]]}
      )

    resolved = Candidates.resolve(c, %{{:a, :instruction} => 0, {:a, :demos} => 0})
    assert resolved.a.instruction == "current"
    assert resolved.a.demos == []
  end

  test "non-zero indices resolve to proposed values" do
    c =
      Candidates.build(
        %{a: "current"},
        %{a: ["i1", "i2"]},
        %{a: [[:demo_set_1], [:demo_set_2]]}
      )

    resolved = Candidates.resolve(c, %{{:a, :instruction} => 2, {:a, :demos} => 1})
    assert resolved.a.instruction == "i2"
    assert resolved.a.demos == [:demo_set_1]
  end

  describe "Inspect" do
    test "renders compact tag with dim and predictor counts" do
      c =
        Candidates.build(
          %{a: "ca", b: "cb"},
          %{a: ["i1"], b: ["i1"]},
          %{a: [[:d1]], b: [[:d1]]}
        )

      assert inspect(c) == "#Dsxir.Optimizer.MIPROv2.Candidates<dims: 4, predictors: 2>"
    end

    test "does not dump the lookup table" do
      c = Candidates.build(%{a: "ca"}, %{a: ["i1"]}, %{a: [[:d1]]})
      refute inspect(c) =~ "lookup"
    end
  end
end
