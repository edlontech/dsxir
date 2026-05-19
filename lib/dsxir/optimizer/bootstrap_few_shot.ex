defmodule Dsxir.Optimizer.BootstrapFewShot do
  @moduledoc """
  Two-phase optimizer: slot labeled demos from the trainset (phase 1), then
  augment with bootstrapped demos captured from successful traces (phase 2).

  ## Phases

    1. **Labeled.** Up to `:max_labeled_demos` examples are picked from the
       trainset (uniform random; deterministic-by-hash when `:deterministic`
       is set). Each chosen example is slotted as `%Dsxir.Demo{kind: :labeled}`
       only into predictors whose declared input + output fields the demo's
       data keys cover; non-matching predictors get no labeled demo from
       that example. No LM call.

    2. **Bootstrap.** For each round in `1..max_rounds`, the trainset is
       walked example-by-example. For each example, the program is run inside
       a `Dsxir.with_trace/1` frame with per-call opts seeded for diversity
       (`temperature: cfg.diversity_temperature`, `cache: false`, plus a
       per-round per-example nonce). When the metric coerces to
       `>= :threshold`, each trace entry is pushed into the matching
       predictor's `demos_pool` as
       `%Dsxir.Demo{kind: :bootstrapped, source: %{round: R, example_index: I}}`
       until `:max_bootstrapped_demos` is reached.

  Diversity is delivered by pushing a `Dsxir.Settings.context/2` frame that
  swaps the resolved `:lm` config tuple with one carrying the diversity
  keywords. The LM dispatcher reads `:lm` from settings and merges per-call
  opts on top, so the temperature lever reaches the wire protocol.

  ## Options

    * `:max_labeled_demos` (default `4`) — cap on phase 1 demos per predictor.
    * `:max_bootstrapped_demos` (default `4`) — cap on phase 2 demos per predictor.
    * `:max_rounds` (default `1`) — number of bootstrap passes over the trainset.
    * `:threshold` (default `1.0`) — coerced metric must meet or exceed this to
      keep the trace. Accepted threshold types: `true | false | integer() |
      float()`. Booleans coerce to `1.0` / `0.0`. Other values raise
      `FunctionClauseError` during option parsing — bootstrap is a fail-fast
      operation on bad configuration.
    * `:max_errors` (default `10`) — aggregate cap on per-example errors.
      Exceeding returns a framework-classed error.
    * `:deterministic` (default `false`) — when `true`, phase 1 selection is
      hash-stable and phase-2 trainset order is hash-stable. Phase-2 LM
      outputs are still nondeterministic via temperature.
    * `:diversity_temperature` (default `1.0`) — temperature forwarded as
      per-call opt during phase 2.

  ## Returned stats

      %{
        labeled_demos: non_neg_integer(),
        bootstrapped_demos: non_neg_integer(),
        predictor_count: non_neg_integer(),
        rounds: non_neg_integer(),
        error_count: non_neg_integer(),
        max_errors: non_neg_integer(),
        threshold: float()
      }

  ## Errors

  Per-example raises are caught and stamped with
  `path: [:bootstrap_few_shot, :"round_R", :"example_I"]`. When
  `error_count > max_errors`, `compile/4` returns
  `{:error, %Dsxir.Errors.Framework.OptimizerError{optimizer: __MODULE__,
  inner: aggregate}}` where `inner` is an aggregate produced via Splode's
  `to_class` helper on `Dsxir.Errors`. Callers can traverse per-predictor
  sub-errors via Splode's `traverse_errors` helper.

  ## Trainset hash

  `metadata.trainset_hash` is
  `:crypto.hash(:sha256, :erlang.term_to_binary(trainset)) |> Base.encode16(case: :lower)`.

  ## Session mode

  `Dsxir.OptimizerSession.compile(BootstrapFewShot, ...)` walks the trainset one
  example at a time via `step/6`, halting with `:rounds_exhausted` after all
  `max_rounds` passes complete. Session mode preserves the per-round, per-example
  scheduling but does not bail out early when the pool fills; the trial budget
  matches `max_rounds * length(trainset)`.
  """

  @behaviour Dsxir.Optimizer

  alias Dsxir.Demo
  alias Dsxir.Errors
  alias Dsxir.Metric
  alias Dsxir.Module.Info, as: ModuleInfo
  alias Dsxir.Optimizer.BootstrapFewShot.Sampler
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Signature.Runtime, as: SignatureRuntime
  alias Dsxir.Telemetry

  @default_max_labeled_demos 4
  @default_max_bootstrapped_demos 4
  @default_max_rounds 1
  @default_threshold 1.0
  @default_max_errors 10
  @default_diversity_temperature 1.0

  @impl Dsxir.Optimizer
  def compile(_student, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def compile(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_function(metric, 3) and is_list(opts) do
    case validate_trainset(trainset) do
      :ok -> do_compile(student, trainset, metric, opts)
      {:error, %Errors.Invalid.Trainset{} = err} -> {:error, err}
    end
  end

  defp do_compile(student, trainset, metric, opts) do
    cfg = config(opts)
    start = System.monotonic_time()

    Telemetry.emit(
      Telemetry.optimizer_start(),
      %{system_time: System.system_time()},
      %{optimizer: __MODULE__, trainset_size: length(trainset), error_class: nil}
    )

    labeled = phase_one(trainset, cfg)
    {bootstrapped, errors} = phase_two(student, trainset, metric, cfg)
    error_count = length(errors)

    case classify_errors(errors, cfg.max_errors) do
      :ok ->
        compiled = slot_all(student, labeled, bootstrapped, trainset)
        stats = stats_for(labeled, bootstrapped, compiled, cfg, error_count)

        Telemetry.emit(
          Telemetry.optimizer_stop(),
          %{duration: System.monotonic_time() - start, score: nil},
          %{optimizer: __MODULE__, trainset_size: length(trainset), error_class: nil}
        )

        {:ok, compiled, stats}

      {:halt, aggregate} ->
        framework_error = %Errors.Framework.OptimizerError{
          optimizer: __MODULE__,
          inner: aggregate
        }

        Telemetry.emit(
          Telemetry.optimizer_stop(),
          %{duration: System.monotonic_time() - start, score: nil},
          %{
            optimizer: __MODULE__,
            trainset_size: length(trainset),
            error_class: :framework
          }
        )

        {:error, framework_error}
    end
  end

  defp config(opts) do
    %{
      max_labeled_demos: Keyword.get(opts, :max_labeled_demos, @default_max_labeled_demos),
      max_bootstrapped_demos:
        Keyword.get(opts, :max_bootstrapped_demos, @default_max_bootstrapped_demos),
      max_rounds: Keyword.get(opts, :max_rounds, @default_max_rounds),
      threshold: Keyword.get(opts, :threshold, @default_threshold) |> coerce_threshold(),
      max_errors: Keyword.get(opts, :max_errors, @default_max_errors),
      deterministic: Keyword.get(opts, :deterministic, false),
      diversity_temperature:
        Keyword.get(opts, :diversity_temperature, @default_diversity_temperature)
    }
  end

  defp coerce_threshold(true), do: 1.0
  defp coerce_threshold(false), do: 0.0
  defp coerce_threshold(n) when is_integer(n), do: n * 1.0
  defp coerce_threshold(n) when is_float(n), do: n

  defp validate_trainset(trainset) do
    case Enum.find(trainset, fn ex -> not match?(%Dsxir.Example{}, ex) end) do
      nil ->
        :ok

      offender ->
        {:error, %Errors.Invalid.Trainset{reason: :not_an_example, example: offender}}
    end
  end

  defp phase_one(trainset, cfg) do
    chosen =
      if cfg.deterministic do
        trainset |> Enum.sort_by(&:erlang.phash2/1) |> Enum.take(cfg.max_labeled_demos)
      else
        Enum.take_random(trainset, cfg.max_labeled_demos)
      end

    Enum.map(chosen, &Demo.labeled/1)
  end

  defp phase_two(student, trainset, metric, cfg) do
    indexed_trainset =
      if cfg.deterministic,
        do: trainset |> Enum.sort_by(&:erlang.phash2/1) |> Enum.with_index(),
        else: Enum.with_index(trainset)

    initial = {empty_pool(student), []}

    Enum.reduce(1..cfg.max_rounds, initial, fn round, acc ->
      run_round(round, indexed_trainset, student, metric, cfg, acc)
    end)
  end

  defp run_round(round, indexed_trainset, student, metric, cfg, acc) do
    Enum.reduce(indexed_trainset, acc, fn {example, idx}, {pool, errs} ->
      maybe_run_example(student, example, idx, round, metric, cfg, pool, errs)
    end)
  end

  defp maybe_run_example(student, example, idx, round, metric, cfg, pool, errs) do
    if pool_full?(pool, cfg.max_bootstrapped_demos) do
      {pool, errs}
    else
      run_round_example(student, example, idx, round, metric, cfg, pool, errs)
    end
  end

  defp run_round_example(student, example, idx, round, metric, cfg, pool, errs) do
    diverse_lm = inject_diversity(Settings.resolve(:lm), round, idx, cfg)

    try do
      {_prog, prediction, trace} =
        Dsxir.with_trace(fn ->
          Settings.context(
            [
              lm: diverse_lm,
              metadata:
                Map.merge(Settings.resolve(:metadata, %{}), %{
                  bootstrap_round: round,
                  bootstrap_index: idx
                })
            ],
            fn -> dispatch(student, example) end
          )
        end)

      coerced = Metric.apply(metric, example, prediction, trace)

      if coerced >= cfg.threshold do
        trial_emit(round, idx, coerced, true)
        {add_trace_to_pool(pool, trace, round, idx, cfg.max_bootstrapped_demos), errs}
      else
        trial_emit(round, idx, coerced, false)
        {pool, errs}
      end
    rescue
      e ->
        item_error_emit(round, idx, e)

        stamped =
          stamp_path(e, [:bootstrap_few_shot, :"round_#{round}", :"example_#{idx}"])

        {pool, [stamped | errs]}
    end
  end

  defp inject_diversity(nil, _round, _idx, _cfg), do: nil

  defp inject_diversity({impl, config}, round, idx, cfg)
       when is_atom(impl) and is_list(config) do
    extra = [
      temperature: cfg.diversity_temperature,
      cache: false,
      _dsxir_nonce: {round, idx, :erlang.unique_integer([:monotonic])}
    ]

    {impl, Keyword.merge(config, extra)}
  end

  defp dispatch(%Program{module: user_module} = prog, %Dsxir.Example{} = example) do
    user_module.forward(prog, Dsxir.Example.inputs(example))
  end

  defp empty_pool(%Program{predictors: predictors}),
    do: Map.new(predictors, fn {name, _} -> {name, []} end)

  defp pool_full?(pool, cap) do
    Enum.all?(pool, fn {_name, demos} -> length(demos) >= cap end)
  end

  defp add_trace_to_pool(pool, trace, round, idx, cap) do
    Enum.reduce(trace, pool, fn {name, inputs, prediction, _demos_used}, acc ->
      current = Map.get(acc, name, [])

      if length(current) >= cap do
        acc
      else
        demo =
          Demo.bootstrapped(
            captured_example(inputs, prediction),
            %{round: round, example_index: idx}
          )

        Map.put(acc, name, current ++ [demo])
      end
    end)
  end

  defp captured_example(inputs, %Dsxir.Prediction{fields: fields}) do
    data = Map.merge(inputs, fields)
    Dsxir.Example.new(data, input_keys: Map.keys(inputs))
  end

  defp stamp_path(%{path: existing} = err, prefix) when is_list(existing) do
    %{err | path: prefix ++ existing}
  end

  defp stamp_path(err, _prefix), do: err

  defp slot_all(
         %Program{module: user_module, predictors: predictors} = prog,
         labeled,
         bootstrapped,
         trainset
       ) do
    decls = ModuleInfo.module(user_module)

    updated =
      Map.new(predictors, fn {name, %Program.State{} = state} ->
        decl = Enum.find(decls, &(&1.name == name))
        compatible_labeled = compatible_demos(labeled, decl)
        per_predictor = compatible_labeled ++ Map.get(bootstrapped, name, [])
        {name, %{state | demos: per_predictor}}
      end)

    metadata =
      prog.metadata
      |> Map.put(:compiled_with, __MODULE__)
      |> Map.put(:score, nil)
      |> Map.put(:trainset_hash, trainset_hash(trainset))

    %{prog | predictors: updated, metadata: metadata}
  end

  defp compatible_demos(demos, decl) do
    required = required_field_names(decl)
    Enum.filter(demos, fn demo -> MapSet.subset?(required, demo_key_set(demo)) end)
  end

  defp required_field_names(decl) do
    decl.signature
    |> SignatureRuntime.fields()
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp demo_key_set(%Demo{example: %Dsxir.Example{data: data}}), do: MapSet.new(Map.keys(data))
  defp demo_key_set(%Dsxir.Example{data: data}), do: MapSet.new(Map.keys(data))

  defp trainset_hash(trainset) do
    :crypto.hash(:sha256, :erlang.term_to_binary(trainset)) |> Base.encode16(case: :lower)
  end

  defp classify_errors(errors, max_errors) when length(errors) > max_errors do
    aggregate = Errors.to_class(errors, class: :framework)
    {:halt, aggregate}
  end

  defp classify_errors(_errors, _max_errors), do: :ok

  defp stats_for(labeled, bootstrapped, compiled, cfg, error_count) do
    %{
      labeled_demos: length(labeled),
      bootstrapped_demos: bootstrapped |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
      predictor_count: map_size(compiled.predictors),
      rounds: cfg.max_rounds,
      error_count: error_count,
      max_errors: cfg.max_errors,
      threshold: cfg.threshold
    }
  end

  defp trial_emit(round, idx, score, kept) do
    Telemetry.emit(
      Telemetry.optimizer_trial(),
      %{score: score * 1.0},
      %{
        optimizer: __MODULE__,
        round: round,
        example_index: idx,
        kept: kept,
        error_class: nil
      }
    )
  end

  defp item_error_emit(round, idx, err) do
    Telemetry.emit(
      Telemetry.optimizer_item_error(),
      %{system_time: System.system_time()},
      %{
        optimizer: __MODULE__,
        round: round,
        example_index: idx,
        error: err,
        error_class: Errors.class_of(err)
      }
    )
  end

  @impl Dsxir.Optimizer
  @doc """
  Prepare a resumable BootstrapFewShot session.

  Performs phase one (labeled demo selection) eagerly and seeds the per-round
  example queue used by `step/6`. The returned planned-trial count is
  `max_rounds * length(trainset)` — an upper bound, since errors do not reduce
  the budget but do increment the session's error counter.
  """
  @spec init_session(Program.t(), [Dsxir.Example.t()], nil | Dsxir.Metric.t(), keyword()) ::
          {:ok, Sampler.t(), pos_integer()} | {:error, Exception.t()}
  def init_session(_program, [], _metric, _opts) do
    {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}}
  end

  def init_session(%Program{} = student, trainset, metric, opts)
      when is_list(trainset) and is_list(opts) and (is_function(metric, 3) or is_nil(metric)) do
    case validate_trainset(trainset) do
      :ok ->
        cfg = config(opts)
        labeled = phase_one(trainset, cfg)
        examples = prepare_examples(trainset, cfg)
        planned = cfg.max_rounds * length(trainset)

        sampler = %Sampler{
          round: 1,
          max_rounds: cfg.max_rounds,
          examples_remaining_in_round: examples,
          all_examples_for_round: examples,
          demos_pool: empty_pool(student),
          predictor_decls: ModuleInfo.module(student.module),
          labeled_demos_slotted: labeled,
          rng_seed: :erlang.phash2({:bootstrap_few_shot, opts}),
          config: cfg,
          error_count: 0
        }

        {:ok, sampler, planned}

      {:error, %Errors.Invalid.Trainset{} = err} ->
        {:error, err}
    end
  end

  @impl Dsxir.Optimizer
  @doc """
  Run a single example through one round of BootstrapFewShot.

  When the current round's queue is empty and `round < max_rounds`, advances
  to the next round and recurses on the freshly prepared queue. When the queue
  is empty and `round >= max_rounds`, halts with `:rounds_exhausted`.

  Exceptions from the example pipeline are caught and reported as
  `status: :error` trials rather than crashing the session.
  """
  @spec step(
          Sampler.t(),
          non_neg_integer(),
          Program.t(),
          [Dsxir.Example.t()],
          nil | Dsxir.Metric.t(),
          keyword()
        ) :: {:cont, Sampler.t(), map()} | {:halt, Sampler.t(), :rounds_exhausted}
  def step(
        %Sampler{examples_remaining_in_round: [], round: r, max_rounds: max} = sampler,
        _idx,
        _program,
        _trainset,
        _metric,
        _opts
      )
      when r >= max do
    {:halt, sampler, :rounds_exhausted}
  end

  def step(
        %Sampler{examples_remaining_in_round: [], round: r, max_rounds: max} = sampler,
        idx,
        program,
        trainset,
        metric,
        opts
      )
      when r < max do
    next_examples = prepare_examples(trainset, sampler.config)

    sampler = %{
      sampler
      | round: r + 1,
        examples_remaining_in_round: next_examples,
        all_examples_for_round: next_examples
    }

    step(sampler, idx, program, trainset, metric, opts)
  end

  def step(
        %Sampler{examples_remaining_in_round: [{example, ex_idx} | rest]} = sampler,
        trial_idx,
        program,
        _trainset,
        metric,
        _opts
      ) do
    start = System.monotonic_time(:millisecond)
    cfg = sampler.config
    round = sampler.round

    result =
      try do
        run_example(program, example, ex_idx, round, metric, cfg, sampler.demos_pool)
      rescue
        e ->
          stamped = stamp_path(e, [:bootstrap_few_shot, :"round_#{round}", :"example_#{ex_idx}"])
          item_error_emit(round, ex_idx, stamped)
          {:error, stamped}
      end

    duration = System.monotonic_time(:millisecond) - start

    case result do
      {:ok, score, new_pool, kept} ->
        trial_emit(round, ex_idx, score, kept)
        candidate = slot_session(program, sampler.labeled_demos_slotted, new_pool)

        sampler2 = %{
          sampler
          | demos_pool: new_pool,
            examples_remaining_in_round: rest
        }

        trial = %{
          trial_idx: trial_idx,
          candidate_id: "bfs-r#{round}-i#{ex_idx}",
          score: score * 1.0,
          status: :ok,
          stats: %{
            round: round,
            example_index: ex_idx,
            kept: kept,
            demos_in_pool: total_demos(new_pool)
          },
          duration_ms: duration,
          error: nil,
          error_class: nil,
          candidate_program: candidate
        }

        {:cont, sampler2, trial}

      {:error, err} ->
        sampler2 = %{
          sampler
          | examples_remaining_in_round: rest,
            error_count: sampler.error_count + 1
        }

        trial = %{
          trial_idx: trial_idx,
          candidate_id: nil,
          score: nil,
          status: :error,
          stats: %{round: round, example_index: ex_idx},
          duration_ms: duration,
          error: err,
          error_class: Errors.class_of(err),
          candidate_program: nil
        }

        {:cont, sampler2, trial}
    end
  end

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

  defp prepare_examples(trainset, %{deterministic: true}) do
    trainset
    |> Enum.sort_by(&:erlang.phash2/1)
    |> Enum.with_index()
  end

  defp prepare_examples(trainset, %{deterministic: false}) do
    Enum.with_index(trainset)
  end

  defp run_example(student, example, idx, round, metric, cfg, pool) do
    diverse_lm = inject_diversity(Settings.resolve(:lm), round, idx, cfg)

    {_prog, prediction, trace} =
      Dsxir.with_trace(fn ->
        Settings.context(
          [
            lm: diverse_lm,
            metadata:
              Map.merge(Settings.resolve(:metadata, %{}), %{
                bootstrap_round: round,
                bootstrap_index: idx
              })
          ],
          fn -> dispatch(student, example) end
        )
      end)

    coerced =
      case metric do
        nil -> 0.0
        _ -> Metric.apply(metric, example, prediction, trace)
      end

    if coerced >= cfg.threshold do
      new_pool = add_trace_to_pool(pool, trace, round, idx, cfg.max_bootstrapped_demos)
      {:ok, coerced, new_pool, true}
    else
      {:ok, coerced, pool, false}
    end
  end

  defp slot_session(%Program{predictors: predictors} = prog, labeled, demos_pool) do
    decls = ModuleInfo.module(prog.module)

    updated =
      Map.new(predictors, fn {name, %Program.State{} = state} ->
        decl = Enum.find(decls, &(&1.name == name))
        compatible_labeled = compatible_demos(labeled, decl)
        per_predictor = compatible_labeled ++ Map.get(demos_pool, name, [])
        {name, %{state | demos: per_predictor}}
      end)

    %{prog | predictors: updated}
  end

  defp total_demos(pool) do
    pool |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
  end
end
