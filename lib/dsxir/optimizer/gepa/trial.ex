defmodule Dsxir.Optimizer.GEPA.Trial do
  @moduledoc """
  One-trial pipeline: select operator, apply, build child, evaluate, admit.
  Catches the framework-recognised exception classes at its boundary and
  surfaces them as a `:error`-status trial record (degraded sampler) rather
  than crashing the caller.
  """

  alias Dsxir.Errors

  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Evaluator
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Operators
  alias Dsxir.Optimizer.GEPA.Pareto
  alias Dsxir.Optimizer.GEPA.Population
  alias Dsxir.Optimizer.GEPA.Sampler

  @type args :: %{
          required(:sampler) => Sampler.t(),
          required(:trial_idx) => non_neg_integer(),
          required(:metric) => Dsxir.Metric.t() | nil
        }

  @doc """
  Runs one trial: samples an operator, applies it, evaluates the child, and
  admits it to the population. Recognised framework exceptions are caught and
  surfaced as a `:error`-status trial (sampler marked degraded) instead of
  crashing the caller.
  """
  @spec run(args()) :: {:ok, Sampler.t(), trial_result :: map()}
  def run(%{sampler: %Sampler{} = s, trial_idx: idx, metric: metric}) do
    started = System.monotonic_time(:millisecond)

    try do
      {op_mod, parents, rng1} =
        Operators.sample(s.frontier, s.population, s.config.operator_weights, s.rng_state)

      ctx = %{
        reflective_lm: s.reflective_lm,
        demo_table: s.demo_table,
        decls: s.decls,
        rng: rng1,
        config: s.config
      }

      case op_mod.apply(parents, ctx) do
        {:ok, child_delta, proposer_calls} ->
          outcome = %{
            op_mod: op_mod,
            parents: parents,
            child_delta: child_delta,
            proposer_calls: proposer_calls
          }

          on_success(s, idx, outcome, metric, started, rng1)

        {:error, exc} ->
          on_failure(s, idx, op_mod, parents, exc, started, rng1)
      end
    rescue
      e in [
        Errors.LM.RequestFailed,
        Errors.LM.RateLimited,
        Errors.LM.ContextWindow,
        Errors.LM.Authentication,
        Errors.Adapter.ParseError,
        Errors.Adapter.ZoiValidation,
        Errors.Adapter.FallbackExhausted,
        Errors.Framework.PredictorError,
        Errors.Framework.GEPAOperatorFailed,
        Errors.Invalid.Configuration,
        Errors.Invalid.Metric
      ] ->
        on_rescue(s, idx, stamp_path(e, idx), started)
    end
  end

  defp on_success(s, idx, outcome, metric, started, rng1) do
    %{op_mod: op_mod, parents: parents, child_delta: child_delta, proposer_calls: proposer_calls} =
      outcome

    child_program = Delta.apply_to(s.seed_program, child_delta, s.demo_table)
    {scores, feedback} = evaluate(child_program, s.devset, metric)

    child_ind =
      Individual.new(
        child_delta,
        scores,
        feedback,
        parent_ids(parents),
        op_mod.kind(),
        s.generation + 1
      )

    accepted? = Pareto.would_join_frontier?(s.population, child_ind)
    next_pop = Population.add(s.population, child_ind)
    next_front = Pareto.frontier(next_pop)
    best_so_far = update_best(s.best_so_far, child_ind)

    s2 = %{
      s
      | population: next_pop,
        frontier: next_front,
        generation: s.generation + 1,
        attempts: s.attempts + 1,
        proposer_calls: s.proposer_calls + proposer_calls,
        total_devset_evals: s.total_devset_evals + length(s.devset),
        rng_state: rng1,
        best_so_far: best_so_far
    }

    duration = System.monotonic_time(:millisecond) - started

    trial = %{
      trial_idx: idx,
      candidate_id: child_ind.id,
      score: child_ind.aggregated,
      status: :ok,
      stats: %{
        operator: op_mod.kind(),
        parents: parent_ids(parents),
        generation: child_ind.generation,
        accepted_to_frontier: accepted?,
        frontier_size: length(next_front),
        proposer_calls: proposer_calls
      },
      duration_ms: duration,
      error: nil,
      error_class: nil,
      candidate_program: child_program
    }

    {:ok, s2, trial}
  end

  defp on_failure(s, idx, op_mod, parents, exc, started, rng1) do
    s2 = %{s | attempts: s.attempts + 1, rng_state: rng1, degraded: true}

    duration = System.monotonic_time(:millisecond) - started

    trial = %{
      trial_idx: idx,
      candidate_id: nil,
      score: nil,
      status: :error,
      stats: %{operator: op_mod.kind(), parents: parent_ids(parents)},
      duration_ms: duration,
      error: exc,
      error_class: Errors.class_of(exc),
      candidate_program: nil
    }

    {:ok, s2, trial}
  end

  defp on_rescue(s, idx, exc, started) do
    s2 = %{s | attempts: s.attempts + 1, degraded: true}

    duration = System.monotonic_time(:millisecond) - started

    trial = %{
      trial_idx: idx,
      candidate_id: nil,
      score: nil,
      status: :error,
      stats: %{operator: nil, parents: []},
      duration_ms: duration,
      error: exc,
      error_class: Errors.class_of(exc),
      candidate_program: nil
    }

    {:ok, s2, trial}
  end

  defp evaluate(program, devset, metric), do: Evaluator.run_or_nils(program, devset, metric)

  defp parent_ids(%Individual{id: id}), do: [id]
  defp parent_ids({%Individual{id: a}, %Individual{id: b}}), do: [a, b]

  defp update_best(nil, %Individual{aggregated: nil}), do: nil
  defp update_best(nil, %Individual{id: id, aggregated: score}), do: {id, score}
  defp update_best({_, _} = best, %Individual{aggregated: nil}), do: best

  defp update_best({best_id, best_score}, %Individual{id: id, aggregated: score})
       when is_number(score) and is_number(best_score) do
    if score > best_score, do: {id, score}, else: {best_id, best_score}
  end

  defp update_best(current, _), do: current

  defp stamp_path(%{path: existing} = e, idx) when is_list(existing) do
    Map.put(e, :path, [:gepa, :"trial_#{idx}" | existing])
  end

  defp stamp_path(e, _idx), do: e
end
