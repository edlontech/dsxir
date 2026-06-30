defmodule Dsxir.Optimizer.SIMBA do
  @moduledoc """
  Stochastic Introspective Mini-Batch Ascent. Implements `@behaviour
  Dsxir.Optimizer` and the four checkpointable callbacks, so it drops into
  `Dsxir.OptimizerSession` exactly the way GEPA and MIPROv2 do.

  Each `step/6` is one mini-batch trajectory-sampling iteration driven by
  `Dsxir.Optimizer.SIMBA.Trial`. `init_session/4` plants the student as pool
  index 0 and shuffles the trainset cursor. See `Dsxir.Optimizer.SIMBA.Auto`
  for `:auto` presets.

  ## Options

    * `:auto` (default `:medium`) - preset for `bsize`, `num_candidates`,
      `max_steps`, `max_demos`. `:light | :medium | :heavy`.
    * `:seed` (default `0`) - RNG seed; makes a run deterministic.
    * Any preset key - overrides the preset.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Errors
  alias Dsxir.Optimizer.SIMBA.Auto
  alias Dsxir.Optimizer.SIMBA.Config
  alias Dsxir.Optimizer.SIMBA.Evaluator
  alias Dsxir.Optimizer.SIMBA.Sampler
  alias Dsxir.Optimizer.SIMBA.Stats
  alias Dsxir.Optimizer.SIMBA.Trial
  alias Dsxir.Program
  alias Dsxir.Telemetry

  @impl Dsxir.Optimizer
  @spec compile(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t(), keyword()) ::
          Dsxir.Optimizer.result()
  def compile(_student, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def compile(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_function(metric, 3) and is_list(opts) do
    started = System.monotonic_time(:millisecond)

    Telemetry.emit(
      [:dsxir, :optimizer, :start],
      %{system_time: System.system_time()},
      %{optimizer: __MODULE__, trainset_size: length(trainset), error_class: nil}
    )

    case init_session(student, trainset, metric, opts) do
      {:ok, sampler, _planned} ->
        final = run_loop(sampler, student, trainset, metric, opts)
        {best, stats} = finalize(final, trainset, metric, started)
        compiled = stamp_metadata(best, stats)

        Telemetry.emit(
          [:dsxir, :optimizer, :stop],
          %{duration_ms: stats.wall_clock_ms},
          %{optimizer: __MODULE__, best_score: stats.best_score, error_class: nil}
        )

        {:ok, compiled, stats}

      {:error, _} = err ->
        err
    end
  end

  @doc "Like `compile/4` but raises the validation exception on `{:error, _}`."
  @spec compile!(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t(), keyword()) :: Program.t()
  def compile!(%Program{} = student, trainset, metric, opts) do
    case compile(student, trainset, metric, opts) do
      {:ok, prog, _stats} -> prog
      {:error, exception} -> raise exception
    end
  end

  defp run_loop(sampler, student, trainset, metric, opts) do
    Enum.reduce_while(0..(sampler.total_planned_trials - 1), sampler, fn idx, s ->
      case step(s, idx, student, trainset, metric, opts) do
        {:cont, s2, trial} ->
          emit_trial(trial)
          {:cont, s2}

        {:halt, s2, _} ->
          {:halt, s2}
      end
    end)
  end

  defp emit_trial(trial) do
    Telemetry.emit(
      [:dsxir, :optimizer, :simba, :trial],
      %{score: trial.score, baseline: trial.stats.baseline, duration_ms: trial.duration_ms},
      %{
        trial_idx: trial.trial_idx,
        num_candidates: trial.stats.num_candidates,
        error_class: trial.error_class
      }
    )
  end

  defp finalize(sampler, trainset, metric, started) do
    cfg = sampler.config
    n = cfg.num_candidates + 1
    m = length(sampler.winning_programs) - 1

    program_idxs =
      if m < 1 do
        List.duplicate(0, n)
      else
        for i <- 0..(n - 1), do: round(i * m / (n - 1))
      end
      |> Enum.uniq()

    candidates = Enum.map(program_idxs, &Enum.at(sampler.winning_programs, &1))

    scored =
      Enum.map(candidates, fn cand ->
        records =
          Evaluator.run(for(ex <- trainset, do: {cand, ex}), metric,
            sampling: false,
            num_threads: cfg.num_threads
          )

        %{score: mean(Enum.map(records, & &1.score)), program: cand}
      end)

    best = Enum.max_by(scored, & &1.score)
    candidate_data = Enum.sort_by(scored, & &1.score, :desc)

    stats = %Stats{
      best_score: best.score,
      best_program_idx: Enum.find_index(candidate_data, &(&1 == best)),
      steps: sampler.attempts,
      num_candidates_total: sampler.next_idx,
      candidate_programs: candidate_data,
      trial_logs: sampler.trial_logs,
      total_program_runs: total_program_runs(sampler, length(candidates), length(trainset)),
      degraded: sampler.degraded,
      wall_clock_ms: System.monotonic_time(:millisecond) - started
    }

    {best.program, stats}
  end

  # NOTE: approximate run count: per step samples bsize*num_candidates trajectories
  # then evaluates roughly as many candidates, plus the finalize full-trainset evals.
  defp total_program_runs(sampler, finalize_candidates, trainset_size) do
    cfg = sampler.config
    cfg.bsize * cfg.num_candidates * 2 * sampler.attempts + finalize_candidates * trainset_size
  end

  defp stamp_metadata(%Program{metadata: meta} = prog, %Stats{} = stats) do
    %{
      prog
      | metadata:
          meta
          |> Map.put(:compiled_with, __MODULE__)
          |> Map.put(:score, stats.best_score)
          |> Map.put(:_simba_stats, stats)
    }
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)

  @impl Dsxir.Optimizer
  def init_session(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_list(opts) and (is_function(metric, 3) or is_nil(metric)) do
    with {:ok, cfg} <- Config.validate(Auto.expand(opts, Keyword.get(opts, :auto, :medium)), trainset),
         {:ok, _decls} <- validate_predictors(student) do
      seed = Keyword.get(opts, :seed, 0)
      initial_rng = :rand.seed_s(:exsss, {seed, seed, seed})
      {data_indices, rng_state} = shuffle(Enum.to_list(0..(length(trainset) - 1)), initial_rng)

      sampler = %Sampler{
        trainset: trainset,
        seed_program: student,
        programs: [%{idx: 0, program: student}],
        program_scores: %{0 => []},
        next_idx: 0,
        winning_programs: [student],
        data_indices: data_indices,
        instance_idx: 0,
        trial_logs: %{},
        best_so_far: nil,
        attempts: 0,
        rng_seed: seed,
        rng_state: rng_state,
        degraded: false,
        config: cfg,
        total_planned_trials: cfg.max_steps
      }

      {:ok, sampler, cfg.max_steps}
    end
  end

  defp validate_predictors(%Program{} = student) do
    case Program.Source.predictors(student.source) do
      [] -> {:error, %Errors.Invalid.Trainset{reason: :no_predictors, example: nil}}
      decls -> {:ok, decls}
    end
  end

  defp shuffle(elements, rng) do
    {tagged, rng} =
      Enum.map_reduce(elements, rng, fn element, r ->
        {u, r2} = :rand.uniform_s(r)
        {{u, element}, r2}
      end)

    {tagged |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), rng}
  end

  @impl Dsxir.Optimizer
  @doc """
  Single mini-batch step. Returns `{:cont, sampler, trial}` while budget
  remains, or `{:halt, sampler, :budget_exhausted}` once `attempts` reaches
  `total_planned_trials` on entry. Mirrors `Dsxir.Optimizer.GEPA.step/6`.
  """
  def step(%Sampler{} = sampler, trial_idx, _student, _trainset, metric, opts) do
    if sampler.attempts >= sampler.total_planned_trials do
      {:halt, sampler, :budget_exhausted}
    else
      {:ok, s2, trial} =
        Trial.run(%{sampler: sampler, trial_idx: trial_idx, metric: metric, opts: opts})

      {:cont, s2, trial}
    end
  end

  @impl Dsxir.Optimizer
  def serialize_state(%Sampler{} = s), do: Sampler.serialize(s)

  @impl Dsxir.Optimizer
  def deserialize_state(blob, version), do: Sampler.deserialize(blob, version)

  @doc "Projects sampler state into a `Dsxir.Optimizer.SIMBA.Stats` record."
  @spec build_stats(Sampler.t()) :: Dsxir.Optimizer.SIMBA.Stats.t()
  def build_stats(%Sampler{} = s), do: Sampler.build_stats(s)
end
