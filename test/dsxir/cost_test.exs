defmodule Dsxir.CostTest do
  use ExUnit.Case, async: true

  alias Dsxir.Cost

  describe "zero/0" do
    test "is the additive identity with nil fields and zero calls" do
      assert %Cost{
               input_tokens: nil,
               output_tokens: nil,
               cache_read_tokens: nil,
               cache_write_tokens: nil,
               reasoning_tokens: nil,
               input_cost: nil,
               output_cost: nil,
               cache_read_cost: nil,
               cache_write_cost: nil,
               reasoning_cost: nil,
               total_cost: nil,
               currency: nil,
               calls: 0
             } = Cost.zero()
    end
  end

  describe "Inspect" do
    test "shows only populated token/cost fields and call count" do
      cost = %Cost{input_tokens: 1200, output_tokens: 340, total_cost: 0.0021, calls: 1}
      assert inspect(cost) == "#Dsxir.Cost<%{in: 1200, out: 340, cost: 0.0021, calls: 1}>"
    end

    test "omits nil fields" do
      assert inspect(%Cost{calls: 0}) == "#Dsxir.Cost<%{calls: 0}>"
    end

    test "omits currency and per-bucket costs for compactness" do
      cost = %Cost{input_tokens: 10, total_cost: 0.5, currency: "USD", input_cost: 0.2, calls: 1}
      rendered = inspect(cost)
      refute rendered =~ "USD"
      refute rendered =~ "input_cost"
      assert rendered == "#Dsxir.Cost<%{in: 10, cost: 0.5, calls: 1}>"
    end
  end

  describe "merge/2" do
    test "sums numeric fields and accumulates calls" do
      a = %Cost{input_tokens: 10, output_tokens: 5, total_cost: 0.001, currency: "USD", calls: 1}
      b = %Cost{input_tokens: 20, output_tokens: 7, total_cost: 0.002, currency: "USD", calls: 1}

      assert %Cost{
               input_tokens: 30,
               output_tokens: 12,
               total_cost: 0.003,
               currency: "USD",
               calls: 2
             } =
               Cost.merge(a, b)
    end

    test "treats nil as additive identity but keeps all-nil fields nil" do
      a = %Cost{input_tokens: 10, output_tokens: nil, total_cost: nil, calls: 1}
      b = %Cost{input_tokens: nil, output_tokens: 7, total_cost: nil, calls: 1}

      assert %Cost{input_tokens: 10, output_tokens: 7, total_cost: nil, calls: 2} =
               Cost.merge(a, b)
    end

    test "merging with zero/0 is identity" do
      a = %Cost{input_tokens: 10, total_cost: 0.001, calls: 1}
      assert Cost.merge(a, Cost.zero()) == a
      assert Cost.merge(Cost.zero(), a) == a
    end

    test "first non-nil currency wins" do
      a = %Cost{currency: nil, calls: 1}
      b = %Cost{currency: "USD", calls: 1}
      assert %Cost{currency: "USD"} = Cost.merge(a, b)
    end
  end

  describe "sum/1" do
    test "folds a list with zero/0 as the seed" do
      costs = [
        %Cost{input_tokens: 10, total_cost: 0.001, calls: 1},
        %Cost{input_tokens: 20, total_cost: 0.002, calls: 1},
        %Cost{input_tokens: 5, total_cost: 0.0005, calls: 1}
      ]

      assert %Cost{input_tokens: 35, total_cost: 0.0035, calls: 3} = Cost.sum(costs)
    end

    test "sum of empty list is zero/0" do
      assert Cost.sum([]) == Cost.zero()
    end

    test "first non-nil currency in the list wins, consistent with merge/2" do
      costs = [
        %Cost{currency: nil, calls: 1},
        %Cost{currency: "EUR", calls: 1},
        %Cost{currency: "USD", calls: 1}
      ]

      assert %Cost{currency: "EUR", calls: 3} = Cost.sum(costs)
    end
  end

  describe "to_measurements/1" do
    test "maps Cost fields onto the flat telemetry measurement keys" do
      cost = %Cost{
        input_tokens: 100,
        output_tokens: 50,
        cache_read_tokens: 10,
        cache_write_tokens: 5,
        reasoning_tokens: 3,
        total_cost: 0.01
      }

      assert %{
               tokens_in: 100,
               tokens_out: 50,
               cache_read_tokens: 10,
               cache_write_tokens: 5,
               reasoning_tokens: 3,
               cost: 0.01
             } = Cost.to_measurements(cost)
    end

    test "preserves nil values (no coercion to zero)" do
      assert %{tokens_in: nil, tokens_out: nil, cost: nil} = Cost.to_measurements(Cost.zero())
    end
  end
end
