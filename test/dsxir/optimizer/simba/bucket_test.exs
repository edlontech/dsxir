defmodule Dsxir.Optimizer.SIMBA.BucketTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.SIMBA.Bucket

  defp record(score), do: %{score: score, trace: [], prediction: nil, example: nil, metadata: nil}

  describe "from_records/1" do
    test "sorts records by score descending" do
      records = [record(0.3), record(0.8), record(0.5)]
      bucket = Bucket.from_records(records)
      assert Enum.map(bucket.records, & &1.score) == [0.8, 0.5, 0.3]
    end

    test "computes max_score" do
      bucket = Bucket.from_records([record(0.3), record(0.8), record(0.5)])
      assert bucket.max_score == 0.8
    end

    test "computes max_to_min_gap" do
      bucket = Bucket.from_records([record(0.3), record(0.8), record(0.5)])
      assert_in_delta bucket.max_to_min_gap, 0.5, 1.0e-9
    end

    test "computes max_to_avg_gap" do
      bucket = Bucket.from_records([record(0.3), record(0.8), record(0.5)])
      avg = (0.3 + 0.8 + 0.5) / 3
      assert_in_delta bucket.max_to_avg_gap, 0.8 - avg, 1.0e-9
    end

    test "single-record bucket has zero gaps" do
      bucket = Bucket.from_records([record(0.7)])
      assert bucket.max_score == 0.7
      assert bucket.max_to_min_gap == 0.0
      assert bucket.max_to_avg_gap == 0.0
    end
  end

  describe "sort/1" do
    test "orders buckets descending by {max_to_min_gap, max_score, max_to_avg_gap}" do
      b1 = Bucket.from_records([record(0.5), record(0.3)])
      b2 = Bucket.from_records([record(0.9), record(0.1)])
      b3 = Bucket.from_records([record(0.6), record(0.1)])

      sorted = Bucket.sort([b1, b2, b3])

      assert Enum.map(sorted, & &1.max_score) == [0.9, 0.6, 0.5]
    end

    test "breaks tie on max_to_min_gap by max_score desc" do
      same_gap_high = Bucket.from_records([record(0.9), record(0.4)])
      same_gap_low = Bucket.from_records([record(0.6), record(0.1)])

      [first | _] = Bucket.sort([same_gap_low, same_gap_high])
      assert first.max_score == 0.9
    end
  end

  describe "percentiles/1" do
    test "p10 and p90 with linear interpolation on [0..9]" do
      scores = Enum.map(0..9, &(&1 * 1.0))
      {p10, p90} = Bucket.percentiles(scores)
      assert_in_delta p10, 0.9, 1.0e-9
      assert_in_delta p90, 8.1, 1.0e-9
    end

    test "linear interpolation on odd-length list [1..5]" do
      scores = [1.0, 2.0, 3.0, 4.0, 5.0]
      {p10, p90} = Bucket.percentiles(scores)
      assert_in_delta p10, 1.4, 1.0e-9
      assert_in_delta p90, 4.6, 1.0e-9
    end

    test "unsorted input is sorted before interpolation" do
      scores = [9.0, 0.0, 3.0, 6.0]
      {p10, _p90} = Bucket.percentiles(scores)
      sorted = [0.0, 3.0, 6.0, 9.0]
      n = 4
      expected_p10_rank = 0.1 * (n - 1)
      lo = trunc(expected_p10_rank)
      frac = expected_p10_rank - lo
      expected_p10 = Enum.at(sorted, lo) * (1 - frac) + Enum.at(sorted, lo + 1) * frac
      assert_in_delta p10, expected_p10, 1.0e-9
    end
  end
end
