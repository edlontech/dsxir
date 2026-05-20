defmodule Dsxir.Optimizer.GEPA.FeedbackPool do
  @moduledoc """
  Samples reflective rollouts from a single individual's per-example score and
  feedback arrays. Returns up to K_success best-scoring entries and up to
  K_fail worst-scoring entries, skipping entries where feedback is nil.
  """

  alias Dsxir.Optimizer.GEPA.Individual

  @type rollout :: %{example_idx: non_neg_integer(), score: float(), feedback: term()}

  @doc """
  Returns up to `k_success` best-scoring rollouts and up to `k_fail`
  worst-scoring rollouts from `ind`, in insertion order with duplicates by
  `example_idx` removed. Entries with `nil` score or feedback are skipped.
  """
  @spec sample_rollouts(
          Individual.t(),
          k_success :: non_neg_integer(),
          k_fail :: non_neg_integer(),
          rng :: term()
        ) ::
          {[rollout()], rng :: term()}
  def sample_rollouts(%Individual{} = ind, k_success, k_fail, rng_state) do
    eligible =
      ind.scores
      |> Enum.zip(ind.feedback)
      |> Enum.with_index()
      |> Enum.reject(fn {{score, feedback}, _idx} -> is_nil(feedback) or is_nil(score) end)
      |> Enum.map(fn {{score, fb}, idx} ->
        %{example_idx: idx, score: score, feedback: fb}
      end)

    successes = eligible |> Enum.sort_by(& &1.score, :desc) |> Enum.take(k_success)
    failures = eligible |> Enum.sort_by(& &1.score, :asc) |> Enum.take(k_fail)

    {dedup_keep_order(successes ++ failures), rng_state}
  end

  defp dedup_keep_order(rollouts) do
    {_seen, kept} =
      Enum.reduce(rollouts, {MapSet.new(), []}, fn r, {seen, kept} ->
        if MapSet.member?(seen, r.example_idx) do
          {seen, kept}
        else
          {MapSet.put(seen, r.example_idx), [r | kept]}
        end
      end)

    Enum.reverse(kept)
  end
end
