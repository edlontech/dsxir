defmodule Dsxir.Optimizer.COPRO.Evaluator do
  @moduledoc """
  Scores a candidate program for `Dsxir.Optimizer.COPRO`. Runs the
  already-overridden program on the eval set via `Dsxir.Evaluate` and returns
  the mean score and the aggregate error summary. This is a pure scoring shim:
  override application lives in the `Dsxir.Optimizer.COPRO` wrapper, which hands
  this function a program whose instruction overrides are already applied. The
  eval-set rows are scored concurrently; `cfg.num_threads` sets the fan-out and
  defaults to `System.schedulers_online/0` when absent.

  Per-example failures collapse to `failure_score: 0.0`; the caller decides
  whether a wholesale failure is an error trial.

  `max_errors` is set to `length(evalset)` rather than `:infinity` because
  `Dsxir.Evaluate.max_errors` is typed `non_neg_integer()` and the `Inspect`
  implementation calls `Integer.to_string/1` on it, which would crash on the
  atom `:infinity`. The field is telemetry metadata only — `Dsxir.Evaluate.run/2`
  never consults it to abort the run, so every eval-set row is always scored.
  """

  alias Dsxir.Evaluate
  alias Dsxir.EvaluationResult
  alias Dsxir.Program

  @doc """
  Scores `program` against `evalset` with `metric` and returns
  `{:ok, mean_score, errors}`. Reads `cfg.num_threads` for the eval fan-out,
  falling back to `System.schedulers_online/0` when the key is absent.
  """
  @spec run(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t(), map()) ::
          {:ok, score :: float(), errors :: EvaluationResult.errors()}
  def run(%Program{} = program, evalset, metric, cfg) do
    ev = %Evaluate{
      devset: evalset,
      metric: metric,
      max_errors: length(evalset),
      failure_score: 0.0,
      num_threads: Map.get(cfg, :num_threads, System.schedulers_online())
    }

    %EvaluationResult{score: score, errors: errors} = Evaluate.run(ev, program)
    {:ok, score, errors}
  end
end
