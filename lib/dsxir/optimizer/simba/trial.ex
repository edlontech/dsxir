defmodule Dsxir.Optimizer.SIMBA.Trial do
  @moduledoc """
  One SIMBA mini-batch step over a `Dsxir.Optimizer.SIMBA.Sampler`.

  `run/1` draws the next mini-batch (reshuffle-and-wrap on exhaustion), samples
  diverse trajectories from the current pool, buckets them per example, builds
  new candidate programs by dropping demos and applying a strategy, evaluates
  the candidates on the same mini-batch, records the per-step winner, and
  registers every candidate back into the pool.

  All randomness threads `sampler.rng_state` explicitly: the batch reshuffle,
  softmax program selection, the Poisson demo-drop count, the dropped indices,
  and the strategy choice all take and return the `:rand` state. Nothing touches
  global `:rand`, so a resumed checkpoint replays deterministically.
  """

  alias Dsxir.Optimizer.SIMBA.Bucket
  alias Dsxir.Optimizer.SIMBA.Evaluator
  alias Dsxir.Optimizer.SIMBA.Sampler
  alias Dsxir.Optimizer.SIMBA.Strategy.AppendDemo
  alias Dsxir.Optimizer.SIMBA.Strategy.AppendRule
  alias Dsxir.Program

  @type args :: %{
          required(:sampler) => Sampler.t(),
          required(:trial_idx) => non_neg_integer(),
          required(:metric) => Dsxir.Metric.t(),
          optional(:opts) => keyword()
        }

  @doc """
  Runs one mini-batch step and returns `{:ok, updated_sampler, trial_result}`.

  The updated sampler carries the threaded `rng_state`, the advanced
  `instance_idx` (and reshuffled `data_indices` on wrap), the grown program
  pool / score lists / winning programs, the updated `best_so_far`, an
  incremented `attempts`, and the per-step entry under `trial_logs[trial_idx]`.
  """
  @spec run(args()) :: {:ok, Sampler.t(), map()}
  def run(%{sampler: %Sampler{} = s, trial_idx: idx, metric: metric} = args) do
    opts = Map.get(args, :opts, [])
    config = s.config
    bsize = config.bsize
    num_candidates = config.num_candidates
    num_threads = opts[:num_threads] || config.num_threads

    {batch, data_indices, instance_idx, rng} = next_batch(s, bsize)

    top = Sampler.top_k_plus_baseline(s, num_candidates)

    {traj_pairs, rng} = trajectory_pairs(s, batch, top, num_candidates, config, rng)

    outputs =
      Evaluator.run(traj_pairs, metric,
        sampling: true,
        temperature: config.sampling_temperature,
        num_threads: num_threads
      )

    scores = Enum.map(outputs, & &1.score)
    {p10, p90} = Bucket.percentiles(scores)
    baseline = mean(scores)
    sorted_buckets = bucketize(outputs, bsize, num_candidates)

    strategies = strategies_for(config.max_demos)

    {candidates, rng} =
      build_candidates(
        sorted_buckets,
        s,
        top,
        strategies,
        config,
        {p10, p90},
        num_candidates + 1,
        rng
      )

    candidate_pairs = for cand <- candidates, ex <- batch, do: {cand, ex}
    outputs2 = Evaluator.run(candidate_pairs, metric, sampling: false, num_threads: num_threads)

    candidate_scores = candidate_means(candidates, outputs2, bsize)

    {registered, candidate_idxs} = register_candidates(s, candidates, outputs2, bsize)

    {best_score, best_program, best_idx} =
      best_candidate(candidates, candidate_scores, candidate_idxs)

    winning_programs =
      case best_program do
        nil -> s.winning_programs
        program -> s.winning_programs ++ [program]
      end

    trial_log = %{
      baseline: baseline,
      candidate_scores: candidate_scores,
      num_candidates: length(candidates),
      p10: p10,
      p90: p90
    }

    s2 = %{
      registered
      | rng_state: rng,
        data_indices: data_indices,
        instance_idx: instance_idx,
        winning_programs: winning_programs,
        best_so_far: update_best(s.best_so_far, best_idx, best_score),
        attempts: s.attempts + 1,
        trial_logs: Map.put(s.trial_logs, idx, trial_log)
    }

    trial = %{
      trial_idx: idx,
      candidate_id: "step_#{idx}",
      score: best_score,
      status: :ok,
      duration_ms: 0,
      stats: %{
        baseline: baseline,
        candidate_scores: candidate_scores,
        num_candidates: length(candidates),
        p10: p10,
        p90: p90
      },
      error: nil,
      error_class: nil,
      candidate_program: best_program
    }

    {:ok, s2, trial}
  end

  @doc """
  Drops a Poisson-sampled number of demo positions from every predictor of
  `program`, threading `rng`.

  `num_demos` is the maximum demo count across predictors. With
  `max_demos_tmp = max(max_demos, 3 when max_demos == 0)`, the drop count is
  `min(max(poisson(num_demos / max_demos_tmp), floor), num_demos)` where `floor`
  is `1` when `num_demos >= max_demos_tmp` and `0` otherwise. The dropped
  positions are sampled with replacement and removed from each predictor's
  `State.demos`.
  """
  @spec drop_demos(Program.t(), map(), term()) :: {Program.t(), term()}
  def drop_demos(program, config, rng) do
    num_demos = max_demos_in_program(program)
    max_demos_tmp = if config.max_demos > 0, do: config.max_demos, else: 3
    {drawn, rng} = Sampler.poisson(num_demos / max_demos_tmp, rng)
    floor = if num_demos >= max_demos_tmp, do: 1, else: 0
    to_drop = min(max(drawn, floor), num_demos)
    {drop_idxs, rng} = pick_drop_indices(num_demos, to_drop, rng)
    drop_set = MapSet.new(drop_idxs)
    {drop_positions(program, drop_set), rng}
  end

  defp next_batch(%Sampler{} = s, bsize) do
    {data_indices, instance_idx, rng} =
      if s.instance_idx + bsize > length(s.data_indices) do
        {shuffled, rng} = shuffle(s.data_indices, s.rng_state)
        {shuffled, 0, rng}
      else
        {s.data_indices, s.instance_idx, s.rng_state}
      end

    batch_indices = Enum.slice(data_indices, instance_idx, bsize)
    batch = Enum.map(batch_indices, &Enum.at(s.trainset, &1))
    {batch, data_indices, instance_idx + bsize, rng}
  end

  defp shuffle(elements, rng) do
    {tagged, rng} =
      Enum.map_reduce(elements, rng, fn element, r ->
        {u, r2} = :rand.uniform_s(r)
        {{u, element}, r2}
      end)

    {tagged |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)), rng}
  end

  defp trajectory_pairs(s, batch, top, num_candidates, config, rng) do
    Enum.flat_map_reduce(0..(num_candidates - 1), rng, fn _c, r ->
      Enum.map_reduce(batch, r, fn example, racc ->
        {src_idx, racc2} =
          Sampler.softmax_sample(s, top, config.temperature_for_sampling, racc)

        {{program_at(s, src_idx), example}, racc2}
      end)
    end)
  end

  defp bucketize(outputs, bsize, num_candidates) do
    0..(bsize - 1)
    |> Enum.map(fn e ->
      0..(num_candidates - 1)
      |> Enum.map(fn c -> Enum.at(outputs, e + c * bsize) end)
      |> Bucket.from_records()
    end)
    |> Bucket.sort()
  end

  defp strategies_for(max_demos) when max_demos > 0, do: [AppendDemo, AppendRule]
  defp strategies_for(_max_demos), do: [AppendRule]

  defp build_candidates(buckets, s, top, strategies, config, {p10, p90}, cap, rng) do
    Enum.reduce_while(buckets, {[], rng}, fn bucket, {acc, r} ->
      {src_idx, r} = Sampler.softmax_sample(s, top, config.temperature_for_candidates, r)
      {cand, r} = drop_demos(program_at(s, src_idx), config, r)
      {strat, r} = pick_strategy(strategies, r)

      ctx = %{
        batch_p10: p10,
        batch_p90: p90,
        reflective_lm: config.reflective_lm,
        source: nil,
        rng: r,
        demo_input_field_maxlen: config.demo_input_field_maxlen
      }

      acc =
        case strat.apply(bucket, cand, ctx) do
          {:ok, mutated} -> acc ++ [mutated]
          :skip -> acc
        end

      if length(acc) >= cap, do: {:halt, {acc, r}}, else: {:cont, {acc, r}}
    end)
  end

  defp pick_strategy(strategies, rng) do
    {u, rng} = :rand.uniform_s(rng)
    idx = min(trunc(u * length(strategies)), length(strategies) - 1)
    {Enum.at(strategies, idx), rng}
  end

  defp pick_drop_indices(_num_demos, 0, rng), do: {[], rng}

  defp pick_drop_indices(num_demos, to_drop, rng) do
    Enum.map_reduce(1..to_drop, rng, fn _, r ->
      {u, r2} = :rand.uniform_s(r)
      {min(trunc(u * num_demos), num_demos - 1), r2}
    end)
  end

  defp drop_positions(program, drop_set) do
    Enum.reduce(program.predictors, program, fn {name, state}, prog ->
      kept =
        state.demos
        |> Enum.with_index()
        |> Enum.reject(fn {_demo, i} -> MapSet.member?(drop_set, i) end)
        |> Enum.map(&elem(&1, 0))

      Program.put_state(prog, name, %{state | demos: kept})
    end)
  end

  defp max_demos_in_program(program) do
    counts = program.predictors |> Map.values() |> Enum.map(&length(&1.demos))
    if counts == [], do: 0, else: Enum.max(counts)
  end

  defp candidate_means(candidates, outputs2, bsize) do
    candidates
    |> Enum.with_index()
    |> Enum.map(fn {_cand, k} ->
      outputs2 |> Enum.slice(k * bsize, bsize) |> Enum.map(& &1.score) |> mean()
    end)
  end

  defp register_candidates(s, candidates, outputs2, bsize) do
    candidates
    |> Enum.with_index()
    |> Enum.reduce({s, []}, fn {cand, k}, {acc_s, idxs} ->
      score_list = outputs2 |> Enum.slice(k * bsize, bsize) |> Enum.map(& &1.score)
      acc_s = Sampler.register_new_program(acc_s, cand, score_list)
      {acc_s, idxs ++ [acc_s.next_idx]}
    end)
  end

  defp best_candidate([], _scores, _idxs), do: {nil, nil, nil}

  defp best_candidate(candidates, scores, idxs) do
    max = Enum.max(scores)
    k = Enum.find_index(scores, &(&1 == max))
    {Enum.at(scores, k), Enum.at(candidates, k), Enum.at(idxs, k)}
  end

  defp update_best(current, nil, _score), do: current
  defp update_best(nil, idx, score), do: {idx, score}

  defp update_best({best_idx, best_score}, idx, score) do
    if score > best_score, do: {idx, score}, else: {best_idx, best_score}
  end

  defp program_at(%Sampler{programs: programs}, idx) do
    Enum.find_value(programs, fn %{idx: i, program: p} -> if i == idx, do: p end)
  end

  defp mean([]), do: 0.0
  defp mean(xs), do: Enum.sum(xs) / length(xs)
end
