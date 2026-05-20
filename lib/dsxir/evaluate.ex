defmodule Dsxir.Evaluate do
  @moduledoc """
  Devset evaluation runner.

  Fan-out via `Task.Supervisor.async_stream_nolink/4` under
  `Dsxir.TaskSupervisor`. Settings are snapshot once on the caller and replayed
  per worker via `Dsxir.Settings.run/2` so settings-scoped state (lm, adapter,
  metadata, cache) is preserved across workers.

  Per-example errors are caught at the worker boundary, classified via
  `Dsxir.Errors.class_of/1`, and counted in
  `EvaluationResult.errors.by_class`. The runner does not abort on individual
  row failures; `run!/2` raises after the run completes when any row errored.

  Telemetry:

    * `[:dsxir, :evaluate, :item]` — per row.
      Measurements: `%{duration, metric_value}` (`metric_value: nil` on error).
      Metadata: `%{example, prediction, error_class}` (`prediction: nil` on
      error, `error_class: nil` on success).
    * `[:dsxir, :evaluate, :stop]` — once.
      Measurements: `%{duration, score, total, error_count, save_as}`
      (`save_as: nil` when not set).
      Metadata: `%{evaluator, devset_size, max_errors}`.

  When `:save_as` is set, the result rows are written to disk as JSON-Lines
  (one row per line) before `run/2` returns.
  """

  alias Dsxir.Errors
  alias Dsxir.EvaluationResult
  alias Dsxir.Settings
  alias Dsxir.Telemetry

  @default_num_threads 1
  @default_max_errors 10
  @default_failure_score 0.0
  @default_timeout 60_000

  defstruct devset: [],
            metric: nil,
            num_threads: @default_num_threads,
            max_errors: @default_max_errors,
            failure_score: @default_failure_score,
            save_as: nil,
            timeout: @default_timeout

  @type t :: %__MODULE__{
          devset: [Dsxir.Example.t()],
          metric: Dsxir.Metric.t(),
          num_threads: pos_integer(),
          max_errors: non_neg_integer(),
          failure_score: float(),
          save_as: nil | Path.t(),
          timeout: pos_integer()
        }

  @doc """
  Evaluate `program` over the configured devset. Per-row failures are caught
  and reported in the returned `EvaluationResult`; the run never aborts on a
  single error. When `:save_as` is set, the rows are persisted as JSON Lines
  before returning.
  """
  @spec run(t(), Dsxir.Program.t()) :: EvaluationResult.t()
  def run(%__MODULE__{} = ev, %Dsxir.Program{} = program) do
    snapshot = Settings.snapshot()
    start_time = System.monotonic_time()

    rows =
      Dsxir.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        ev.devset,
        fn example -> run_one(ev, program, example, snapshot) end,
        max_concurrency: ev.num_threads,
        timeout: ev.timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(ev.devset)
      |> Enum.map(&row_from_stream/1)

    result = build_result(ev, rows)
    maybe_save(ev, result)
    duration = System.monotonic_time() - start_time

    Telemetry.emit(
      Telemetry.evaluate_stop(),
      %{
        duration: duration,
        score: result.score,
        total: length(result.results),
        error_count: result.errors.count,
        save_as: ev.save_as
      },
      %{
        evaluator: __MODULE__,
        devset_size: length(ev.devset),
        max_errors: ev.max_errors
      }
    )

    result
  end

  @doc """
  Bang variant of `run/2`. Returns the result when zero rows errored and
  otherwise raises `Dsxir.Errors.Framework.PredictorError` with the per-class
  error counts.
  """
  @spec run!(t(), Dsxir.Program.t()) :: EvaluationResult.t()
  def run!(%__MODULE__{} = ev, %Dsxir.Program{} = program) do
    case run(ev, program) do
      %EvaluationResult{errors: %{count: 0}} = ok ->
        ok

      %EvaluationResult{errors: %{count: n, by_class: by_class}} ->
        raise %Errors.Framework.PredictorError{
          predictor: __MODULE__,
          signature: nil,
          inner: nil,
          reason: {:per_example_errors, n, by_class}
        }
    end
  end

  defp run_one(ev, program, example, snapshot) do
    Settings.run(snapshot, fn ->
      example_start = System.monotonic_time()
      row = invoke(program, example, ev)
      duration = System.monotonic_time() - example_start

      {meas, meta} = telemetry_for(row, duration)
      Telemetry.emit(Telemetry.evaluate_item(), meas, meta)

      row
    end)
  end

  defp invoke(program, example, ev) do
    inputs = Dsxir.Example.inputs(example)

    try do
      {_prog, prediction} = Dsxir.Program.forward(program, inputs)
      metric = Dsxir.Metric.apply(ev.metric, example, prediction, nil)
      EvaluationResult.ok_row(example, prediction, metric)
    rescue
      e in [
        Dsxir.Errors.Adapter.ParseError,
        Dsxir.Errors.Adapter.ZoiValidation,
        Dsxir.Errors.Adapter.FallbackExhausted,
        Dsxir.Errors.LM.RequestFailed,
        Dsxir.Errors.LM.Authentication,
        Dsxir.Errors.LM.RateLimited,
        Dsxir.Errors.LM.ContextWindow,
        Dsxir.Errors.Invalid.Configuration,
        Dsxir.Errors.Invalid.Metric,
        Dsxir.Errors.Framework.PredictorError,
        Dsxir.Errors.Halted.Plug,
        RuntimeError
      ] ->
        EvaluationResult.error_row(example, e)
    end
  end

  defp row_from_stream({{:ok, row}, _example}), do: row

  defp row_from_stream({{:exit, reason}, example}) do
    EvaluationResult.error_row(example, exit_to_exception(reason))
  end

  defp exit_to_exception({%{__exception__: true} = exception, _stacktrace}), do: exception
  defp exit_to_exception(%{__exception__: true} = exception), do: exception

  defp exit_to_exception(:timeout) do
    %Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: nil,
      reason: :timeout
    }
  end

  defp exit_to_exception(other) do
    %Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: nil,
      reason: other
    }
  end

  defp telemetry_for(%{error: nil, metric: m, prediction: p, example: e}, duration) do
    {%{duration: duration, metric_value: m}, %{example: e, prediction: p, error_class: nil}}
  end

  defp telemetry_for(%{error: err, example: e}, duration) do
    {%{duration: duration, metric_value: nil},
     %{example: e, prediction: nil, error_class: Errors.class_of(err)}}
  end

  defp build_result(ev, rows) do
    metric_values =
      Enum.map(rows, fn
        %{metric: nil} -> ev.failure_score
        %{metric: m} -> m
      end)

    by_class =
      rows
      |> Enum.reject(&is_nil(&1.error))
      |> Enum.map(fn %{error: e} -> Errors.class_of(e) end)
      |> Enum.frequencies()

    error_count = rows |> Enum.count(&(not is_nil(&1.error)))

    %EvaluationResult{
      score: EvaluationResult.score_from(metric_values),
      results: rows,
      errors: %{count: error_count, by_class: by_class}
    }
  end

  defp maybe_save(%__MODULE__{save_as: nil}, _result), do: :ok

  defp maybe_save(%__MODULE__{save_as: path}, %EvaluationResult{} = result)
       when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    encoded =
      result.results
      |> Enum.map(&encode_row/1)
      |> Enum.map_join("\n", &Jason.encode!/1)

    File.write!(path, encoded <> "\n")
    :ok
  end

  defp encode_row(%{example: ex, prediction: pred, metric: m, error: err}) do
    %{
      example: ex.data,
      prediction: prediction_payload(pred),
      metric: m,
      error: err && Exception.message(err),
      error_class: err && Errors.class_of(err)
    }
  end

  defp prediction_payload(nil), do: nil
  defp prediction_payload(%Dsxir.Prediction{fields: f}), do: f

  defimpl Inspect do
    import Inspect.Algebra

    def inspect(%Dsxir.Evaluate{} = ev, _opts) do
      concat([
        "#Dsxir.Evaluate<devset: ",
        Integer.to_string(length(ev.devset)),
        ", num_threads: ",
        Integer.to_string(ev.num_threads),
        ", max_errors: ",
        Integer.to_string(ev.max_errors),
        ">"
      ])
    end
  end
end
