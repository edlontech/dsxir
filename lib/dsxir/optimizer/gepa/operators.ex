defmodule Dsxir.Optimizer.GEPA.Operators do
  @moduledoc """
  Behaviour and dispatcher for GEPA mutation operators.

  Each operator returns `{:ok, %Delta{}, proposer_calls}` or `{:error, exc}`.
  `sample/4` picks an operator by weighted draw against
  `config.operator_weights` and returns the parents the operator needs.
  """

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators
  alias Dsxir.Optimizer.GEPA.Pareto
  alias Dsxir.Optimizer.GEPA.Population

  @type ctx :: %{
          reflective_lm: {module(), keyword()},
          demo_table: %{atom() => %{map() => [Dsxir.Demo.t()]}},
          decls: [Dsxir.Program.PredictorDecl.t()],
          rng: term(),
          config: map()
        }

  @type parents :: Individual.t() | {Individual.t(), Individual.t()}

  @callback kind() :: :mutate_instr | :mutate_demos | :crossover
  @callback parent_count() :: 1 | 2
  @callback apply(parents :: parents(), ctx :: ctx()) ::
              {:ok, Delta.t(), proposer_calls :: non_neg_integer()}
              | {:error, Exception.t()}

  @doc """
  Weighted draw of an operator. Returns `{operator_module, parents, rng2}`.
  Population invariants make stale frontier references impossible by
  construction: the loop never removes ids.
  """
  @spec sample(
          frontier :: [Population.id()],
          pop :: Population.t(),
          weights :: %{atom() => float()},
          rng :: term()
        ) :: {module(), parents(), term()}
  def sample(frontier, %Population{} = pop, weights, rng) when frontier != [] do
    {op_mod, rng1} = pick_operator(weights, rng)
    {parents, rng2} = pick_parents(op_mod, pop, frontier, rng1)
    {op_mod, parents, rng2}
  end

  defp pick_operator(weights, rng) do
    candidates = [
      {Operators.MutateInstr, Map.get(weights, :mutate_instr, 0.0)},
      {Operators.MutateDemos, Map.get(weights, :mutate_demos, 0.0)},
      {Operators.Crossover, Map.get(weights, :crossover, 0.0)}
    ]

    weighted_pick(candidates, rng)
  end

  defp weighted_pick(candidates, rng) do
    total = candidates |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    {r, rng2} = :rand.uniform_s(rng)
    chosen = pick_candidate(candidates, total, r)
    {chosen, rng2}
  end

  defp pick_candidate(candidates, total, r) when total <= 0.0 do
    idx = min(trunc(r * length(candidates)), length(candidates) - 1)
    candidates |> Enum.at(idx) |> elem(0)
  end

  defp pick_candidate(candidates, total, r) do
    target = r * total

    {pick, _} = Enum.reduce_while(candidates, {nil, 0.0}, &step_candidate(&1, &2, target))
    pick
  end

  defp step_candidate({mod, w}, {_prev, acc}, target) do
    new = acc + w
    if new >= target, do: {:halt, {mod, new}}, else: {:cont, {mod, new}}
  end

  defp pick_parents(op_mod, pop, frontier, rng) do
    case op_mod.parent_count() do
      1 -> Pareto.select_parent(pop, frontier, rng)
      2 -> pick_two_parents(pop, frontier, rng)
    end
  end

  defp pick_two_parents(pop, frontier, rng) do
    {a, rng1} = Pareto.select_parent(pop, frontier, rng)
    rest = List.delete(frontier, a.id)

    case rest do
      [] ->
        {{a, a}, rng1}

      _ ->
        {b, rng2} = Pareto.select_parent(pop, rest, rng1)
        {{a, b}, rng2}
    end
  end
end
