defmodule Dsxir.Predictor.Parallel do
  @moduledoc """
  Fan-out predictor helper. Runs N predictor calls concurrently under
  `Dsxir.TaskSupervisor`, replaying the caller's `Dsxir.Settings.snapshot/0`
  in each worker so settings-scoped state (metadata, lm, adapter, cache)
  is preserved.

  Returns `{prog', results}` where `results` mirrors the input order:
  successful entries are `{:ok, prediction}` and failures are
  `{:error, exception}`. The caller decides whether to raise — Parallel does
  not.

  ## Iron Law of OTP

  Workers are short-lived `Task`s, no mutable state across calls. Concurrency
  is required (fan-out is the purpose). Fault isolation is required, hence
  `Task.Supervisor.async_stream_nolink/4`: a worker crash does not link back
  to the caller, and `on_timeout: :kill_task` reaps slow workers so they do
  not block the stream.
  """

  alias Dsxir.Module.Runtime
  alias Dsxir.Program
  alias Dsxir.Settings

  @type request :: {atom(), map()}
  @type result :: {:ok, Dsxir.Prediction.t()} | {:error, Exception.t()}

  @default_timeout 30_000

  @spec run(Program.t(), [request()], keyword()) :: {Program.t(), [result()]}
  def run(%Program{} = prog, requests, opts \\ []) when is_list(requests) do
    snapshot = Settings.snapshot()
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Dsxir.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      requests,
      fn {name, inputs} ->
        Settings.run(snapshot, fn ->
          Runtime.call(prog, name, inputs, opts)
        end)
      end,
      max_concurrency: max_concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(requests)
    |> Enum.reduce({prog, []}, &reduce_result/2)
    |> then(fn {prog2, results} -> {prog2, Enum.reverse(results)} end)
  end

  defp reduce_result({{:ok, {worker_prog, prediction}}, {name, _inputs}}, {acc_prog, acc}) do
    merged = Program.put_state(acc_prog, name, Program.get_state(worker_prog, name))
    {merged, [{:ok, prediction} | acc]}
  end

  defp reduce_result({{:exit, reason}, {name, _inputs}}, {acc_prog, acc}) do
    {acc_prog, [{:error, exit_to_error(name, reason)} | acc]}
  end

  defp exit_to_error(_name, {%{__exception__: true} = exception, _stacktrace}), do: exception

  defp exit_to_error(_name, %{__exception__: true} = exception), do: exception

  defp exit_to_error(name, :timeout) do
    %Dsxir.Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: name,
      reason: :timeout
    }
  end

  defp exit_to_error(name, reason) do
    %Dsxir.Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: name,
      reason: reason
    }
  end
end
