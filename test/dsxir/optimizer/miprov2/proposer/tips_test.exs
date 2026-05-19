defmodule Dsxir.Optimizer.MIPROv2.Proposer.TipsTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.MIPROv2.Proposer.Tips

  describe "resolve/1" do
    test "returns nil for nil" do
      assert Tips.resolve(nil) == nil
    end

    test "resolves known atoms to non-empty strings" do
      for key <- [:persona, :creative, :simple, :concise] do
        value = Tips.resolve(key)
        assert is_binary(value)
        assert String.length(value) > 0
      end
    end

    test "returns nil for unknown atom" do
      assert Tips.resolve(:not_a_tip) == nil
    end

    test "passes binary strings through unchanged" do
      assert Tips.resolve("Be terse.") == "Be terse."
    end
  end
end
