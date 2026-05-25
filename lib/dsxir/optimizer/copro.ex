defmodule Dsxir.Optimizer.COPRO do
  @moduledoc """
  Coordinate-ascent instruction optimizer. Port of DSPy's COPRO.

  COPRO optimizes per-predictor instructions only (no demos). Each round it
  asks a proposer LM for a breadth of candidate instructions per predictor,
  evaluates every candidate as a whole program (the other predictors held at
  their current committed override), and at the end of the round commits each
  predictor's strict round winner. The next round's proposer is grounded in the
  predictor's scored attempt history. After `depth` rounds the committed
  overrides are applied to the student and returned.

  The pure coordinate-ascent state and its transitions live in
  `Dsxir.Optimizer.COPRO.Sampler`; this module owns the IO — proposer (LM)
  calls via `Dsxir.Optimizer.COPRO.Proposer` and whole-program scoring via
  `Dsxir.Optimizer.COPRO.Evaluator` — and threads the sampler through.

  ## Quick start

      {:ok, compiled, stats} =
        Dsxir.compile(
          Dsxir.Optimizer.COPRO,
          program,
          trainset,
          metric,
          auto: :light
        )

  ## Options

  See `Dsxir.Optimizer.COPRO.Auto` for the `:light | :medium | :heavy` presets
  controlling `:breadth`, `:depth`, and `:init_temperature`.

    * `:auto` (default `:medium`) — budget preset.
    * `:proposer_lm` — `{module, config}` tuple for instruction proposals.
      Defaults to the resolved task LM.

  ## Returned stats

  `t:Dsxir.Optimizer.COPRO.Stats.t/0`. Notable fields:

    * `:best_score` — whole-program score under the committed overrides.
    * `:best_instructions` — the committed per-predictor overrides.
    * `:rounds` — committed rounds (equals `cfg.depth` on a full run).
    * `:trials` — per-candidate `Dsxir.Optimizer.COPRO.Stats.Record` list.
    * `:proposer_calls` — proposer LM calls issued.
    * `:degraded` — `true` when any proposer call failed and was substituted
      with the predictor's current best instruction.

  Under `compile/4` the reported `best_score` is a single confirmatory
  whole-program evaluation under the committed `best_overrides` after the final
  round commits, so it reflects the program actually returned rather than a
  per-predictor candidate maximum.

  In session mode (`Dsxir.OptimizerSession`) `best_program`/`best_score` are
  selected by the session from the highest-scoring individual trial, and each
  COPRO trial's candidate program changes only one predictor's instruction. So
  for a program where more than one predictor improves, a session run can return
  a different program and score than `compile/4`, which applies every committed
  override at once. This mirrors `Dsxir.Optimizer.MIPROv2`'s session behaviour.

  Wrapper-only bookkeeping (proposer call count, degraded flag, per-candidate
  `Stats.Record` list) lives in first-class `Sampler` fields so session-mode
  `step/6` callers can checkpoint it; it serializes and survives `Sampler`
  transitions transparently.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Errors
  alias Dsxir.Optimizer.COPRO.Auto
  alias Dsxir.Optimizer.COPRO.Evaluator
  alias Dsxir.Optimizer.COPRO.Proposer
  alias Dsxir.Optimizer.COPRO.Sampler
  alias Dsxir.Optimizer.COPRO.Stats
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime, as: SignatureRuntime
  alias Dsxir.Telemetry

  @copro_trial [:dsxir, :optimizer, :copro, :trial]
  @copro_round [:dsxir, :optimizer, :copro, :round]

  @impl Dsxir.Optimizer
  @doc """
  Compile `student` against `trainset` under `metric`.

  Returns `{:ok, program, stats}` on success or `{:error, exception}` on
  validation failure. See the module doc for `opts`.
  """
  @spec compile(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t(), keyword()) ::
          Dsxir.Optimizer.result()
  def compile(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_function(metric, 3) and is_list(opts) do
    start = System.monotonic_time(:millisecond)

    Telemetry.emit(
      Telemetry.optimizer_start(),
      %{system_time: System.system_time()},
      %{optimizer: __MODULE__, trainset_size: length(trainset), error_class: nil}
    )

    result = do_compile(student, trainset, metric, opts)
    breadth = Auto.expand(opts, opts[:auto] || :medium).breadth
    finalize(result, student, metric, start, breadth)
  end

  @doc """
  Like `compile/4` but raises the validation exception on `{:error, _}`.
  """
  @spec compile!(Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t(), keyword()) ::
          {Program.t(), Stats.t()}
  def compile!(%Program{} = student, trainset, metric, opts) do
    case compile(student, trainset, metric, opts) do
      {:ok, compiled, stats} -> {compiled, stats}
      {:error, exception} -> raise exception
    end
  end

  defp do_compile(student, trainset, metric, opts) do
    case init_session(student, trainset, metric, opts) do
      {:ok, sampler, _total} ->
        final = drive_loop(sampler, 0, student, trainset, metric, opts)
        compiled = apply_overrides(student, final.best_overrides)
        {:ok, compiled, final}

      {:error, _} = err ->
        err
    end
  end

  defp drive_loop(sampler, idx, student, trainset, metric, opts) do
    case step(sampler, idx, student, trainset, metric, opts) do
      {:cont, next, _trial_result} ->
        drive_loop(next, idx + 1, student, trainset, metric, opts)

      {:halt, next, _reason} ->
        next
    end
  end

  defp finalize({:ok, compiled, %Sampler{} = sampler}, student, metric, start, breadth) do
    elapsed = System.monotonic_time(:millisecond) - start
    {best_score, sampler} = confirm_best_score(sampler, student, metric)
    stats = build_stats(sampler, best_score, elapsed, breadth)

    Telemetry.emit(
      Telemetry.optimizer_stop(),
      %{duration: elapsed, score: stats.best_score},
      %{optimizer: __MODULE__, trainset_size: length(sampler.evalset), error_class: nil}
    )

    {:ok, stamp_metadata(compiled, stats), stats}
  end

  defp finalize({:error, exception} = err, _student, _metric, start, _breadth) do
    elapsed = System.monotonic_time(:millisecond) - start

    Telemetry.emit(
      Telemetry.optimizer_stop(),
      %{duration: elapsed, score: nil},
      %{optimizer: __MODULE__, trainset_size: 0, error_class: Errors.class_of(exception)}
    )

    err
  end

  @impl Dsxir.Optimizer
  @doc """
  Prepare a resumable COPRO session.

  Expands the budget preset, validates the trainset and predictor set, scores
  the seed program once to seed the round baseline, and builds the round-zero
  candidate queue via the basic proposer. The returned planned-trial count is
  `cfg.depth * length(predictors) * cfg.breadth`.
  """
  @spec init_session(Program.t(), [Dsxir.Example.t()], nil | Dsxir.Metric.t(), keyword()) ::
          {:ok, Sampler.t(), pos_integer()} | {:error, Exception.t()}
  def init_session(_program, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def init_session(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_list(opts) and (is_function(metric, 3) or is_nil(metric)) do
    cfg = Auto.expand(opts, opts[:auto] || :medium)
    decls = Program.Source.predictors(student.source)

    case decls do
      [] ->
        {:error, %Errors.Invalid.Trainset{reason: :no_predictors, example: nil}}

      decls ->
        build_session(student, trainset, metric, opts, cfg, decls)
    end
  end

  defp build_session(student, trainset, metric, opts, cfg, decls) do
    proposer_lm = opts[:proposer_lm] || Settings.resolve(:lm)
    base_overrides = current_instructions(student, decls)

    {:ok, base_score, _errors} = Evaluator.run(student, trainset, metric, cfg)

    total = cfg.depth * length(decls) * cfg.breadth

    base =
      Sampler.new(
        seed_program: student,
        decls: decls,
        evalset: trainset,
        total_planned_trials: total,
        best_overrides: base_overrides
      )

    seed =
      %{
        base
        | best_score: base_score,
          round_best:
            Map.new(decls, fn d ->
              {d.name, %{instruction: base_overrides[d.name], score: base_score}}
            end),
          history: seed_history(decls, base_overrides, base_score)
      }

    ctx = %{cfg: cfg, proposer_lm: proposer_lm}
    {queue, sampler} = build_round_queue(seed, :basic, ctx)

    {:ok, %{sampler | queue: queue}, total}
  end

  defp seed_history(decls, base_overrides, base_score) do
    Map.new(decls, fn d ->
      {d.name, [%{instruction: base_overrides[d.name], score: base_score, round: 0}]}
    end)
  end

  @impl Dsxir.Optimizer
  @doc """
  Run a single COPRO trial against the session sampler.

  Halts once the planned trial budget is met. Otherwise pops the next candidate,
  applies it on top of the current best overrides, scores the whole program,
  records the result, and returns a `trial_result` map. When the round queue is
  exhausted it commits the round; if the depth budget is not yet spent it builds
  the next round's queue (grounded in the attempt history) and re-enters to
  return one evaluated trial.
  """
  @spec step(
          Sampler.t(),
          non_neg_integer(),
          Program.t(),
          [Dsxir.Example.t()],
          nil | Dsxir.Metric.t(),
          keyword()
        ) :: {:cont, Sampler.t(), map()} | {:halt, Sampler.t(), term()}
  def step(%Sampler{} = sampler, trial_idx, %Program{} = _program, _trainset, metric, opts) do
    if Sampler.attempts_left?(sampler) do
      do_step(sampler, trial_idx, metric, opts)
    else
      flush_on_exhaustion(sampler)
    end
  end

  defp flush_on_exhaustion(%Sampler{queue: [_ | _]} = sampler) do
    {:halt, sampler, :budget_exhausted}
  end

  defp flush_on_exhaustion(%Sampler{queue: []} = sampler) do
    {committed, improved} = Sampler.commit_round(sampler)

    Telemetry.emit(
      @copro_round,
      %{improved: improved, best_score: committed.best_score},
      %{optimizer: __MODULE__, round: committed.round}
    )

    {:halt, committed, :budget_exhausted}
  end

  defp do_step(%Sampler{} = sampler, trial_idx, metric, opts) when is_list(opts) do
    do_step(sampler, trial_idx, metric, build_ctx(opts))
  end

  defp do_step(%Sampler{} = sampler, trial_idx, metric, %{cfg: _} = ctx) do
    case Sampler.dequeue(sampler) do
      {item, s} ->
        run_trial(s, item, trial_idx, metric, ctx)

      :empty ->
        advance_or_halt(sampler, trial_idx, metric, ctx)
    end
  end

  defp run_trial(%Sampler{} = s, item, trial_idx, metric, ctx) do
    start = System.monotonic_time(:millisecond)
    overrides = Map.put(s.best_overrides, item.predictor, item.instruction)
    program = apply_overrides(s.seed_program, overrides)

    {:ok, score, errors} = Evaluator.run(program, s.evalset, metric, ctx.cfg)
    status = classify_trial(score, errors, s.evalset)

    prev_best = get_in(s.round_best, [item.predictor, :score])
    accepted? = is_nil(prev_best) or score > prev_best

    s = Sampler.record_trial(s, item, score)
    duration = System.monotonic_time(:millisecond) - start

    record = %Stats.Record{
      trial_index: trial_idx,
      round: s.round,
      predictor: item.predictor,
      instruction: item.instruction,
      score: score,
      accepted?: accepted?,
      duration_ms: duration
    }

    s = append_record(s, record)

    Telemetry.emit(
      @copro_trial,
      %{score: score},
      %{
        optimizer: __MODULE__,
        round: s.round,
        predictor: item.predictor,
        example_index: trial_idx,
        kept: accepted?,
        status: status,
        error_class: nil
      }
    )

    {:cont, s, trial_result(trial_idx, item, score, status, duration, program)}
  end

  defp advance_or_halt(%Sampler{} = sampler, trial_idx, metric, ctx) do
    {committed, improved} = Sampler.commit_round(sampler)

    Telemetry.emit(
      @copro_round,
      %{improved: improved, best_score: committed.best_score},
      %{optimizer: __MODULE__, round: committed.round}
    )

    if committed.round + 1 >= ctx.cfg.depth do
      {:halt, committed, :depth_exhausted}
    else
      {queue, advanced} = build_round_queue(committed, :given_attempts, ctx)
      advanced = Sampler.enqueue_round(advanced, queue)
      do_step(advanced, trial_idx, metric, ctx)
    end
  end

  @impl Dsxir.Optimizer
  @spec serialize_state(Sampler.t()) :: {:ok, binary(), 1}
  def serialize_state(%Sampler{} = sampler), do: Sampler.serialize_state(sampler)

  @impl Dsxir.Optimizer
  @spec deserialize_state(binary(), pos_integer()) ::
          {:ok, Sampler.t()}
          | {:error, :version_mismatch | :corrupt_blob | {:bad_sampler_shape, term()}}
  def deserialize_state(blob, version), do: Sampler.deserialize_state(blob, version)

  defp build_round_queue(%Sampler{} = sampler, kind, ctx) do
    decls = Enum.sort_by(sampler.decls, & &1.name)

    {by_predictor, sampler} =
      Enum.reduce(decls, {%{}, sampler}, fn decl, {acc, s} ->
        {candidates, s} = propose_for(decl, kind, s, ctx)
        {Map.put(acc, decl.name, candidates), s}
      end)

    queue =
      for decl <- decls,
          {instruction, _index} <- Enum.with_index(Map.fetch!(by_predictor, decl.name)) do
        %{predictor: decl.name, instruction: instruction, source: kind}
      end

    {queue, sampler}
  end

  defp propose_for(decl, kind, %Sampler{} = s, ctx) do
    proposer_ctx = proposer_ctx(decl, kind, s, ctx)

    case Proposer.propose(proposer_ctx) do
      {:ok, candidates} ->
        {candidates, bump_proposer_calls(s)}

      {:error, _} ->
        fallback = [s.best_overrides[decl.name]]
        {fallback, s |> bump_proposer_calls() |> mark_degraded()}
    end
  end

  defp proposer_ctx(decl, :basic, %Sampler{} = s, ctx) do
    %{
      kind: :basic,
      decl: decl,
      current_instruction: s.best_overrides[decl.name],
      n: ctx.cfg.breadth,
      temperature: ctx.cfg.init_temperature,
      lm: ctx.proposer_lm
    }
  end

  defp proposer_ctx(decl, :given_attempts, %Sampler{} = s, ctx) do
    attempts =
      s.history
      |> Map.get(decl.name, [])
      |> Enum.filter(fn entry -> is_number(entry.score) and is_binary(entry.instruction) end)
      |> Enum.map(fn entry -> %{instruction: entry.instruction, score: entry.score} end)

    %{
      kind: :given_attempts,
      decl: decl,
      attempts: attempts,
      n: ctx.cfg.breadth,
      temperature: ctx.cfg.init_temperature,
      lm: ctx.proposer_lm
    }
  end

  defp classify_trial(_score, errors, evalset) do
    if errors.count == length(evalset), do: :error, else: :ok
  end

  defp trial_result(trial_idx, item, score, status, duration, program) do
    %{
      trial_idx: trial_idx,
      candidate_id: candidate_id_for(item),
      score: score,
      status: status,
      stats: %{predictor: item.predictor, instruction: item.instruction, source: item.source},
      duration_ms: duration,
      error: nil,
      error_class: nil,
      candidate_program: program
    }
  end

  defp candidate_id_for(item) do
    "copro-#{item.predictor}-#{:erlang.phash2(item.instruction)}"
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

  defp apply_overrides(%Program{predictors: predictors} = program, overrides) do
    new_predictors =
      Enum.reduce(overrides, predictors, fn {name, inst}, acc ->
        case Map.fetch(acc, name) do
          {:ok, state} -> Map.put(acc, name, %{state | instructions_override: inst})
          :error -> acc
        end
      end)

    %{program | predictors: new_predictors}
  end

  defp confirm_best_score(%Sampler{} = sampler, student, metric) do
    program = apply_overrides(student, sampler.best_overrides)
    {:ok, score, _errors} = Evaluator.run(program, sampler.evalset, metric, %{})
    {score, %{sampler | best_score: score}}
  end

  defp build_stats(%Sampler{} = sampler, best_score, elapsed, breadth) do
    %Stats{
      best_score: best_score,
      best_instructions: sampler.best_overrides,
      rounds: sampler.round + 1,
      breadth: breadth,
      trials: Enum.reverse(sampler.trial_records),
      proposer_calls: sampler.proposer_calls,
      total_devset_evals: sampler.total_devset_evals,
      wall_clock_ms: elapsed,
      degraded: sampler.degraded
    }
  end

  defp stamp_metadata(%Program{metadata: metadata} = program, %Stats{} = stats) do
    metadata =
      metadata
      |> Map.put(:compiled_with, __MODULE__)
      |> Map.put(:score, stats.best_score)
      |> Map.put(:_copro_stats, stats)

    %{program | metadata: metadata}
  end

  defp build_ctx(opts) do
    cfg = Auto.expand(opts, opts[:auto] || :medium)
    proposer_lm = opts[:proposer_lm] || Settings.resolve(:lm)
    %{cfg: cfg, proposer_lm: proposer_lm}
  end

  defp bump_proposer_calls(%Sampler{} = s),
    do: %{s | proposer_calls: s.proposer_calls + 1}

  defp mark_degraded(%Sampler{} = s),
    do: %{s | degraded: true}

  defp append_record(%Sampler{} = s, record),
    do: %{s | trial_records: [record | s.trial_records]}
end
