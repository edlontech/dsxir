defmodule Dsxir.Predictor.Sampling do
  @moduledoc """
  Shared sample-score-select core for `Dsxir.Predictor.BestOfN` and
  `Dsxir.Predictor.Refine`. Runs a program's `forward/2` up to `n` times
  sequentially, each attempt under an `:lm` config carrying diversity
  (`temperature`, `cache: false`, a fresh `_dsxir_nonce`) the same way
  `Dsxir.Optimizer.BootstrapFewShot` does. Scores each attempt with
  `reward_fn`, keeps the strictly-best, stops early on `threshold`, and
  tolerates up to `fail_count` raising attempts before re-raising the last
  error wrapped as `Dsxir.Errors.Framework.PredictorError`.

  The optional `:on_attempt` hook is called at the start of each attempt with
  the prior attempt's info (`nil` on the first) and returns a hints map (or
  `nil`) pushed onto `Dsxir.Settings` for the upcoming attempt.
  """

  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Telemetry

  @type reward_fn :: (map(), Prediction.t() -> number())

  @default_temperature 1.0

  @doc "Run `program` up to `:n` times with diverse sampling, score each with `reward_fn`, and return the best-scoring attempt."
  @spec run(Program.t(), map(), reward_fn(), keyword()) :: {Program.t(), Prediction.t()}
  def run(%Program{} = program, inputs, reward_fn, opts)
      when is_map(inputs) and is_function(reward_fn, 2) do
    n = fetch_pos!(opts, :n)
    event = Keyword.fetch!(opts, :event_name)
    threshold = Keyword.get(opts, :threshold)
    fail_count = fetch_non_neg!(opts, :fail_count, n)
    temperature = Keyword.get(opts, :temperature, @default_temperature)
    on_attempt = Keyword.get(opts, :on_attempt, nil)

    acc = %{best: nil, prior: nil, failures_left: fail_count, last_error: nil}

    final =
      Enum.reduce_while(0..(n - 1), acc, fn attempt_idx, acc ->
        hints = resolve_hints(on_attempt, acc.prior)
        result = attempt(program, inputs, reward_fn, attempt_idx, temperature, hints)

        step(result, acc, %{
          event: event,
          attempt_idx: attempt_idx,
          threshold: threshold,
          hints: hints
        })
      end)

    case final.best do
      nil ->
        raise wrap(final.last_error, event)

      %{program: prog, pred: pred, reward: reward} ->
        emit_stop(event, reward)
        {prog, pred}
    end
  end

  defp step({:ok, info}, acc, %{
         event: event,
         attempt_idx: idx,
         threshold: threshold,
         hints: hints
       }) do
    kept? = better?(acc.best, info)
    best = if kept?, do: info, else: acc.best
    emit_attempt(event, idx, info.reward, kept?, hints, false)
    acc = %{acc | best: best, prior: info}

    if is_number(threshold) and info.reward >= threshold do
      {:halt, acc}
    else
      {:cont, acc}
    end
  end

  defp step({:error, e}, acc, %{event: event, attempt_idx: idx, hints: hints}) do
    emit_attempt(event, idx, nil, false, hints, true)
    left = acc.failures_left - 1

    if left < 0 do
      raise wrap(e, event)
    else
      {:cont, %{acc | failures_left: left, last_error: e}}
    end
  end

  defp resolve_hints(nil, _prior), do: nil
  defp resolve_hints(hook, prior) when is_function(hook, 1), do: hook.(prior)

  defp attempt(program, inputs, reward_fn, attempt_idx, temperature, hints) do
    case run_forward(program, inputs, attempt_idx, temperature, hints) do
      {:ok, prog, pred, trace} ->
        reward = check_number!(reward_fn.(inputs, pred))
        {:ok, %{program: prog, pred: pred, reward: reward, trace: trace}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp run_forward(program, inputs, attempt_idx, temperature, hints) do
    ctx = lm_frame(Settings.resolve(:lm), attempt_idx, temperature) ++ hints_frame(hints)

    try do
      {prog, pred, trace} =
        Dsxir.with_trace(fn ->
          Settings.context(ctx, fn -> Program.forward(program, inputs, []) end)
        end)

      {:ok, prog, pred, trace}
    rescue
      e -> {:error, e}
    end
  end

  defp lm_frame(nil, _attempt_idx, _temperature), do: []

  defp lm_frame({impl, config}, attempt_idx, temperature)
       when is_atom(impl) and is_list(config) do
    diverse =
      Keyword.merge(config,
        temperature: temperature,
        cache: false,
        _dsxir_nonce: {:sampling, attempt_idx, :erlang.unique_integer([:monotonic])}
      )

    [lm: {impl, diverse}]
  end

  defp hints_frame(nil), do: []
  defp hints_frame(map) when map_size(map) == 0, do: []
  defp hints_frame(map) when is_map(map), do: [hints: map]

  defp better?(nil, _info), do: true
  defp better?(%{reward: best}, %{reward: r}), do: r > best

  defp check_number!(value) when is_number(value), do: value

  defp check_number!(value) do
    raise %Dsxir.Errors.Invalid.Metric{example: nil, returned: value, expected: :number}
  end

  defp wrap(inner, event) do
    %Dsxir.Errors.Framework.PredictorError{
      predictor: module_for(event),
      signature: nil,
      inner: inner,
      reason: :fail_count_exhausted
    }
  end

  defp module_for(:best_of_n), do: Dsxir.Predictor.BestOfN
  defp module_for(:refine), do: Dsxir.Predictor.Refine

  defp emit_attempt(event, attempt, reward, kept?, hints, failed?) do
    Telemetry.emit(
      Telemetry.sampling_attempt(event),
      %{reward: reward},
      Map.merge(Settings.resolve(:metadata, %{}), %{
        attempt: attempt,
        kept?: kept?,
        failed?: failed?,
        fed_back?: is_map(hints) and map_size(hints) > 0
      })
    )
  end

  defp emit_stop(event, best_reward) do
    Telemetry.emit(
      Telemetry.sampling_stop(event),
      %{best_reward: best_reward},
      Settings.resolve(:metadata, %{})
    )
  end

  defp fetch_pos!(opts, key) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n >= 1 ->
        n

      other ->
        raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp fetch_non_neg!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n >= 0 ->
        n

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-negative integer, got: #{inspect(other)}"
    end
  end
end
