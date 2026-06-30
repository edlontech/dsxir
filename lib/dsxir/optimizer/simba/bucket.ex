defmodule Dsxir.Optimizer.SIMBA.Bucket do
  @moduledoc """
  Per-example trajectory bucket with variance statistics.

  A bucket groups all trajectory records for one trainset example and computes
  gap statistics used to prioritise which examples are processed first during
  candidate generation.
  """

  @type trajectory_record :: %{
          score: float(),
          trace: list(),
          prediction: term(),
          example: term(),
          metadata: term()
        }

  @type t :: %{
          records: [trajectory_record()],
          max_to_min_gap: float(),
          max_score: float(),
          max_to_avg_gap: float()
        }

  @doc """
  Builds a bucket from a list of records for one example.

  Records are sorted by score descending. Three gap stats are computed:
  `max_to_min_gap`, `max_score`, and `max_to_avg_gap`.
  """
  @spec from_records([trajectory_record()]) :: t()
  def from_records(records) when records != [] do
    sorted = Enum.sort_by(records, & &1.score, :desc)
    scores = Enum.map(sorted, & &1.score)
    max_score = hd(sorted).score
    min_score = List.last(sorted).score
    avg_score = Enum.sum(scores) / length(scores)

    %{
      records: sorted,
      max_to_min_gap: max_score - min_score,
      max_score: max_score,
      max_to_avg_gap: max_score - avg_score
    }
  end

  @doc """
  Sorts a list of buckets descending by `{max_to_min_gap, max_score, max_to_avg_gap}`.

  Examples with more variance and a higher score ceiling are processed first.
  """
  @spec sort([t()]) :: [t()]
  def sort(buckets) do
    Enum.sort_by(
      buckets,
      fn b -> {b.max_to_min_gap, b.max_score, b.max_to_avg_gap} end,
      :desc
    )
  end

  @doc """
  Computes `{p10, p90}` over a flat list of numeric scores using
  linear interpolation (numpy-style).

  For percentile p over sorted xs of length n:
  rank = p/100 * (n-1); interpolate between floor and ceil indices.
  """
  @spec percentiles([number()]) :: {float(), float()}
  def percentiles(scores) do
    sorted = Enum.sort(scores)
    n = length(sorted)
    {lerp(sorted, n, 10), lerp(sorted, n, 90)}
  end

  defp lerp(sorted, n, p) do
    rank = p / 100 * (n - 1)
    lo = trunc(rank)
    hi = min(lo + 1, n - 1)
    frac = rank - lo
    Enum.at(sorted, lo) * (1.0 - frac) + Enum.at(sorted, hi) * frac
  end
end
