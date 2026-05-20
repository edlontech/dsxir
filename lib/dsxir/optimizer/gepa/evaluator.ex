defmodule Dsxir.Optimizer.GEPA.Evaluator do
  @moduledoc """
  Parallel devset evaluation for `Dsxir.Optimizer.GEPA`. Returns
  `{scores, feedback}` — two ordered lists aligned with the devset.

  Each per-example `Dsxir.Metric.apply/4` call is wrapped in a worker under
  `Dsxir.TaskSupervisor`, replaying the caller's `Dsxir.Settings` snapshot.
  After the metric runs, the worker drains the GEPA feedback slot via
  `Dsxir.Metric.drain_gepa_feedback/0`. Per-example exceptions in the
  recognised LM/adapter/invalid class set are caught and produce `nil` in
  both arrays.

  Whole-evaluation failures (e.g. process crashes outside the rescue list)
  raise; the caller catches them.
  """

  alias Dsxir.Errors
  alias Dsxir.Metric
  alias Dsxir.Settings

  @timeout 60_000

  @type predictor_feedback :: %{atom() => String.t() | nil}

  @spec run(
          Dsxir.Program.t(),
          [Dsxir.Example.t()],
          Dsxir.Metric.t(),
          num_threads :: pos_integer()
        ) ::
          {[float() | nil], [predictor_feedback() | String.t() | nil]}
  def run(%Dsxir.Program{} = program, devset, metric, num_threads \\ 4)
      when is_list(devset) and is_function(metric, 3) and is_integer(num_threads) do
    snapshot = Settings.snapshot()

    rows =
      Dsxir.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        devset,
        fn example -> run_one(program, example, metric, snapshot) end,
        max_concurrency: num_threads,
        timeout: @timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.zip(devset)
      |> Enum.map(&row_from_stream/1)

    {Enum.map(rows, & &1.score), Enum.map(rows, & &1.feedback)}
  end

  @doc """
  Evaluator wrapper that returns positionally-aligned `nil` arrays when the
  metric is `nil` or the devset is empty; otherwise delegates to `run/4`.
  """
  @spec run_or_nils(Dsxir.Program.t(), [Dsxir.Example.t()], Dsxir.Metric.t() | nil) ::
          {[float() | nil], [predictor_feedback() | String.t() | nil]}
  def run_or_nils(_program, [], _metric), do: {[], []}

  def run_or_nils(_program, devset, nil) do
    nils = Enum.map(devset, fn _ -> nil end)
    {nils, nils}
  end

  def run_or_nils(program, devset, metric) when is_function(metric, 3),
    do: run(program, devset, metric)

  defp run_one(program, example, metric, snapshot) do
    Settings.run(snapshot, fn ->
      try do
        inputs = Dsxir.Example.inputs(example)
        {_prog, prediction} = Dsxir.Program.forward(program, inputs)
        score = Metric.apply(metric, example, prediction, nil)
        feedback = extract_feedback(Metric.drain_gepa_feedback())
        %{score: score, feedback: feedback, error: nil}
      rescue
        e in [
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
          %{score: nil, feedback: nil, error: e}
      end
    end)
  end

  defp extract_feedback(nil), do: nil
  defp extract_feedback(%Metric.ScoreWithFeedback{feedback: fb}), do: fb

  defp row_from_stream({{:ok, row}, _example}), do: row

  defp row_from_stream({{:exit, _reason}, _example}) do
    %{score: nil, feedback: nil, error: :worker_exit}
  end
end
