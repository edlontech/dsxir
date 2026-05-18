defmodule Dsxir.Retrieval.CosineTest do
  use ExUnit.Case, async: true

  alias Dsxir.Retrieval.Cosine

  test "identical vectors return 1.0" do
    assert Cosine.similarity([1.0, 0.0, 0.0], [1.0, 0.0, 0.0]) == 1.0
  end

  test "orthogonal vectors return 0.0" do
    assert Cosine.similarity([1.0, 0.0], [0.0, 1.0]) == 0.0
  end

  test "anti-parallel vectors return -1.0" do
    assert Cosine.similarity([1.0, 0.0], [-1.0, 0.0]) == -1.0
  end

  test "zero vector returns 0.0 (denominator guard)" do
    assert Cosine.similarity([0.0, 0.0], [1.0, 0.0]) == 0.0
    assert Cosine.similarity([1.0, 0.0], [0.0, 0.0]) == 0.0
  end

  test "length mismatch raises PredictorError with :vector_length_mismatch reason" do
    err =
      assert_raise Dsxir.Errors.Framework.PredictorError, fn ->
        Cosine.similarity([1.0, 0.0], [1.0, 0.0, 0.0])
      end

    assert err.reason == :vector_length_mismatch
    assert err.trajectory == %{lengths: {2, 3}}
  end
end
