defmodule Dsxir.Optimizer.GEPA do
  @moduledoc """
  Reflective + Pareto-frontier evolutionary optimizer. Implements
  `@behaviour Dsxir.Optimizer` and all four checkpointable callbacks, so it
  drops into `Dsxir.OptimizerSession` exactly the way MIPROv2 does.

  Public API:

      {:ok, compiled, stats} =
        Dsxir.compile(Dsxir.Optimizer.GEPA, program, trainset, metric, auto: :medium)

  Session mode:

      {:ok, compiled, stats} =
        Dsxir.OptimizerSession.compile(Dsxir.Optimizer.GEPA, program, trainset, metric,
                                         opts: [auto: :light])

  See `Dsxir.Optimizer.GEPA.Auto` for `:auto` presets.

  ## Options

    * `:auto` (default `:medium`) - preset for population size, operator weights,
      rollout K, etc. `:light | :medium | :heavy`.
    * `:reflective_lm` (default: settings task LM) - `{module, keyword()}` tuple
      for the LM that performs reflective mutations.
    * Any preset key (`:num_trials`, `:operator_weights`, etc.) - overrides preset.

  ## Returned stats

  `t:Dsxir.Optimizer.GEPA.Stats.t/0`. See module doc for fields.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Errors
  alias Dsxir.Optimizer.BootstrapFewShot

  alias Dsxir.Optimizer.GEPA.Auto
  alias Dsxir.Optimizer.GEPA.Delta
  alias Dsxir.Optimizer.GEPA.Evaluator
  alias Dsxir.Optimizer.GEPA.Individual
  alias Dsxir.Optimizer.GEPA.Pareto
  alias Dsxir.Optimizer.GEPA.Population
  alias Dsxir.Optimizer.GEPA.Sampler
  alias Dsxir.Optimizer.GEPA.Stats
  alias Dsxir.Optimizer.GEPA.Trial

  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime, as: SignatureRuntime
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
        final = run_loop(sampler, metric, opts)
        compiled = pick_best_program(student, final)
        stats = build_final_stats(final, started)

        Telemetry.emit(
          [:dsxir, :optimizer, :stop],
          %{duration_ms: stats.wall_clock_ms},
          %{optimizer: __MODULE__, best_score: stats.best_score, error_class: nil}
        )

        {:ok, stamp_metadata(compiled, stats), stats}

      {:error, _} = err ->
        err
    end
  end

  defp run_loop(sampler, metric, _opts) do
    Enum.reduce_while(0..(sampler.config.num_trials - 1), {sampler, []}, fn idx, {s, trials} ->
      {:ok, s2, trial} = Trial.run(%{sampler: s, trial_idx: idx, metric: metric})
      emit_trial(trial)

      if s2.attempts >= s2.config.num_trials do
        {:halt, {s2, [trial | trials]}}
      else
        {:cont, {s2, [trial | trials]}}
      end
    end)
  end

  defp emit_trial(trial) do
    Telemetry.emit(
      [:dsxir, :optimizer, :gepa, :trial],
      %{
        score: trial.score,
        duration_ms: trial.duration_ms,
        frontier_size: Map.get(trial.stats, :frontier_size, 0)
      },
      %{
        trial_idx: trial.trial_idx,
        operator: Map.get(trial.stats, :operator),
        accepted_to_frontier: Map.get(trial.stats, :accepted_to_frontier, false),
        parents: Map.get(trial.stats, :parents, []),
        generation: Map.get(trial.stats, :generation),
        error_class: trial.error_class
      }
    )
  end

  defp pick_best_program(seed, {sampler, _trials}) do
    case sampler.best_so_far do
      nil ->
        seed

      {id, _} ->
        case Population.by_id(sampler.population, id) do
          %Individual{delta: delta} -> Delta.apply_to(seed, delta, sampler.demo_table)
          _ -> seed
        end
    end
  end

  defp build_final_stats({sampler, trial_log}, started) do
    %Stats{
      Sampler.build_stats(sampler)
      | trials: Enum.reverse(for t <- trial_log, is_map(t), do: trial_summary(t)),
        wall_clock_ms: System.monotonic_time(:millisecond) - started
    }
  end

  defp trial_summary(trial) do
    %{
      trial_idx: trial.trial_idx,
      individual_id: trial.candidate_id,
      operator: Map.get(trial.stats, :operator),
      accepted?: Map.get(trial.stats, :accepted_to_frontier, false),
      score: trial.score
    }
  end

  defp stamp_metadata(%Program{metadata: m} = prog, %Stats{} = stats) do
    %{
      prog
      | metadata:
          m
          |> Map.put(:compiled_with, __MODULE__)
          |> Map.put(:score, stats.best_score)
          |> Map.put(:_gepa_stats, stats)
    }
  end

  @impl Dsxir.Optimizer
  def init_session(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_list(opts) and (is_function(metric, 3) or is_nil(metric)) do
    cfg = Auto.expand(opts, Keyword.get(opts, :auto, :medium))

    with {:ok, {bootstrap_train, devset}} <-
           split_trainset(trainset, cfg.seed, cfg.devset_fraction),
         {:ok, reflective_lm} <- validate_reflective_lm(opts) do
      decls = Program.Source.predictors(student.source)
      demo_table = build_demo_table(student, bootstrap_train, metric, cfg, decls)
      seed_delta = build_seed_delta(student, decls, cfg)
      {seed_scores, seed_feedback} = seed_eval(student, devset, metric)
      seed_ind = Individual.new(seed_delta, seed_scores, seed_feedback, [], :seed, 0)
      population = Population.new(seed_ind)
      frontier = Pareto.frontier(population)

      sampler = %Sampler{
        population: population,
        frontier: frontier,
        devset: devset,
        seed_program: student,
        decls: decls,
        demo_table: demo_table,
        reflective_lm: reflective_lm,
        proposer_calls: 0,
        total_devset_evals: length(devset),
        attempts: 0,
        generation: 0,
        rng_seed: cfg.seed,
        rng_state: :rand.seed_s(:exsplus, {cfg.seed + 1, cfg.seed + 2, cfg.seed + 3}),
        best_so_far: best_so_far_of(seed_ind),
        degraded: false,
        config: cfg,
        total_planned_trials: cfg.num_trials
      }

      {:ok, sampler, cfg.num_trials}
    end
  end

  def init_session(_, [], _, _) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  defp validate_reflective_lm(opts) do
    value = Keyword.get(opts, :reflective_lm, Settings.resolve(:lm))

    case value do
      {mod, cfg} when is_atom(mod) and not is_nil(mod) and is_list(cfg) ->
        {:ok, {mod, cfg}}

      _ ->
        {:error,
         %Errors.Invalid.Configuration{
           key: :reflective_lm,
           value: value,
           reason:
             "expected {module, keyword()} tuple; got nil — pass :reflective_lm in opts or configure :lm in settings"
         }}
    end
  end

  defp seed_eval(student, devset, metric), do: Evaluator.run_or_nils(student, devset, metric)

  defp best_so_far_of(%Individual{aggregated: nil}), do: nil
  defp best_so_far_of(%Individual{id: id, aggregated: s}), do: {id, s}

  defp split_trainset(trainset, seed, fraction) do
    indexed = Enum.with_index(trainset)

    shuffled =
      indexed
      |> Enum.sort_by(fn {_ex, idx} -> :erlang.phash2({seed, idx}) end)
      |> Enum.map(&elem(&1, 0))

    n = length(shuffled)
    val_count = max(1, min(n - 1, round(n * fraction)))

    if n < 2 do
      {:error,
       %Errors.Invalid.EmptyDevset{
         reason: :too_small,
         trainset_size: n,
         devset_fraction: fraction
       }}
    else
      {:ok, {Enum.drop(shuffled, val_count), Enum.take(shuffled, val_count)}}
    end
  end

  defp build_demo_table(student, trainset, metric, cfg, decls) do
    n = cfg.num_demo_bundles
    half = max(1, div(n, 2))

    labeled_refs =
      for offset <- 0..(half - 1) do
        ref = %{seed: cfg.seed + offset, kind: :labeled}
        {ref, labeled_bundle(student, trainset, cfg.seed + offset)}
      end

    bootstrap_refs =
      for offset <- 0..(n - half - 1), n - half > 0 do
        ref = %{seed: cfg.seed + offset, kind: :bootstrap}
        {ref, bootstrap_bundle(student, trainset, metric, cfg.seed + offset)}
      end

    all = labeled_refs ++ bootstrap_refs

    Map.new(decls, fn decl ->
      bundles =
        Map.new(all, fn {ref, compiled_program} ->
          {ref, demos_for(compiled_program, decl.name)}
        end)

      {decl.name, bundles}
    end)
  end

  defp demos_for(compiled, predictor_name) do
    case Map.get(compiled.predictors, predictor_name) do
      %Program.State{demos: demos} -> demos
      _ -> []
    end
  end

  defp labeled_bundle(student, trainset, seed) do
    with_seeded_rand(seed, fn ->
      case LabeledFewShot.compile(student, trainset, nil,
             max_labeled_demos: 4,
             deterministic: false
           ) do
        {:ok, compiled, _} -> compiled
        {:error, _} -> student
      end
    end)
  end

  defp bootstrap_bundle(student, _trainset, nil, _seed), do: student

  defp bootstrap_bundle(student, trainset, metric, seed) do
    with_seeded_rand(seed, fn -> do_bootstrap(student, trainset, metric) end)
  end

  defp do_bootstrap(student, trainset, metric) do
    case BootstrapFewShot.compile(student, trainset, metric,
           max_labeled_demos: 0,
           max_bootstrapped_demos: 4,
           max_rounds: 1,
           threshold: 0.0,
           deterministic: false
         ) do
      {:ok, compiled, _} -> compiled
      {:error, _} -> student
    end
  rescue
    _ in [
      Errors.LM.RequestFailed,
      Errors.LM.Authentication,
      Errors.LM.RateLimited,
      Errors.LM.ContextWindow,
      Errors.Adapter.ParseError,
      Errors.Adapter.ZoiValidation,
      Errors.Adapter.FallbackExhausted,
      Errors.Invalid.Configuration,
      Errors.Invalid.Trainset,
      Errors.Invalid.Metric,
      Errors.Framework.PredictorError,
      Errors.Framework.OptimizerError,
      RuntimeError
    ] ->
      student
  end

  defp with_seeded_rand(seed, fun) do
    prev = :rand.export_seed()
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})

    try do
      fun.()
    after
      case prev do
        :undefined -> Process.delete(:rand_seed)
        state -> :rand.seed(state)
      end
    end
  end

  defp build_seed_delta(student, decls, cfg) do
    instructions =
      Map.new(decls, fn decl ->
        override =
          case Map.get(student.predictors, decl.name) do
            %Program.State{instructions_override: inst} when is_binary(inst) -> inst
            _ -> nil
          end

        {decl.name, override || SignatureRuntime.instruction(decl.signature)}
      end)

    demo_bundle_refs =
      Map.new(decls, fn decl -> {decl.name, %{seed: cfg.seed, kind: :labeled}} end)

    %Delta{instructions: instructions, demo_bundle_refs: demo_bundle_refs}
  end

  @impl Dsxir.Optimizer
  @doc """
  Single-trial step. Always returns `{:cont, sampler, trial}` or `{:halt, sampler, :budget_exhausted}`;
  recognised exception classes are caught inside `Trial.run/1` and surfaced as
  an `:error`-status trial record (and `degraded: true` on the returned sampler).
  The session driver decides whether to halt on accumulated errors.
  """
  def step(%Sampler{} = sampler, trial_idx, _program, _trainset, metric, _opts) do
    if sampler.attempts >= sampler.config.num_trials do
      {:halt, sampler, :budget_exhausted}
    else
      {:ok, s2, trial} = Trial.run(%{sampler: sampler, trial_idx: trial_idx, metric: metric})
      {:cont, s2, trial}
    end
  end

  @impl Dsxir.Optimizer
  def serialize_state(%Sampler{} = s), do: Sampler.serialize(s)

  @impl Dsxir.Optimizer
  def deserialize_state(blob, version), do: Sampler.deserialize(blob, version)
end
