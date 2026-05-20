defmodule Dsxir.Optimizer.MIPROv2 do
  @moduledoc """
  Joint instruction-and-demo optimizer. Port of DSPy's MIPROv2.

  Bootstraps candidate demo bundles, asks a proposer LM for candidate
  instructions grounded in program / dataset summaries, then searches the joint
  categorical space with a configurable sampler (`Dsxir.Optimizer.Search.TPE`
  by default). Trials run in parallel on a minibatch via
  `Dsxir.Optimizer.MIPROv2.Trial.run/1`; top candidates are periodically re-run
  on the full valset and the highest full-eval score wins.

  ## Quick start

      {:ok, compiled, stats} =
        Dsxir.compile(
          Dsxir.Optimizer.MIPROv2,
          program,
          trainset,
          metric,
          auto: :medium
        )

  ## Options

  See `Dsxir.Optimizer.MIPROv2.Auto` for `:light | :medium | :heavy` presets.

    * `:auto` (default `:medium`) — preset for `num_trials`,
      `num_instruction_candidates`, `num_demo_sets`, `minibatch_size`.
    * `:proposer_lm` — `{module, config}` tuple used for program/dataset
      summaries and grounded instruction proposals. Defaults to the task LM.
    * `:sampler` (default `Dsxir.Optimizer.Search.TPE`) — sampler module.
    * `:sampler_opts` (default `[]`) — passed to `sampler.init/2`.
    * `:batch_size` (default `4`) — trials suggested + executed per loop step.
    * `:minibatch_full_eval_steps` (default `10`) — every Nth trial triggers a
      full-valset rerank of the top `:top_k_full_eval` trials.
    * `:top_k_full_eval` (default `4`) — how many minibatch winners to rerank.
    * `:seed` (default `0`) — controls trainset/valset split and sampler PRNG.
    * `:valset_fraction` (default `0.2`) — share of trainset reserved as valset
      (clamped to leave at least one training example and one valset example
      when possible).
    * `:compile_cache` (default `true`) — enables `Dsxir.Optimizer.Cache`.
    * `:tip` (default `nil`) — stylistic hint forwarded to the grounded proposer.

  ## Returned stats

  `t:Dsxir.Optimizer.MIPROv2.Stats.t/0`. Notable fields:

    * `:best_score` / `:best_config` — winning trial.
    * `:trials` / `:full_evals` — per-trial records.
    * `:proposer_calls` — LM calls issued to the proposer.
    * `:total_task_lm_calls` / `:total_cached_calls` — task LM stats summed
      across trials.
    * `:degraded` — `true` when any proposer call failed and was substituted
      with an empty summary or candidate list.
    * `:wall_clock_ms` — wall time of the compile.

  ## Session mode

  `Dsxir.OptimizerSession.compile(MIPROv2, ...)` runs trials sequentially via
  `step/6` and skips the periodic full-valset rerank performed by `compile/4`.
  In session mode `best_program` is selected from minibatch scores only, so
  outcomes may differ from a non-session compile against the same inputs.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Errors
  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Optimizer.Cache
  alias Dsxir.Optimizer.LabeledFewShot
  alias Dsxir.Optimizer.MIPROv2.Auto
  alias Dsxir.Optimizer.MIPROv2.Candidates
  alias Dsxir.Optimizer.MIPROv2.Proposer.DatasetSummarizer
  alias Dsxir.Optimizer.MIPROv2.Proposer.Grounded
  alias Dsxir.Optimizer.MIPROv2.Proposer.ProgramSummarizer
  alias Dsxir.Optimizer.MIPROv2.Sampler
  alias Dsxir.Optimizer.MIPROv2.Stats
  alias Dsxir.Optimizer.MIPROv2.Trial
  alias Dsxir.Optimizer.Search.TPE
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime, as: SignatureRuntime
  alias Dsxir.Telemetry

  @default_auto :medium
  @default_sampler TPE
  @default_batch_size 4
  @default_minibatch_full_eval_steps 10
  @default_top_k_full_eval 4
  @default_seed 0
  @default_valset_fraction 0.2

  @impl Dsxir.Optimizer
  @doc """
  Compile `student` against `trainset` under `metric`.

  Returns `{:ok, program, stats}` on success or `{:error, exception}` on
  validation failure. See module doc for `opts`.
  """
  @spec compile(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t(), keyword()) ::
          Dsxir.Optimizer.result()
  def compile(_student, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def compile(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_function(metric, 3) and is_list(opts) do
    start = System.monotonic_time(:millisecond)
    cfg = resolve_config(opts)
    snapshot = Settings.snapshot()
    task_lm = Settings.resolve(:lm)
    proposer_lm = Keyword.get(opts, :proposer_lm, task_lm)

    Telemetry.emit(
      Telemetry.optimizer_start(),
      %{system_time: System.system_time()},
      %{optimizer: __MODULE__, trainset_size: length(trainset), error_class: nil}
    )

    result =
      Cache.with_compile_cache(cfg.compile_cache, fn tid ->
        do_compile(student, trainset, metric, cfg, snapshot, proposer_lm, tid)
      end)

    finalize(result, start)
  end

  defp finalize({:ok, compiled, %Stats{} = stats}, start) do
    elapsed = System.monotonic_time(:millisecond) - start
    stats = %{stats | wall_clock_ms: elapsed}

    Telemetry.emit(
      Telemetry.optimizer_stop(),
      %{
        duration_ms: elapsed,
        task_lm_calls: stats.total_task_lm_calls,
        proposer_calls: stats.proposer_calls,
        cached_calls: stats.total_cached_calls
      },
      %{optimizer: __MODULE__, best_score: stats.best_score, error_class: nil}
    )

    {:ok, stamp_metadata(compiled, stats), stats}
  end

  defp finalize({:error, _} = err, _start), do: err

  defp resolve_config(opts) do
    auto_level = Keyword.get(opts, :auto, @default_auto)
    expanded = Auto.expand(opts, auto_level)

    %{
      num_trials: Keyword.fetch!(expanded, :num_trials),
      num_instruction_candidates: Keyword.fetch!(expanded, :num_instruction_candidates),
      num_demo_sets: Keyword.fetch!(expanded, :num_demo_sets),
      minibatch_size: Keyword.fetch!(expanded, :minibatch_size),
      sampler: Keyword.get(expanded, :sampler, @default_sampler),
      sampler_opts: Keyword.get(expanded, :sampler_opts, []),
      batch_size: Keyword.get(expanded, :batch_size, @default_batch_size),
      minibatch_full_eval_steps:
        Keyword.get(expanded, :minibatch_full_eval_steps, @default_minibatch_full_eval_steps),
      top_k_full_eval: Keyword.get(expanded, :top_k_full_eval, @default_top_k_full_eval),
      seed: Keyword.get(expanded, :seed, @default_seed),
      valset_fraction: Keyword.get(expanded, :valset_fraction, @default_valset_fraction),
      compile_cache: Keyword.get(expanded, :compile_cache, true),
      tip: Keyword.get(expanded, :tip)
    }
  end

  defp do_compile(student, trainset, metric, cfg, snapshot, proposer_lm, tid) do
    {trainsplit, valset} = split_trainset(trainset, cfg.seed, cfg.valset_fraction)
    minibatch_size = effective_minibatch(valset, cfg.minibatch_size)

    decls = Dsxir.Program.Source.predictors(student.source)
    current_instructions = current_instructions(student, decls)
    demo_bundles = bootstrap_demos(student, trainsplit, metric, cfg, decls)

    {program_summary, dataset_summary, proposer_calls_summary, summary_degraded} =
      summarize(decls, trainsplit, proposer_lm)

    {proposed_instructions, proposer_calls_inst, proposer_degraded} =
      propose_instructions(decls, program_summary, dataset_summary, cfg, proposer_lm)

    candidates = Candidates.build(current_instructions, proposed_instructions, demo_bundles)

    sampler_state =
      cfg.sampler.init(candidates.space, Keyword.put_new(cfg.sampler_opts, :seed, cfg.seed))

    initial = %{
      sampler: sampler_state,
      history: [],
      trials: [],
      full_evals: [],
      trial_count: 0,
      task_lm_calls: 0,
      cached_calls: 0
    }

    final =
      run_search(initial, %{
        program: student,
        candidates: candidates,
        cfg: cfg,
        minibatch: valset_minibatch(valset, minibatch_size, cfg.seed),
        valset: valset,
        metric: metric,
        cache_tid: tid,
        snapshot: snapshot
      })

    {best_score, best_config} = pick_best(final.full_evals, final.trials)

    stats = %Stats{
      best_score: best_score,
      best_config: best_config,
      trials: Enum.reverse(final.trials),
      full_evals: Enum.reverse(final.full_evals),
      proposer_calls: proposer_calls_summary + proposer_calls_inst,
      total_task_lm_calls: final.task_lm_calls,
      total_cached_calls: final.cached_calls,
      program_summary: program_summary,
      dataset_summary: dataset_summary,
      degraded: summary_degraded or proposer_degraded
    }

    compiled = apply_best_config(student, candidates, best_config)
    {:ok, compiled, stats}
  end

  defp split_trainset(trainset, seed, fraction) do
    indexed = Enum.with_index(trainset)

    shuffled =
      Enum.sort_by(indexed, fn {_ex, idx} -> :erlang.phash2({seed, idx}) end)
      |> Enum.map(fn {ex, _} -> ex end)

    n = length(shuffled)
    val_count = max(1, min(n - 1, round(n * fraction)))

    case n do
      1 -> {shuffled, shuffled}
      _ -> {Enum.drop(shuffled, val_count), Enum.take(shuffled, val_count)}
    end
  end

  defp effective_minibatch(valset, requested) do
    case length(valset) do
      0 -> requested
      n -> min(requested, n)
    end
  end

  defp valset_minibatch(valset, size, seed) do
    indexed = Enum.with_index(valset)

    indexed
    |> Enum.sort_by(fn {_ex, idx} -> :erlang.phash2({:minibatch, seed, idx}) end)
    |> Enum.take(size)
    |> Enum.map(fn {ex, _} -> ex end)
  end

  defp current_instructions(%Program{predictors: predictors}, decls) do
    Map.new(decls, fn decl ->
      override =
        case Map.get(predictors, decl.name) do
          %Program.State{instructions_override: inst} when is_binary(inst) -> inst
          _ -> nil
        end

      instruction = override || SignatureRuntime.instruction(decl.signature)
      {decl.name, instruction}
    end)
  end

  defp bootstrap_demos(student, trainset, metric, cfg, decls) do
    n = cfg.num_demo_sets
    half = max(1, div(n, 2))
    labeled_count = half
    bootstrap_count = max(1, n - half)

    labeled_bundles =
      for offset <- 0..(labeled_count - 1) do
        labeled_bundle(student, trainset, cfg.seed + offset)
      end

    bootstrap_bundles =
      for offset <- 0..(bootstrap_count - 1) do
        bootstrap_bundle(student, trainset, metric, cfg.seed + offset)
      end

    bundles = labeled_bundles ++ bootstrap_bundles

    Map.new(decls, fn decl ->
      per_predictor = Enum.map(bundles, &extract_demos(&1, decl.name))
      {decl.name, per_predictor}
    end)
  end

  defp extract_demos(compiled, predictor_name) do
    case Map.get(compiled.predictors, predictor_name) do
      %Program.State{demos: demos} -> demos
      _ -> []
    end
  end

  defp labeled_bundle(student, trainset, seed) do
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})

    case LabeledFewShot.compile(student, trainset, nil,
           max_labeled_demos: 4,
           deterministic: false
         ) do
      {:ok, compiled, _stats} -> compiled
      {:error, _} -> student
    end
  end

  defp bootstrap_bundle(student, trainset, metric, seed) do
    :rand.seed(:exsplus, {seed, seed + 1, seed + 2})

    case BootstrapFewShot.compile(student, trainset, metric,
           max_labeled_demos: 0,
           max_bootstrapped_demos: 4,
           max_rounds: 1,
           threshold: 0.0,
           deterministic: false
         ) do
      {:ok, compiled, _stats} -> compiled
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

  defp summarize(decls, trainset, proposer_lm) do
    {program_summary, p_calls_p, p_degraded} = run_program_summary(decls, proposer_lm)

    {dataset_summary, p_calls_d, d_degraded} = run_dataset_summary(trainset, proposer_lm)

    {program_summary, dataset_summary, p_calls_p + p_calls_d, p_degraded or d_degraded}
  end

  defp run_program_summary(decls, {_mod, _cfg} = lm) do
    case safe_call(fn -> ProgramSummarizer.run(decls, lm) end) do
      {:ok, summary} ->
        emit_proposer(:program_summary, :ok)
        {summary, 1, false}

      {:error, _} ->
        emit_proposer(:program_summary, :error)
        {"", 1, true}
    end
  end

  defp run_program_summary(_decls, _other), do: {"", 0, true}

  defp run_dataset_summary(trainset, {_mod, _cfg} = lm) do
    case safe_call(fn -> DatasetSummarizer.run(trainset, lm, sample_size: 5) end) do
      {:ok, summary} ->
        emit_proposer(:dataset_summary, :ok)
        {summary, 1, false}

      {:error, _} ->
        emit_proposer(:dataset_summary, :error)
        {"", 1, true}
    end
  end

  defp run_dataset_summary(_trainset, _other), do: {"", 0, true}

  defp safe_call(fun) do
    fun.()
  rescue
    e in [
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
      {:error, e}
  end

  defp propose_instructions(decls, program_summary, dataset_summary, cfg, {_mod, _cfg} = lm) do
    Enum.reduce(decls, {%{}, 0, false}, fn decl, acc ->
      args = %{
        program_summary: program_summary,
        dataset_summary: dataset_summary,
        predictor_decl: decl,
        tip: cfg.tip,
        n_candidates: cfg.num_instruction_candidates,
        lm: lm
      }

      reduce_proposed(decl, safe_call(fn -> Grounded.run(args) end), acc)
    end)
  end

  defp propose_instructions(decls, _psum, _dsum, _cfg, _no_lm) do
    proposed = Map.new(decls, fn decl -> {decl.name, []} end)
    {proposed, 0, true}
  end

  defp reduce_proposed(decl, {:ok, candidates}, {acc, calls, degraded}) do
    emit_proposer(:grounded, :ok, %{predictor: decl.name})
    {Map.put(acc, decl.name, candidates), calls + 1, degraded}
  end

  defp reduce_proposed(decl, {:error, _}, {acc, calls, _degraded}) do
    emit_proposer(:grounded, :error, %{predictor: decl.name})
    {Map.put(acc, decl.name, []), calls + 1, true}
  end

  defp emit_proposer(stage, outcome, extra \\ %{}) do
    Telemetry.emit(
      Telemetry.miprov2_proposer(),
      %{system_time: System.system_time()},
      Map.merge(%{optimizer: __MODULE__, stage: stage, outcome: outcome}, extra)
    )
  end

  defp run_search(state, ctx) do
    if state.trial_count >= ctx.cfg.num_trials do
      state
    else
      remaining = ctx.cfg.num_trials - state.trial_count
      batch = min(ctx.cfg.batch_size, remaining)
      {configs, sampler} = ctx.cfg.sampler.suggest(state.sampler, state.history, batch)

      records = run_batch(configs, ctx, state.trial_count)
      observations = Enum.map(records, fn r -> %{config: r.config, score: r.score} end)
      sampler = ctx.cfg.sampler.observe(sampler, observations)

      Enum.each(records, &emit_trial/1)

      new_trial_count = state.trial_count + length(records)
      trials = Enum.reverse(records) ++ state.trials

      lm_calls = state.task_lm_calls + Enum.sum(Enum.map(records, & &1.lm_calls))
      cached_calls = state.cached_calls + Enum.sum(Enum.map(records, & &1.cached_calls))

      {full_evals, lm_calls, cached_calls} =
        maybe_full_eval(state, records, new_trial_count, ctx, lm_calls, cached_calls)

      next = %{
        state
        | sampler: sampler,
          history: state.history ++ observations,
          trials: trials,
          full_evals: full_evals,
          trial_count: new_trial_count,
          task_lm_calls: lm_calls,
          cached_calls: cached_calls
      }

      run_search(next, ctx)
    end
  end

  defp run_batch(configs, ctx, base_idx) do
    configs
    |> Enum.with_index()
    |> Enum.map(fn {config, offset} ->
      Trial.run(%{
        program: ctx.program,
        config: config,
        candidates: ctx.candidates,
        examples: ctx.minibatch,
        metric: ctx.metric,
        cache_tid: ctx.cache_tid,
        settings_snapshot: ctx.snapshot,
        trial_index: base_idx + offset,
        batch_size: max(1, ctx.cfg.batch_size)
      })
    end)
  end

  defp maybe_full_eval(state, _records, trial_count, ctx, lm_calls, cached_calls) do
    if trial_count > 0 and rem(trial_count, ctx.cfg.minibatch_full_eval_steps) == 0 do
      candidates_to_rerank =
        [state.trials, Enum.reverse(state.full_evals)]
        |> Enum.concat()
        |> rerank_pool(ctx.cfg.top_k_full_eval)

      reranked =
        Enum.map(candidates_to_rerank, fn record ->
          Trial.run(%{
            program: ctx.program,
            config: record.config,
            candidates: ctx.candidates,
            examples: ctx.valset,
            metric: ctx.metric,
            cache_tid: ctx.cache_tid,
            settings_snapshot: ctx.snapshot,
            trial_index: record.trial_index,
            batch_size: max(1, ctx.cfg.batch_size)
          })
        end)

      Telemetry.emit(
        Telemetry.miprov2_rerank(),
        %{at_trial: trial_count, top_k_size: length(reranked)},
        %{optimizer: __MODULE__}
      )

      added_lm = Enum.sum(Enum.map(reranked, & &1.lm_calls))
      added_cached = Enum.sum(Enum.map(reranked, & &1.cached_calls))

      {Enum.reverse(reranked) ++ state.full_evals, lm_calls + added_lm,
       cached_calls + added_cached}
    else
      {state.full_evals, lm_calls, cached_calls}
    end
  end

  defp rerank_pool(records, top_k) do
    records
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(top_k)
  end

  defp emit_trial(record) do
    Telemetry.emit(
      Telemetry.optimizer_trial(),
      %{score: record.score},
      %{
        optimizer: __MODULE__,
        round: 1,
        example_index: record.trial_index,
        kept: true,
        error_class: nil
      }
    )
  end

  defp pick_best([], []), do: {nil, %{}}

  defp pick_best([], trials) do
    best = Enum.max_by(trials, & &1.score)
    {best.score, best.config}
  end

  defp pick_best(full_evals, _trials) do
    best = Enum.max_by(full_evals, & &1.score)
    {best.score, best.config}
  end

  defp apply_best_config(student, _candidates, config) when map_size(config) == 0, do: student

  defp apply_best_config(%Program{predictors: predictors} = student, candidates, config) do
    resolved = Candidates.resolve(candidates, config)

    new_predictors =
      Enum.reduce(resolved, predictors, fn {name, %{instruction: inst, demos: demos}}, acc ->
        case Map.fetch(acc, name) do
          {:ok, state} ->
            Map.put(acc, name, %{state | instructions_override: inst, demos: demos})

          :error ->
            acc
        end
      end)

    %{student | predictors: new_predictors}
  end

  defp stamp_metadata(%Program{metadata: metadata} = program, %Stats{} = stats) do
    metadata =
      metadata
      |> Map.put(:compiled_with, __MODULE__)
      |> Map.put(:score, stats.best_score)
      |> Map.put(:_miprov2_stats, stats)

    %{program | metadata: metadata}
  end

  @impl Dsxir.Optimizer
  @doc """
  Prepare a resumable MIPROv2 session.

  Performs the one-time, expensive proposer LM calls (program summary, dataset
  summary, grounded instruction proposals) and bootstraps the demo bundles so
  the resulting `Dsxir.Optimizer.MIPROv2.Sampler` can be checkpointed and the
  proposer never has to be called again across `step/6` invocations.

  The returned planned-trial count equals `cfg.num_trials`.
  """
  @spec init_session(Program.t(), [Dsxir.Example.t()], nil | Dsxir.Metric.t(), keyword()) ::
          {:ok, Sampler.t(), pos_integer()} | {:error, Exception.t()}
  def init_session(_program, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def init_session(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_list(opts) and (is_function(metric, 3) or is_nil(metric)) do
    cfg = resolve_config(opts)
    task_lm = Settings.resolve(:lm)
    proposer_lm = Keyword.get(opts, :proposer_lm, task_lm)

    {trainsplit, valset} = split_trainset(trainset, cfg.seed, cfg.valset_fraction)
    minibatch_size = effective_minibatch(valset, cfg.minibatch_size)

    decls = Dsxir.Program.Source.predictors(student.source)
    current_instructions = current_instructions(student, decls)
    demo_bundles = bootstrap_demos(student, trainsplit, metric, cfg, decls)

    {program_summary, dataset_summary, proposer_calls_summary, summary_degraded} =
      summarize(decls, trainsplit, proposer_lm)

    {proposed_instructions, proposer_calls_inst, proposer_degraded} =
      propose_instructions(decls, program_summary, dataset_summary, cfg, proposer_lm)

    candidates = Candidates.build(current_instructions, proposed_instructions, demo_bundles)

    tpe_state =
      cfg.sampler.init(candidates.space, Keyword.put_new(cfg.sampler_opts, :seed, cfg.seed))

    sampler = %Sampler{
      tpe_state: tpe_state,
      candidates: candidates,
      proposer_summaries: %{
        program_summary: program_summary,
        dataset_summary: dataset_summary,
        degraded: summary_degraded or proposer_degraded
      },
      rng_seed: cfg.seed,
      config: cfg,
      best_so_far: nil,
      trial_records: [],
      full_evals: [],
      proposer_calls: proposer_calls_summary + proposer_calls_inst,
      batch_size: cfg.batch_size,
      minibatch_full_eval_steps: cfg.minibatch_full_eval_steps,
      top_k_full_eval: cfg.top_k_full_eval,
      total_planned_trials: cfg.num_trials,
      minibatch: valset_minibatch(valset, minibatch_size, cfg.seed),
      valset: valset,
      sampler_module: cfg.sampler
    }

    {:ok, sampler, cfg.num_trials}
  end

  @impl Dsxir.Optimizer
  @doc """
  Run a single trial against the session sampler.

  Returns `{:halt, sampler, :budget_exhausted}` once the trial budget is met,
  otherwise asks the underlying sampler module for one config, runs it through
  `Trial.run/1` on the cached minibatch, and returns a `trial_result` map with
  the nine keys expected by `Dsxir.OptimizerSession`.

  Session mode skips the periodic full-valset rerank that `compile/4` runs.

  Exceptions from the trial pipeline are caught and reported as
  `status: :error` trials rather than crashing the session.
  """
  @spec step(
          Sampler.t(),
          non_neg_integer(),
          Program.t(),
          [Dsxir.Example.t()],
          nil | Dsxir.Metric.t(),
          keyword()
        ) :: {:cont, Sampler.t(), map()} | {:halt, Sampler.t(), :budget_exhausted}
  def step(%Sampler{} = sampler, trial_idx, %Program{} = program, _trainset, metric, _opts) do
    if length(sampler.trial_records) >= sampler.total_planned_trials do
      {:halt, sampler, :budget_exhausted}
    else
      do_step(sampler, trial_idx, program, metric)
    end
  end

  defp do_step(%Sampler{} = sampler, trial_idx, program, metric) do
    start = System.monotonic_time(:millisecond)
    history = build_history(sampler.trial_records)

    {[config], next_tpe} = sampler.sampler_module.suggest(sampler.tpe_state, history, 1)

    try do
      record =
        Trial.run(%{
          program: program,
          config: config,
          candidates: sampler.candidates,
          examples: sampler.minibatch,
          metric: metric,
          cache_tid: nil,
          settings_snapshot: Settings.snapshot(),
          trial_index: trial_idx,
          batch_size: max(1, sampler.batch_size)
        })

      next_tpe =
        sampler.sampler_module.observe(next_tpe, [%{config: config, score: record.score}])

      candidate_program = apply_best_config(program, sampler.candidates, config)
      candidate_id = candidate_id_for(config)

      trial = %{
        trial_idx: trial_idx,
        candidate_id: candidate_id,
        score: record.score,
        status: :ok,
        stats: %{
          lm_calls: record.lm_calls,
          cached_calls: record.cached_calls,
          trial_duration_ms: record.duration_ms,
          config: config
        },
        duration_ms: System.monotonic_time(:millisecond) - start,
        error: nil,
        error_class: nil,
        candidate_program: candidate_program
      }

      best_so_far = update_best(sampler.best_so_far, record.score, candidate_program)

      next = %{
        sampler
        | tpe_state: next_tpe,
          trial_records: [record_summary(record, candidate_id) | sampler.trial_records],
          best_so_far: best_so_far
      }

      {:cont, next, trial}
    rescue
      e ->
        trial = %{
          trial_idx: trial_idx,
          candidate_id: candidate_id_for(config),
          score: nil,
          status: :error,
          stats: %{config: config},
          duration_ms: System.monotonic_time(:millisecond) - start,
          error: e,
          error_class: Errors.class_of(e),
          candidate_program: nil
        }

        next = %{
          sampler
          | tpe_state: next_tpe,
            trial_records: [
              %{trial_idx: trial_idx, score: nil, config: config, status: :error}
              | sampler.trial_records
            ]
        }

        {:cont, next, trial}
    end
  end

  defp build_history(trial_records) do
    trial_records
    |> Enum.reverse()
    |> Enum.filter(fn r -> Map.get(r, :status) != :error and not is_nil(Map.get(r, :score)) end)
    |> Enum.map(fn r -> %{config: r.config, score: r.score} end)
  end

  defp record_summary(%Stats.Record{} = record, candidate_id) do
    %{
      trial_idx: record.trial_index,
      score: record.score,
      config: record.config,
      candidate_id: candidate_id,
      status: :ok,
      lm_calls: record.lm_calls,
      cached_calls: record.cached_calls
    }
  end

  defp candidate_id_for(config) do
    digest = :erlang.phash2(config)
    "miprov2-c#{digest}"
  end

  defp update_best(nil, score, program) when is_float(score), do: {score, program}

  defp update_best({best, _} = current, score, program) when is_float(score) do
    if score > best, do: {score, program}, else: current
  end

  defp update_best(current, _score, _program), do: current

  @impl Dsxir.Optimizer
  @spec serialize_state(Sampler.t()) :: {:ok, binary(), 1}
  def serialize_state(%Sampler{} = sampler) do
    {:ok, :erlang.term_to_binary(sampler, [:deterministic]), 1}
  end

  @impl Dsxir.Optimizer
  @spec deserialize_state(binary(), pos_integer()) ::
          {:ok, Sampler.t()} | {:error, :version_mismatch | {:bad_sampler_shape, term()}}
  def deserialize_state(blob, 1) when is_binary(blob) do
    case :erlang.binary_to_term(blob, [:safe]) do
      %Sampler{} = sampler -> {:ok, sampler}
      other -> {:error, {:bad_sampler_shape, other}}
    end
  end

  def deserialize_state(_blob, _version), do: {:error, :version_mismatch}
end
