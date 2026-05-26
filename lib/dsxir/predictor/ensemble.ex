defmodule Dsxir.Predictor.Ensemble do
  @moduledoc """
  Runs N programs concurrently over the same inputs and reduces their
  predictions. Invoked directly from a `forward/2` body, like
  `Dsxir.Predictor.Parallel`; it is not a declared predictor.

  Members fan out under `Dsxir.TaskSupervisor` via
  `Task.Supervisor.async_stream_nolink/4`, replaying the caller's
  `Dsxir.Settings.snapshot/0` in each worker. Member failures are tolerated and
  surfaced via telemetry; the reduction runs over the survivors. When every
  member fails, `run/3` raises `Dsxir.Errors.Framework.PredictorError` with
  `reason: :all_failed`.

  ## Recognised opts

    * `:reduce_fn` — `([Dsxir.Prediction.t()] -> Dsxir.Prediction.t())`. When
      `nil` (default), `run/3` returns the raw prediction list; otherwise it
      returns the reduced prediction.
    * `:size` — sample this many programs per call. Defaults to all.
    * `:max_concurrency` — defaults to `System.schedulers_online()`.
    * `:timeout` — per-member timeout in ms. Defaults to `30_000`.

  ## Return shape

  Unlike the rest of the predictor namespace, `run/3` returns a bare
  `%Dsxir.Prediction{}` (with a reducer) or a `[%Dsxir.Prediction{}]` (without
  one) rather than a `{program, prediction}` tuple — there is no single program
  identity across N members.

  ## Iron Law of OTP

  Workers are short-lived `Task`s with no state across calls; concurrency is
  the purpose (independent members); fault isolation is required, hence
  `async_stream_nolink` so a member crash does not link back to the caller, and
  `on_timeout: :kill_task` reaps slow members. No process is held; the reducer
  is pure.
  """

  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Settings
  alias Dsxir.Telemetry

  @default_timeout 30_000

  @doc "Majority-vote reducer. Votes on the full `fields` map, or a single field via `field:`. Ties break by first occurrence."
  @spec majority([Prediction.t()], keyword()) :: Prediction.t()
  def majority(predictions, opts \\ [])

  def majority([_ | _] = predictions, opts) do
    field = Keyword.get(opts, :field)
    key = fn pred -> vote_key(pred, field) end

    counts =
      Enum.reduce(predictions, %{}, fn pred, acc ->
        Map.update(acc, key.(pred), 1, &(&1 + 1))
      end)

    winning =
      predictions
      |> Enum.map(key)
      |> Enum.uniq()
      |> Enum.max_by(&Map.fetch!(counts, &1))

    Enum.find(predictions, fn pred -> key.(pred) == winning end)
  end

  defp vote_key(%Prediction{fields: fields}, nil), do: fields
  defp vote_key(%Prediction{fields: fields}, field), do: Map.get(fields, field)

  @doc "Run each program in `programs` over `inputs` concurrently and reduce the survivors."
  @spec run([Program.t()], map(), keyword()) :: Prediction.t() | [Prediction.t()]
  def run(programs, inputs, opts \\ [])

  def run([_ | _] = programs, inputs, opts) when is_map(inputs) do
    selected = sample(programs, Keyword.get(opts, :size))
    reduce_fn = Keyword.get(opts, :reduce_fn)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    snapshot = Settings.snapshot()
    metadata = Settings.resolve(:metadata, %{})

    results =
      Dsxir.TaskSupervisor
      |> Task.Supervisor.async_stream_nolink(
        selected,
        fn program -> Settings.run(snapshot, fn -> Program.forward(program, inputs, []) end) end,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.map(&normalize_result/1)

    Enum.each(results, &emit_member(metadata, &1))
    predictions = for {:ok, pred} <- results, do: pred
    emit_stop(metadata, length(selected), length(predictions), not is_nil(reduce_fn))

    case predictions do
      [] -> raise all_failed(results)
      preds -> reduce(preds, reduce_fn)
    end
  end

  def run(programs, inputs, _opts)
      when not is_list(programs) or programs == [] or not is_map(inputs) do
    raise ArgumentError,
          "Ensemble.run/3 requires a non-empty list of %Dsxir.Program{} and a map of inputs"
  end

  defp sample(programs, nil), do: programs

  defp sample(programs, size) when is_integer(size) and size >= 1,
    do: Enum.take_random(programs, size)

  defp sample(_programs, size),
    do: raise(ArgumentError, ":size must be a positive integer, got: #{inspect(size)}")

  defp reduce(preds, nil), do: preds
  defp reduce(preds, fun) when is_function(fun, 1), do: fun.(preds)

  defp normalize_result({:ok, {%Program{}, %Prediction{} = pred}}), do: {:ok, pred}
  defp normalize_result({:exit, reason}), do: {:error, exit_error(reason)}

  defp exit_error({%{__exception__: true} = exception, _stacktrace}), do: exception
  defp exit_error(%{__exception__: true} = exception), do: exception

  defp exit_error(reason),
    do: %Dsxir.Errors.Framework.PredictorError{predictor: __MODULE__, reason: reason}

  defp all_failed(results) do
    last_error =
      results
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:error, e} -> e
        _ -> false
      end)

    %Dsxir.Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: last_error,
      reason: :all_failed
    }
  end

  defp emit_member(metadata, {:ok, _pred}) do
    Telemetry.emit(
      Telemetry.ensemble_member(),
      %{},
      Map.merge(metadata, %{ok?: true, failed?: false})
    )
  end

  defp emit_member(metadata, {:error, _error}) do
    Telemetry.emit(
      Telemetry.ensemble_member(),
      %{},
      Map.merge(metadata, %{ok?: false, failed?: true})
    )
  end

  defp emit_stop(metadata, members_run, successes, reduced?) do
    Telemetry.emit(
      Telemetry.ensemble_stop(),
      %{members_run: members_run, successes: successes},
      Map.merge(metadata, %{reduced?: reduced?})
    )
  end
end
