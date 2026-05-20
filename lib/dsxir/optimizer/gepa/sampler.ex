defmodule Dsxir.Optimizer.GEPA.Sampler do
  @moduledoc """
  Checkpointable state for a GEPA session. `serialize/1` round-trips via
  `:erlang.term_to_binary/2` with `[:deterministic]`; `deserialize/2`
  uses `[:safe]` and confirms shape.

  `attempts` counts every `step/6` invocation (including failed reflective
  trials) so the budget terminates cleanly even if every operator failed.
  """

  alias Dsxir.Optimizer.GEPA.Population
  alias Dsxir.Optimizer.GEPA.Stats

  defstruct [
    :population,
    :frontier,
    :devset,
    :seed_program,
    :decls,
    :demo_table,
    :reflective_lm,
    :proposer_calls,
    :total_devset_evals,
    :attempts,
    :generation,
    :rng_seed,
    :rng_state,
    :best_so_far,
    :degraded,
    :config,
    :total_planned_trials
  ]

  @type t :: %__MODULE__{
          population: Population.t(),
          frontier: [String.t()],
          devset: [Dsxir.Example.t()],
          seed_program: Dsxir.Program.t(),
          decls: [Dsxir.Program.PredictorDecl.t()],
          demo_table: %{atom() => %{map() => [Dsxir.Demo.t()]}},
          reflective_lm: {module(), keyword()},
          proposer_calls: non_neg_integer(),
          total_devset_evals: non_neg_integer(),
          attempts: non_neg_integer(),
          generation: non_neg_integer(),
          rng_seed: integer(),
          rng_state: term(),
          best_so_far: {String.t(), float()} | nil,
          degraded: boolean(),
          config: map(),
          total_planned_trials: pos_integer()
        }

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

  @doc "Projects sampler state into a `Stats` record for reporting."
  @spec build_stats(t()) :: Stats.t()
  def build_stats(%__MODULE__{} = s) do
    {best_id, best_score} =
      case s.best_so_far do
        nil -> {nil, nil}
        {id, score} -> {id, score}
      end

    %Stats{
      best_score: best_score,
      best_individual_id: best_id,
      generations: s.generation,
      population_size: Population.size(s.population),
      frontier_size: length(s.frontier),
      trials: [],
      proposer_calls: s.proposer_calls,
      total_devset_evals: s.total_devset_evals,
      total_task_lm_calls: 0,
      degraded: s.degraded,
      wall_clock_ms: 0
    }
  end

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.GEPA.Sampler{} = s, opts) do
      {best_id, best_score} =
        case s.best_so_far do
          nil -> {nil, nil}
          {id, score} -> {id, score}
        end

      concat([
        "#Dsxir.Optimizer.GEPA.Sampler<gen: ",
        Integer.to_string(s.generation),
        ", attempts: ",
        Integer.to_string(s.attempts),
        ", population: ",
        Integer.to_string(Dsxir.Optimizer.GEPA.Population.size(s.population)),
        ", frontier: ",
        Integer.to_string(length(s.frontier)),
        ", devset: ",
        Integer.to_string(length(s.devset)),
        ", best: ",
        to_doc(best_id, opts),
        " (",
        to_doc(best_score, opts),
        "), proposer_calls: ",
        Integer.to_string(s.proposer_calls),
        ", degraded: ",
        to_doc(s.degraded, opts),
        ">"
      ])
    end
  end
end
