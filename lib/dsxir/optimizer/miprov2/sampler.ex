defmodule Dsxir.Optimizer.MIPROv2.Sampler do
  @moduledoc """
  Persistent state for a `Dsxir.Optimizer.MIPROv2` session.

  Holds the data that `Dsxir.OptimizerSession` needs to checkpoint and resume
  a sequential MIPROv2 run: the underlying TPE/Random sampler state, the
  pre-built candidate pool, cached proposer summaries (so a resume does not
  re-call the proposer LM), the RNG seed, the per-trial history, and the
  resolved configuration.

  Serialized via `:erlang.term_to_binary/2` with `:deterministic` so two
  checkpoints over the same logical state are byte-identical, and deserialized
  with `:safe` to refuse atom creation from untrusted blobs.
  """

  alias Dsxir.Optimizer.MIPROv2.Candidates

  defstruct [
    :tpe_state,
    :candidates,
    :proposer_summaries,
    :rng_seed,
    :config,
    :best_so_far,
    :trial_records,
    :full_evals,
    :proposer_calls,
    :batch_size,
    :minibatch_full_eval_steps,
    :top_k_full_eval,
    :total_planned_trials,
    :minibatch,
    :valset,
    :sampler_module
  ]

  @type proposer_summaries :: %{
          program_summary: nil | String.t(),
          dataset_summary: nil | String.t(),
          degraded: boolean()
        }

  @type best :: nil | {float(), Dsxir.Program.t()}

  @type t :: %__MODULE__{
          tpe_state: term(),
          candidates: Candidates.t(),
          proposer_summaries: proposer_summaries(),
          rng_seed: integer(),
          config: map(),
          best_so_far: best(),
          trial_records: [map()],
          full_evals: [map()],
          proposer_calls: non_neg_integer(),
          batch_size: pos_integer(),
          minibatch_full_eval_steps: pos_integer(),
          top_k_full_eval: pos_integer(),
          total_planned_trials: pos_integer(),
          minibatch: [Dsxir.Example.t()],
          valset: [Dsxir.Example.t()],
          sampler_module: module()
        }

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Optimizer.MIPROv2.Sampler{} = s, opts) do
      best_score =
        case s.best_so_far do
          {score, _program} -> score
          _ -> nil
        end

      degraded =
        case s.proposer_summaries do
          %{degraded: d} -> d
          _ -> nil
        end

      concat([
        "#Dsxir.Optimizer.MIPROv2.Sampler<trials: ",
        Integer.to_string(count(s.trial_records)),
        "/",
        to_doc(s.total_planned_trials, opts),
        ", full_evals: ",
        Integer.to_string(count(s.full_evals)),
        ", proposer_calls: ",
        to_doc(s.proposer_calls, opts),
        ", minibatch: ",
        Integer.to_string(count(s.minibatch)),
        ", valset: ",
        Integer.to_string(count(s.valset)),
        ", best_score: ",
        to_doc(best_score, opts),
        ", degraded: ",
        to_doc(degraded, opts),
        ">"
      ])
    end

    defp count(list) when is_list(list), do: length(list)
    defp count(_), do: 0
  end
end
