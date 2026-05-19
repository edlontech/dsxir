defmodule Dsxir.OptimizerSession.Data do
  @moduledoc false

  defstruct [
    :session_id,
    :optimizer,
    :program,
    :program_module,
    :trainset,
    :trainset_hash,
    :metric,
    :opts,
    :max_errors,
    :store,
    :settings_snapshot,
    :sampler_state,
    :planned_trials,
    :best_program,
    :best_score,
    :best_trial_idx,
    :trial_log,
    :attempts,
    :completed,
    :errors,
    :started_at,
    :trial_task_ref,
    :next_trial_idx,
    :awaiters,
    pause_flag: false,
    cancel_flag: false,
    terminal_reason: nil
  ]

  @type t :: %__MODULE__{}
end
