defmodule Dsxir.Optimizer.SIMBA.Evaluator do
  @moduledoc """
  Trace-capturing parallel runner for `Dsxir.Optimizer.SIMBA` — DSPy's
  `wrap_program` generalized to a batch of `{program, example}` pairs.

  Each pair runs in its own worker under `Dsxir.TaskSupervisor`, replaying the
  caller's `Dsxir.Settings` snapshot. Inside the worker the forward is wrapped
  in `Dsxir.with_trace/1` (the trace slot is process-local, so each worker
  captures only its own execution), optionally under a scoped diverse `lm` for
  sampling. The metric scores the prediction and `ScoreWithFeedback` is drained
  into `metadata`.

  Results are order-aligned with the input pairs (`ordered: true`). SIMBA treats
  per-pair failures as score `0.0` rather than drops or `nil`: an exception in
  the recognised LM/adapter/invalid class set, or a worker `:exit`
  (timeout/kill), yields a zero-score record so every pair produces one.
  """

  alias Dsxir.Errors
  alias Dsxir.Metric
  alias Dsxir.Settings

  @timeout 60_000

  @type record :: %{
          prediction: Dsxir.Prediction.t() | nil,
          trace: [Dsxir.Trace.Entry.t()],
          score: float(),
          example: Dsxir.Example.t(),
          metadata: term()
        }

  @spec run([{Dsxir.Program.t(), Dsxir.Example.t()}], Dsxir.Metric.t(), keyword()) :: [record()]
  def run(pairs, metric, opts \\ [])
      when is_list(pairs) and is_function(metric, 3) and is_list(opts) do
    snapshot = Settings.snapshot()

    Dsxir.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      pairs,
      fn {program, example} -> run_one(program, example, metric, snapshot, opts) end,
      max_concurrency: opts[:num_threads] || 4,
      timeout: @timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(pairs)
    |> Enum.map(&record_from_stream/1)
  end

  defp run_one(program, example, metric, snapshot, opts) do
    Settings.run(snapshot, fn ->
      try do
        {_prog, prediction, trace} =
          Dsxir.with_trace(fn ->
            Settings.context(lm_frame(opts), fn ->
              Dsxir.Program.forward(program, Dsxir.Example.inputs(example))
            end)
          end)

        score = Metric.apply(metric, example, prediction, trace)
        metadata = extract_feedback(Metric.drain_gepa_feedback())

        %{
          prediction: prediction,
          trace: trace,
          score: score,
          example: example,
          metadata: metadata
        }
      rescue
        _ in [
          Errors.Adapter.ParseError,
          Errors.Adapter.ZoiValidation,
          Errors.Adapter.FallbackExhausted,
          Errors.LM.RequestFailed,
          Errors.LM.RateLimited,
          Errors.LM.ContextWindow,
          Errors.LM.Authentication,
          Errors.Invalid.Configuration,
          Errors.Invalid.Metric,
          Errors.Framework.PredictorError,
          Errors.Halted.Plug,
          RuntimeError
        ] ->
          failure_record(example)
      end
    end)
  end

  defp lm_frame(opts) do
    if opts[:sampling] == true, do: [lm: diverse_lm(opts)], else: []
  end

  defp diverse_lm(opts) do
    case Settings.resolve(:lm) do
      {impl, config} when is_atom(impl) and is_list(config) ->
        extra = [
          temperature: opts[:temperature] || 1.0,
          cache: false,
          _dsxir_nonce: :erlang.unique_integer([:monotonic])
        ]

        {impl, Keyword.merge(config, extra)}

      other ->
        other
    end
  end

  defp extract_feedback(nil), do: nil
  defp extract_feedback(%Metric.ScoreWithFeedback{feedback: fb}), do: fb

  defp failure_record(example) do
    %{prediction: nil, trace: [], score: 0.0, example: example, metadata: nil}
  end

  defp record_from_stream({{:ok, record}, _pair}), do: record

  defp record_from_stream({{:exit, _reason}, {_program, example}}) do
    failure_record(example)
  end
end
