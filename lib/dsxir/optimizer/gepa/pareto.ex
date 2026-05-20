defmodule Dsxir.Optimizer.GEPA.Pareto do
  @moduledoc """
  Per-example Pareto frontier and parent selection for GEPA.

  Dominance is over the per-example score axis. `nil` slots (a failed
  evaluation on that example) act as `-:infinity` so an individual that errors
  on any example is strictly worse than any non-erroring competitor on that
  axis.
  """

  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Population

  @spec dominates?(Individual.t(), Individual.t()) :: boolean()
  def dominates?(%Individual{scores: a}, %Individual{scores: b})
      when length(a) == length(b) do
    do_dominate(a, b, false)
  end

  defp do_dominate([], [], strict?), do: strict?

  defp do_dominate([sa | ra], [sb | rb], strict?) do
    case compare(sa, sb) do
      :less -> false
      :equal -> do_dominate(ra, rb, strict?)
      :greater -> do_dominate(ra, rb, true)
    end
  end

  defp compare(nil, nil), do: :equal
  defp compare(nil, _), do: :less
  defp compare(_, nil), do: :greater
  defp compare(a, b) when a < b, do: :less
  defp compare(a, b) when a > b, do: :greater
  defp compare(_, _), do: :equal

  @doc """
  Returns the list of individual ids that are best on at least one devset
  example. Ties are broken by birth order (oldest wins, deterministic).
  """
  @spec frontier(Population.t()) :: [Individual.id()]
  def frontier(%Population{} = pop) do
    inds = Population.to_list(pop)

    case inds do
      [] -> []
      [only] -> [only.id]
      [first | _] -> per_example_winners(inds, length(first.scores))
    end
  end

  defp per_example_winners(inds, devset_size) do
    0..(devset_size - 1)
    |> Enum.map(&winner_for_example(inds, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp winner_for_example(inds, i) do
    inds
    |> Enum.reduce({nil, nil}, fn ind, {best_id, best_score} ->
      score = Enum.at(ind.scores, i)

      case {best_score, score} do
        {_, nil} -> {best_id, best_score}
        {nil, _} -> {ind.id, score}
        {bs, s} when s > bs -> {ind.id, s}
        _ -> {best_id, best_score}
      end
    end)
    |> elem(0)
  end

  @doc """
  Same as `frontier/1` but answers whether `candidate` would join when added.
  Computes a synthetic frontier including `candidate` against `pop`'s current
  members and checks membership.
  """
  @spec would_join_frontier?(Population.t(), Individual.t()) :: boolean()
  def would_join_frontier?(%Population{} = pop, %Individual{} = candidate) do
    synthetic = Population.add(pop, candidate)
    candidate.id in frontier(synthetic)
  end

  @doc """
  Weighted random parent: weight ∝ number of devset examples this individual
  is best on. Falls back to uniform sample from `frontier_ids` if all weights
  are zero (impossible by construction but defensive).
  """
  @spec select_parent(Population.t(), [Individual.id()], rng :: term()) ::
          {Individual.t(), rng :: term()}
  def select_parent(%Population{} = pop, frontier_ids, rng_state) when frontier_ids != [] do
    weights = coverage(pop, frontier_ids)
    {chosen_id, rng2} = weighted_pick(frontier_ids, weights, rng_state)
    {Population.by_id(pop, chosen_id), rng2}
  end

  defp coverage(pop, frontier_ids) do
    inds = Population.to_list(pop)
    devset_size = inds |> List.first() |> Map.fetch!(:scores) |> length()

    Enum.map(frontier_ids, fn id ->
      Enum.count(0..(devset_size - 1), fn i ->
        winner_for_example(inds, i) == id
      end)
    end)
  end

  defp weighted_pick(ids, weights, rng_state) do
    total = Enum.sum(weights)
    {r, rng2} = :rand.uniform_s(rng_state)
    chosen = pick_by_weight(ids, weights, total, r)
    {chosen, rng2}
  end

  defp pick_by_weight(ids, _weights, total, r) when total <= 0 do
    idx = min(trunc(r * length(ids)), length(ids) - 1)
    Enum.at(ids, idx)
  end

  defp pick_by_weight(ids, weights, total, r) do
    target = r * total

    {pick, _} =
      ids
      |> Enum.zip(weights)
      |> Enum.reduce_while({nil, 0.0}, &step_weighted(&1, &2, target))

    pick
  end

  defp step_weighted({id, w}, {_prev, acc}, target) do
    new_acc = acc + w
    if new_acc >= target, do: {:halt, {id, new_acc}}, else: {:cont, {id, new_acc}}
  end
end
