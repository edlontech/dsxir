defmodule Dsxir.Stream do
  @moduledoc """
  Lazy streaming of a single predictor call — the DSPy `streamify` analog.

  `run/4` returns an `Enumerable` that, when enumerated, runs predictor `name` on
  `program` and yields `%Dsxir.Stream.Event{}` values as tokens arrive, ending
  with the final `%Dsxir.Prediction{}` as the last element:

      program
      |> Dsxir.stream(:answer, %{question: "..."}, listen: [:answer])
      |> Enum.each(fn
        %Dsxir.Stream.Event{type: :field_delta, data: token} -> IO.write(token)
        %Dsxir.Prediction{} = prediction -> IO.inspect(prediction)
      end)

  `opts` accepts `:listen` (field-level streaming) and any other predictor opt;
  the `:stream` sink is supplied internally. `:stream_timeout` (default 60s)
  bounds the wait between events.

  A single named predictor is streamed because only `Dsxir.Module.Runtime.call/4`
  propagates per-call opts to the predictor — the multi-node executor does not —
  and per-predictor listening mirrors how DSPy attaches stream listeners.

  ## Process model

  The forward pass runs in a task under `Dsxir.TaskSupervisor`, replaying the
  caller's `Dsxir.Settings.snapshot/0` (captured eagerly at call time) so the
  task resolves the same lm/adapter/metadata. The producer-to-consumer hand-off
  is a mailbox: the sink sends each event to the enumerating process, and the
  task's return value delivers the prediction last. The consuming process stays
  responsive; a forward-pass crash surfaces as a raised exception during
  enumeration rather than killing the consumer, and halting the stream early
  reaps the task.
  """

  alias Dsxir.Program
  alias Dsxir.Settings

  @default_timeout 60_000

  @doc """
  Return a lazy `Enumerable` that streams predictor `name` on `program`, yielding
  `%Dsxir.Stream.Event{}` values followed by the final `%Dsxir.Prediction{}`. See
  the module doc for the process model and recognised `opts`.
  """
  @spec run(Program.t(), atom(), map(), keyword()) :: Enumerable.t()
  def run(%Program{} = program, name, inputs, opts \\ [])
      when is_atom(name) and is_map(inputs) and is_list(opts) do
    snapshot = Settings.snapshot()
    {timeout, run_opts} = Keyword.pop(opts, :stream_timeout, @default_timeout)

    Stream.resource(
      fn -> start(program, name, inputs, run_opts, snapshot, timeout) end,
      &next/1,
      &cleanup/1
    )
  end

  defp start(program, name, inputs, opts, snapshot, timeout) do
    consumer = self()
    ref = make_ref()

    sink = fn event ->
      send(consumer, {ref, :event, event})
      :ok
    end

    task =
      Task.Supervisor.async_nolink(Dsxir.TaskSupervisor, fn ->
        Settings.run(snapshot, fn ->
          {_program, prediction} =
            Dsxir.Module.Runtime.call(program, name, inputs, Keyword.put(opts, :stream, sink))

          prediction
        end)
      end)

    %{ref: ref, task: task, timeout: timeout}
  end

  defp next(:halt), do: {:halt, :halt}

  defp next(%{ref: ref, task: task, timeout: timeout} = state) do
    receive do
      {^ref, :event, event} ->
        {[event], state}

      {task_ref, prediction} when task_ref == task.ref ->
        Process.demonitor(task.ref, [:flush])
        {[prediction], :halt}

      {:DOWN, task_ref, :process, _pid, reason} when task_ref == task.ref ->
        raise_down(reason)
    after
      timeout ->
        stop(task)

        raise %Dsxir.Errors.Framework.PredictorError{
          predictor: __MODULE__,
          signature: nil,
          inner: nil,
          reason: :stream_timeout
        }
    end
  end

  defp cleanup(:halt), do: :ok

  defp cleanup(%{task: task}) do
    stop(task)
    :ok
  end

  defp stop(task) do
    Process.exit(task.pid, :kill)
    Process.demonitor(task.ref, [:flush])
  end

  defp raise_down({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace) do
    reraise exception, stacktrace
  end

  defp raise_down(reason) do
    raise %Dsxir.Errors.Framework.PredictorError{
      predictor: __MODULE__,
      signature: nil,
      inner: nil,
      reason: reason
    }
  end
end
