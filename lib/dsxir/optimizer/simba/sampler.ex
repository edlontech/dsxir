defmodule Dsxir.Optimizer.SIMBA.Sampler do
  @moduledoc """
  Checkpointable pool state for a SIMBA session. Carries the global program
  pool with per-program mini-batch score lists, the shuffled trainset cursor,
  winning programs per step, and a threaded `:rand` state.

  `serialize/1` round-trips via `:erlang.term_to_binary/2` with
  `[:deterministic]`; `deserialize/2` uses `[:safe]` and confirms shape.

  Helpers that consume randomness take and return `rng_state` so callers
  thread it explicitly; nothing mutates global `:rand`, which keeps
  checkpoint resume deterministic.

  `attempts` counts every `step/6` invocation so the budget terminates
  cleanly even if every candidate failed.
  """

  alias Dsxir.Optimizer.SIMBA.Stats

  defstruct [
    :trainset,
    :seed_program,
    :programs,
    :program_scores,
    :next_idx,
    :winning_programs,
    :data_indices,
    :instance_idx,
    :trial_logs,
    :best_so_far,
    :attempts,
    :rng_seed,
    :rng_state,
    :degraded,
    :config,
    :total_planned_trials
  ]

  @type pool_entry :: %{idx: non_neg_integer(), program: Dsxir.Program.t()}

  @type t :: %__MODULE__{
          trainset: [Dsxir.Example.t()],
          seed_program: Dsxir.Program.t(),
          programs: [pool_entry()],
          program_scores: %{non_neg_integer() => [float()]},
          next_idx: non_neg_integer(),
          winning_programs: [Dsxir.Program.t()],
          data_indices: [non_neg_integer()],
          instance_idx: non_neg_integer(),
          trial_logs: %{optional(non_neg_integer()) => map()},
          best_so_far: {non_neg_integer(), float()} | nil,
          attempts: non_neg_integer(),
          rng_seed: integer(),
          rng_state: term(),
          degraded: boolean(),
          config: map(),
          total_planned_trials: pos_integer()
        }

  @doc "Mean of the score list for `idx`, `0.0` when no scores are recorded."
  @spec calc_average_score(t(), non_neg_integer()) :: float()
  def calc_average_score(%__MODULE__{} = s, idx) do
    case Map.get(s.program_scores, idx, []) do
      [] -> 0.0
      scores -> Enum.sum(scores) / length(scores)
    end
  end

  @doc """
  Pool indices sorted by average score descending, truncated to `k`, with the
  baseline (index 0) always folded in.

  Mirrors DSPy: when 0 is absent from a non-empty top-k it replaces the last
  element, then the result is deduped preserving order.
  """
  @spec top_k_plus_baseline(t(), pos_integer()) :: [non_neg_integer()]
  def top_k_plus_baseline(%__MODULE__{} = s, k) do
    top_k =
      s.programs
      |> Enum.sort_by(&calc_average_score(s, &1.idx), :desc)
      |> Enum.take(k)
      |> Enum.map(& &1.idx)

    top_k
    |> ensure_baseline()
    |> Enum.uniq()
  end

  defp ensure_baseline([]), do: []

  defp ensure_baseline(top_k) do
    if 0 in top_k do
      top_k
    else
      List.replace_at(top_k, -1, 0)
    end
  end

  @doc """
  Weighted pool-index choice with weights `exp(score / temperature)`. Falls
  back to a uniform pick when the weight sum is non-positive. Deterministic
  given `rng_state`; returns the updated state.
  """
  @spec softmax_sample(t(), [non_neg_integer()], float(), term()) ::
          {non_neg_integer(), term()}
  def softmax_sample(%__MODULE__{} = s, idxs, temperature, rng_state) do
    weights = Enum.map(idxs, fn idx -> :math.exp(calc_average_score(s, idx) / temperature) end)
    total = Enum.sum(weights)

    if total <= 0 do
      uniform_choice(idxs, rng_state)
    else
      weighted_pick(idxs, weights, total, rng_state)
    end
  end

  defp uniform_choice(idxs, rng_state) do
    {r, rng2} = :rand.uniform_s(rng_state)
    idx = min(trunc(r * length(idxs)), length(idxs) - 1)
    {Enum.at(idxs, idx), rng2}
  end

  defp weighted_pick(idxs, weights, total, rng_state) do
    {r, rng2} = :rand.uniform_s(rng_state)
    target = r * total

    {pick, _} =
      idxs
      |> Enum.zip(weights)
      |> Enum.reduce_while({hd(idxs), 0.0}, fn {idx, w}, {_prev, acc} ->
        new_acc = acc + w
        if new_acc >= target, do: {:halt, {idx, new_acc}}, else: {:cont, {idx, new_acc}}
      end)

    {pick, rng2}
  end

  @doc """
  Knuth's Poisson sampler over `rng_state`. Deterministic given the state;
  returns the draw and the updated state.
  """
  @spec poisson(float(), term()) :: {non_neg_integer(), term()}
  def poisson(lambda, rng_state) do
    poisson_loop(:math.exp(-lambda), 1.0, 0, rng_state)
  end

  defp poisson_loop(threshold, p, k, rng_state) do
    {u, rng2} = :rand.uniform_s(rng_state)
    p2 = p * u

    if p2 > threshold do
      poisson_loop(threshold, p2, k + 1, rng2)
    else
      {k, rng2}
    end
  end

  @doc """
  Appends `program` to the pool under a fresh monotonic index, records its
  mini-batch `score_list`, and advances `next_idx`.
  """
  @spec register_new_program(t(), Dsxir.Program.t(), [float()]) :: t()
  def register_new_program(%__MODULE__{} = s, program, score_list) do
    new_idx = s.next_idx + 1

    %{
      s
      | next_idx: new_idx,
        programs: s.programs ++ [%{idx: new_idx, program: program}],
        program_scores: Map.put(s.program_scores, new_idx, score_list)
    }
  end

  @doc "Encodes the sampler deterministically. Returns `{:ok, blob, version}`."
  @spec serialize(t()) :: {:ok, binary(), 1}
  def serialize(%__MODULE__{} = s), do: {:ok, :erlang.term_to_binary(s, [:deterministic]), 1}

  @doc """
  Decodes a sampler blob produced by `serialize/1`. Uses the `:safe` term
  decoder and validates the resulting struct shape.
  """
  @spec deserialize(binary(), pos_integer()) ::
          {:ok, t()}
          | {:error, :version_mismatch | :corrupt_blob | {:bad_sampler_shape, term()}}
  def deserialize(blob, 1) when is_binary(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      %__MODULE__{} = s -> {:ok, s}
      other -> {:error, {:bad_sampler_shape, other}}
    end
  rescue
    ArgumentError -> {:error, :corrupt_blob}
  end

  def deserialize(_, _), do: {:error, :version_mismatch}

  @doc """
  Projects sampler state into a `Stats` record. Finalize-only fields
  (`candidate_programs`, `wall_clock_ms`) stay at their struct defaults.
  """
  @spec build_stats(t()) :: Stats.t()
  def build_stats(%__MODULE__{} = s) do
    {best_idx, best_score} =
      case s.best_so_far do
        nil -> {nil, nil}
        {idx, score} -> {idx, score}
      end

    %Stats{
      best_score: best_score,
      best_program_idx: best_idx,
      steps: s.attempts,
      num_candidates_total: s.next_idx,
      trial_logs: s.trial_logs,
      degraded: s.degraded
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.SIMBA.Sampler{} = s, opts) do
      {best_idx, best_score} =
        case s.best_so_far do
          nil -> {nil, nil}
          {idx, score} -> {idx, score}
        end

      concat([
        "#Dsxir.Optimizer.SIMBA.Sampler<attempts: ",
        Integer.to_string(s.attempts),
        ", pool: ",
        Integer.to_string(length(s.programs)),
        ", winners: ",
        Integer.to_string(length(s.winning_programs)),
        ", best: ",
        to_doc(best_idx, opts),
        " (",
        to_doc(best_score, opts),
        "), degraded: ",
        to_doc(s.degraded, opts),
        ">"
      ])
    end
  end
end
