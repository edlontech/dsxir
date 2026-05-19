defmodule Dsxir.Optimizer.MIPROv2.Trial do
  @moduledoc """
  Runs one MIPROv2 trial: apply a sampled config to a program's per-predictor
  state, run the program over a minibatch in parallel, score each prediction
  with the metric, and return a `Dsxir.Optimizer.MIPROv2.Stats.Record`.

  Parallelism uses `Task.Supervisor.async_stream_nolink/4` under
  `Dsxir.TaskSupervisor`. Each worker replays the caller's settings snapshot
  via `Dsxir.Settings.run/2` so the LM, adapter, metadata, and call_plugs are
  preserved per-tenant.

  Cache hits are tracked via `Dsxir.Optimizer.Cache.fetch_or_put/3`'s
  `{:hit | :miss, value}` return. A miss increments `lm_calls`; a hit
  increments `cached_calls`. When the cache is disabled (`tid == nil`) every
  call is reported as a miss so `lm_calls` reflects the true number of
  program executions and `cached_calls` stays at zero.

  Examples whose `program.module.forward/2` raises score `0.0` and the batch
  continues. Worker exits (timeout, crash) likewise score `0.0` without
  aborting the trial.
  """

  alias Dsxir.Optimizer.Cache
  alias Dsxir.Optimizer.MIPROv2.Candidates
  alias Dsxir.Optimizer.MIPROv2.Stats.Record
  alias Dsxir.Program
  alias Dsxir.Settings

  @timeout 60_000

  @type args :: %{
          required(:program) => Program.t(),
          required(:config) => map(),
          required(:candidates) => Candidates.t(),
          required(:examples) => [Dsxir.Example.t()],
          required(:metric) => Dsxir.Metric.t(),
          required(:cache_tid) => Cache.tid(),
          required(:settings_snapshot) => %{globals: map(), stack: [map()]},
          required(:trial_index) => non_neg_integer(),
          required(:batch_size) => pos_integer()
        }

  @doc """
  Apply `config` to `program`, evaluate `examples` in parallel, return a
  `Record` summarising mean score, LM calls, cache hits, and duration.
  """
  @spec run(args()) :: Record.t()
  def run(%{
        program: program,
        config: config,
        candidates: candidates,
        examples: examples,
        metric: metric,
        cache_tid: tid,
        settings_snapshot: snapshot,
        trial_index: idx,
        batch_size: batch_size
      })
      when is_list(examples) and is_function(metric, 3) and is_integer(idx) and idx >= 0 and
             is_integer(batch_size) and batch_size > 0 do
    start = System.monotonic_time(:millisecond)
    applied = apply_config(program, config, candidates)

    {scores, lm_calls, cached_calls} =
      Dsxir.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        examples,
        fn example ->
          Settings.run(snapshot, fn -> score_one(applied, example, metric, tid) end)
        end,
        max_concurrency: batch_size,
        timeout: @timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.reduce({[], 0, 0}, &accumulate/2)

    mean =
      case scores do
        [] -> 0.0
        _ -> Enum.sum(scores) / length(scores)
      end

    %Record{
      trial_index: idx,
      config: config,
      score: mean,
      lm_calls: lm_calls,
      cached_calls: cached_calls,
      duration_ms: System.monotonic_time(:millisecond) - start
    }
  end

  defp accumulate({:ok, {score, lm, cc}}, {scores, lm_acc, cc_acc}),
    do: {[score | scores], lm_acc + lm, cc_acc + cc}

  defp accumulate({:exit, _reason}, {scores, lm_acc, cc_acc}),
    do: {[0.0 | scores], lm_acc, cc_acc}

  defp apply_config(%Program{predictors: predictors} = program, config, candidates) do
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

    %{program | predictors: new_predictors}
  end

  defp score_one(program, example, metric, tid) do
    cache_key = build_cache_key(program, example)

    {origin, result} =
      Cache.fetch_or_put(tid, cache_key, fn -> forward_program(program, example) end)

    score =
      case result do
        {:ok, prediction} -> apply_metric(metric, example, prediction)
        {:error, _} -> 0.0
      end

    case origin do
      :hit -> {score, 0, 1}
      :miss -> {score, 1, 0}
    end
  end

  defp apply_metric(metric, example, prediction) do
    metric.(example, prediction, nil) |> coerce_score()
  rescue
    _ -> 0.0
  end

  defp build_cache_key(program, example) do
    {lm_mod, lm_cfg} = settings_lm()

    {lm_mod, Cache.lm_config_hash(lm_cfg), program_state_digest(program),
     Cache.input_hash(example.data)}
  end

  defp settings_lm do
    case Settings.resolve(:lm) do
      {mod, cfg} when is_atom(mod) and is_list(cfg) -> {mod, cfg}
      nil -> {nil, []}
    end
  end

  defp program_state_digest(%Program{predictors: predictors}) do
    predictors
    |> Enum.sort_by(fn {name, _} -> name end)
    |> Enum.map(fn {_, state} -> Cache.predictor_state_hash(state) end)
    |> :erlang.phash2()
  end

  defp forward_program(program, example) do
    {_prog, prediction} = program.module.forward(program, example.data)
    {:ok, prediction}
  rescue
    e -> {:error, e}
  end

  defp coerce_score(true), do: 1.0
  defp coerce_score(false), do: 0.0
  defp coerce_score(v) when is_integer(v), do: v * 1.0
  defp coerce_score(v) when is_float(v), do: v
  defp coerce_score(_), do: 0.0
end
