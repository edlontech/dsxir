defmodule Dsxir.OptimizerSession do
  @moduledoc """
  Resumable optimizer session driver.

  Wraps a checkpointable `Dsxir.Optimizer` implementation in a `gen_statem`
  that schedules trials sequentially, persists a checkpoint after each trial,
  and exposes `poll/1`, `await/2`, and a synchronous `compile/5` wrapper.

  Pause / resume / cancel are soft signals: setting `pause` or `cancel` lets
  the in-flight trial complete and be checkpointed before the status moves
  to `:paused` / `:cancelled`. Crashed sessions can be rehydrated from a
  persisted checkpoint via `resume_session/3`.

  Note: `await/2`'s `timeout` is enforced client-side. The underlying
  `:gen_statem.call/3` uses `:infinity` as the transport timeout so that
  enqueued awaiters are cleaned up via monitor-and-prune rather than left
  as stale alias entries on a call-side exit. Callers that need a hard
  deadline should wrap `await/2` in a `Task` and apply their own timeout.

  `compile/5` accepts `:timeout` in `opts`; defaults to 5 minutes (overridable
  via `Application.compile_env(:dsxir, :compile_default_timeout, ms)`). On
  timeout the session is cancelled (soft) and `{:error, %OptimizerError{inner:
  :timeout}}` is returned to the caller; the session pid continues running
  briefly until its in-flight trial completes and the checkpoint is flushed.
  """

  @behaviour :gen_statem

  alias Dsxir.Artifact
  alias Dsxir.Errors
  alias Dsxir.Optimizer
  alias Dsxir.OptimizerSession.Checkpoint
  alias Dsxir.OptimizerSession.Data
  alias Dsxir.OptimizerSession.Store
  alias Dsxir.Settings
  alias Dsxir.Telemetry

  @default_max_errors 5
  @default_compile_timeout Application.compile_env(
                             :dsxir,
                             :compile_default_timeout,
                             :timer.minutes(5)
                           )

  @event_start [:dsxir, :optimizer_session, :start]
  @event_trial [:dsxir, :optimizer_session, :trial]
  @event_checkpoint [:dsxir, :optimizer_session, :checkpoint]
  @event_pause [:dsxir, :optimizer_session, :pause]
  @event_resume [:dsxir, :optimizer_session, :resume]
  @event_cancel [:dsxir, :optimizer_session, :cancel]
  @event_stop [:dsxir, :optimizer_session, :stop]
  @event_exception [:dsxir, :optimizer_session, :exception]

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_under_supervisor, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  @spec start_under_supervisor(tuple()) :: {:ok, pid()} | {:error, term()}
  def start_under_supervisor({:fresh, opts, gen_opts, name}) do
    args = {:fresh, opts}
    :gen_statem.start_link(name, __MODULE__, args, gen_opts)
  end

  def start_under_supervisor({:resume, store_spec, session_id, opts, gen_opts, name}) do
    args = {:resume, store_spec, session_id, opts}
    :gen_statem.start_link(name, __MODULE__, args, gen_opts)
  end

  @doc """
  Start a fresh session under `Dsxir.OptimizerSession.DynamicSupervisor`.

  Required opts: `:optimizer`, `:program`, `:trainset`, `:metric`, `:opts`.
  Optional: `:session_id` (auto-generated when absent), `:name`,
  `:settings_snapshot`, `:max_errors`, `:store`.

  Returns `{:error, :already_running}` if a session with the same
  `session_id` is already registered.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    gen_opts = [hibernate_after: 5_000]

    opts =
      opts
      |> Keyword.put_new_lazy(:settings_snapshot, &Settings.snapshot/0)
      |> Keyword.put_new_lazy(:session_id, &gen_session_id/0)

    session_id = Keyword.fetch!(opts, :session_id)

    name =
      case Keyword.get(opts, :name) do
        nil -> via_tuple(session_id)
        explicit -> {:local, explicit}
      end

    spec = %{
      id: {__MODULE__, session_id},
      start: {__MODULE__, :start_under_supervisor, [{:fresh, opts, gen_opts, name}]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    Dsxir.OptimizerSession.DynamicSupervisor
    |> DynamicSupervisor.start_child(spec)
    |> normalize_start_result()
  end

  @doc "Snapshot the current session state without blocking."
  @spec poll(:gen_statem.server_ref()) :: map()
  def poll(ref), do: :gen_statem.call(ref, :poll)

  @doc """
  Block until the session reaches a terminal state.

  `timeout` is enforced client-side via a wrapping `Task` so abandoned
  awaiters are pruned via monitor on the caller. Returns `{:ok, result}`
  on `:completed`, `{:error, _}` on `:failed`/`:paused`/`:cancelled`,
  `{:error, :timeout}` on deadline, or `{:error, {:session_down, reason}}`
  if the session crashed.
  """
  @spec await(:gen_statem.server_ref(), timeout()) :: {:ok, map()} | {:error, term()}
  def await(ref, timeout \\ :infinity) do
    case timeout do
      :infinity ->
        :gen_statem.call(ref, {:await, :infinity}, :infinity)

      ms when is_integer(ms) and ms >= 0 ->
        task = Task.async(fn -> :gen_statem.call(ref, {:await, :infinity}, :infinity) end)

        case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:session_down, reason}}
          nil -> {:error, :timeout}
        end
    end
  end

  @doc "Soft-pause the session: in-flight trial completes and is checkpointed before transitioning to `:paused`."
  @spec pause(:gen_statem.server_ref()) :: :ok | {:error, term()}
  def pause(ref), do: :gen_statem.call(ref, :pause)

  @doc "Resume a paused session. Returns `{:error, :not_paused}` from any other state."
  @spec resume(:gen_statem.server_ref()) :: :ok | {:error, term()}
  def resume(ref), do: :gen_statem.call(ref, :resume_signal)

  @doc "Soft-cancel the session: in-flight trial completes and is checkpointed before transitioning to `:cancelled`."
  @spec cancel(:gen_statem.server_ref()) :: :ok | {:error, term()}
  def cancel(ref), do: :gen_statem.call(ref, :cancel)

  @doc """
  Rehydrate a session from a persisted checkpoint.

  Refuses terminal sessions (`:completed`/`:failed`/`:cancelled`) with
  `AlreadyTerminal`. `:paused` is resumable. Trainset hash, optimizer
  module, and sampler-format version are verified; mismatch returns a
  `ResumeMismatch`. Required opts: `:program`, `:trainset`, `:metric`.
  """
  @spec resume_session(Store.store_spec(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def resume_session(store_spec, session_id, opts \\ []) do
    gen_opts = [hibernate_after: 5_000]
    opts = Keyword.put_new_lazy(opts, :settings_snapshot, &Settings.snapshot/0)

    name =
      case Keyword.get(opts, :name) do
        nil -> via_tuple(session_id)
        explicit -> {:local, explicit}
      end

    spec = %{
      id: {__MODULE__, session_id},
      start:
        {__MODULE__, :start_under_supervisor,
         [{:resume, store_spec, session_id, opts, gen_opts, name}]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }

    Dsxir.OptimizerSession.DynamicSupervisor
    |> DynamicSupervisor.start_child(spec)
    |> normalize_start_result()
  end

  defp via_tuple(session_id) do
    {:via, Registry, {Dsxir.OptimizerSession.Registry, session_id}}
  end

  defp normalize_start_result({:error, {:already_started, _pid}}), do: {:error, :already_running}
  defp normalize_start_result(other), do: other

  @doc "List checkpoint listings from the given store. Filter keys: `:status`, `:optimizer`, `:updated_since`."
  @spec list_sessions(Store.store_spec(), keyword()) ::
          {:ok, [Store.listing()]} | {:error, term()}
  def list_sessions(store_spec, filter \\ []) do
    {mod, opts} = Store.resolve(store_spec)
    mod.list_sessions(opts, filter)
  end

  @doc "Delete a persisted session checkpoint. Idempotent: returns `:ok` even if absent."
  @spec delete_session(Store.store_spec(), String.t()) :: :ok | {:error, term()}
  def delete_session(store_spec, session_id) do
    {mod, opts} = Store.resolve(store_spec)
    mod.delete_checkpoint(opts, session_id)
  end

  @doc """
  Synchronous wrapper: start a fresh session and await its terminal result.

  `:timeout` (in `opts`) defaults to
  `Application.compile_env(:dsxir, :compile_default_timeout, :timer.minutes(5))`.
  On deadline, soft-cancels the session and returns
  `{:error, %Errors.Framework.OptimizerError{inner: :timeout}}`.
  """
  @spec compile(
          module(),
          Dsxir.Program.t(),
          [Dsxir.Example.t()],
          nil | Dsxir.Metric.t(),
          keyword()
        ) ::
          {:ok, Dsxir.Program.t(), map()} | {:error, term()}
  def compile(optimizer, program, trainset, metric, opts) do
    {timeout, opts} = Keyword.pop(opts, :timeout, @default_compile_timeout)

    case start_link(
           optimizer: optimizer,
           program: program,
           trainset: trainset,
           metric: metric,
           opts: opts
         ) do
      {:ok, pid} ->
        await_compile(pid, optimizer, timeout)

      {:error, _} = err ->
        err
    end
  end

  defp await_compile(pid, optimizer, timeout) do
    case await(pid, timeout) do
      {:ok, %{best_program: p, stats: s}} ->
        {:ok, p, s}

      {:error, :timeout} ->
        cancel(pid)
        {:error, %Errors.Framework.OptimizerError{optimizer: optimizer, inner: :timeout}}

      {:error, {:session_down, reason}} ->
        {:error, %Errors.Framework.OptimizerError{optimizer: optimizer, inner: reason}}

      {:error, _} = err ->
        err
    end
  end

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl :gen_statem
  def init({:fresh, opts}) do
    with {:ok, optimizer} <- validate_optimizer(opts),
         {:ok, data} <- build_fresh_data(optimizer, opts),
         :ok <- write_initial_checkpoint(data) do
      Telemetry.emit(@event_start, %{}, %{
        session_id: data.session_id,
        optimizer: data.optimizer,
        planned_trials: data.planned_trials,
        store: elem(data.store, 0)
      })

      {:ok, :idle, data}
    else
      {:error, reason} ->
        emit_init_exception(:fresh, reason)
        {:stop, reason}
    end
  end

  def init({:resume, store_spec, session_id, opts}) do
    {mod, store_opts} = Store.resolve(store_spec)

    with {:ok, cp} <- mod.get_checkpoint(store_opts, session_id),
         :ok <- refuse_if_terminal(cp),
         :ok <- refuse_if_mismatch(cp, opts),
         {opt_mod, version} <- cp.sampler_format,
         {:ok, sampler_state} <- opt_mod.deserialize_state(cp.sampler_blob, version),
         {:ok, data} <- build_resumed_data(cp, mod, store_opts, sampler_state, opts) do
      Telemetry.emit(
        @event_resume,
        %{trials_completed: data.completed, blob_bytes: byte_size(cp.sampler_blob)},
        %{session_id: session_id, optimizer: data.optimizer}
      )

      {:ok, _} = persist_checkpoint(data, :running)
      {:ok, :idle, data}
    else
      {:error, :not_found} ->
        emit_init_exception({:resume, session_id}, :not_found)
        {:stop, :not_found}

      {:error, %Errors.Invalid.AlreadyTerminal{} = e} ->
        emit_init_exception({:resume, session_id}, e)
        {:stop, e}

      {:error, %Errors.Invalid.ResumeMismatch{} = e} ->
        emit_init_exception({:resume, session_id}, e)
        {:stop, e}

      {:error, :version_mismatch} ->
        err = %Errors.Invalid.ResumeMismatch{
          session_id: session_id,
          reason: :sampler_version,
          expected: nil,
          got: nil
        }

        emit_init_exception({:resume, session_id}, err)
        {:stop, err}

      {:error, other} ->
        emit_init_exception({:resume, session_id}, other)
        {:stop, other}
    end
  end

  defp emit_init_exception(source, reason) do
    session_id =
      case source do
        {:resume, id} -> id
        _ -> nil
      end

    Telemetry.emit(
      @event_exception,
      %{duration_ms: 0},
      %{
        session_id: session_id,
        phase: :init,
        kind: :error,
        reason: reason,
        exception_class: Errors.class_of(reason),
        stacktrace: []
      }
    )
  end

  defp build_resumed_data(cp, mod, store_opts, sampler_state, opts) do
    trainset = Keyword.fetch!(opts, :trainset)
    metric = Keyword.get(opts, :metric)

    expected_hash = cp.trainset_hash
    got_hash = Checkpoint.hash_trainset(trainset)

    if got_hash != expected_hash do
      {:error,
       %Errors.Invalid.ResumeMismatch{
         session_id: cp.session_id,
         reason: :trainset_hash,
         expected: expected_hash,
         got: got_hash
       }}
    else
      program = resolve_resume_program(cp, opts)

      data = %Data{
        session_id: cp.session_id,
        optimizer: cp.optimizer,
        program: program,
        program_module: cp.program_module,
        trainset: trainset,
        trainset_hash: expected_hash,
        metric: metric,
        opts: cp.optimizer_opts,
        max_errors: Keyword.get(opts, :max_errors, @default_max_errors),
        store: {mod, store_opts},
        settings_snapshot: Keyword.get_lazy(opts, :settings_snapshot, &Settings.snapshot/0),
        sampler_state: sampler_state,
        planned_trials: :unknown,
        best_program: program,
        best_score: cp.progress.best_score,
        best_trial_idx: cp.progress.best_trial_idx,
        trial_log: Enum.reverse(cp.progress.trial_log),
        attempts: cp.progress.attempts,
        completed: cp.progress.completed,
        errors: cp.progress.errors,
        started_at: cp.progress.started_at,
        trial_task_ref: nil,
        next_trial_idx: length(cp.progress.trial_log),
        awaiters: []
      }

      {:ok, data}
    end
  end

  defp resolve_resume_program(%Checkpoint{best_program_artifact: nil}, opts) do
    Keyword.fetch!(opts, :program)
  end

  defp resolve_resume_program(
         %Checkpoint{best_program_artifact: artifact, program_module: mod},
         opts
       )
       when is_atom(mod) and not is_nil(mod) do
    case Artifact.decode(mod, artifact) do
      {:ok, program} -> program
      _ -> Keyword.fetch!(opts, :program)
    end
  end

  defp resolve_resume_program(
         %Checkpoint{best_program_artifact: artifact, program_module: nil},
         opts
       ) do
    Artifact.decode_and_hydrate(artifact)
  rescue
    _ -> Keyword.fetch!(opts, :program)
  end

  defp program_module_for(source) do
    case Dsxir.Program.Source.identity(source) do
      {:module, mod, _} -> mod
      {:runtime, _id, _version} -> nil
    end
  end

  defp refuse_if_terminal(%Checkpoint{status: :paused}), do: :ok

  defp refuse_if_terminal(%Checkpoint{status: s} = cp)
       when s in [:completed, :failed, :cancelled] do
    {:error, %Errors.Invalid.AlreadyTerminal{session_id: cp.session_id, status: s}}
  end

  defp refuse_if_terminal(_), do: :ok

  defp refuse_if_mismatch(cp, opts) do
    requested = Keyword.get(opts, :optimizer, cp.optimizer)

    if requested == cp.optimizer do
      :ok
    else
      {:error,
       %Errors.Invalid.ResumeMismatch{
         session_id: cp.session_id,
         reason: :optimizer,
         expected: cp.optimizer,
         got: requested
       }}
    end
  end

  defp validate_optimizer(opts) do
    optimizer = Keyword.fetch!(opts, :optimizer)

    case Optimizer.checkpointable?(optimizer) do
      {:ok, _} -> {:ok, optimizer}
      {:error, _} = err -> err
    end
  end

  defp build_fresh_data(optimizer, opts) do
    program = Keyword.fetch!(opts, :program)
    trainset = Keyword.fetch!(opts, :trainset)
    metric = Keyword.get(opts, :metric)
    opt_opts = Keyword.get(opts, :opts, [])
    store = Store.resolve(Keyword.get(opts, :store))
    session_id = Keyword.get_lazy(opts, :session_id, &gen_session_id/0)
    max_errors = Keyword.get(opts, :max_errors, @default_max_errors)

    case optimizer.init_session(program, trainset, metric, opt_opts) do
      {:ok, sampler_state, planned} ->
        snapshot = Keyword.get_lazy(opts, :settings_snapshot, &Settings.snapshot/0)
        now = DateTime.utc_now()

        data = %Data{
          session_id: session_id,
          optimizer: optimizer,
          program: program,
          program_module: program_module_for(program.source),
          trainset: trainset,
          trainset_hash: Checkpoint.hash_trainset(trainset),
          metric: metric,
          opts: opt_opts,
          max_errors: max_errors,
          store: store,
          settings_snapshot: snapshot,
          sampler_state: sampler_state,
          planned_trials: planned,
          best_program: nil,
          best_score: nil,
          best_trial_idx: nil,
          trial_log: [],
          attempts: 0,
          completed: 0,
          errors: 0,
          started_at: now,
          trial_task_ref: nil,
          next_trial_idx: 0,
          awaiters: []
        }

        {:ok, data}

      {:error, _} = err ->
        err
    end
  end

  defp write_initial_checkpoint(data) do
    {:ok, blob, version} = data.optimizer.serialize_state(data.sampler_state)

    cp =
      Checkpoint.new(
        session_id: data.session_id,
        optimizer: data.optimizer,
        optimizer_opts: data.opts,
        trainset_hash: data.trainset_hash,
        program_module: data.program_module,
        sampler_blob: blob,
        sampler_format: {data.optimizer, version}
      )

    {mod, store_opts} = data.store
    mod.put_checkpoint(store_opts, data.session_id, cp)
  end

  defp gen_session_id do
    bytes = :crypto.strong_rand_bytes(16)
    "sess_" <> Base.url_encode64(bytes, padding: false)
  end

  @impl :gen_statem
  def handle_event(:enter, _old, :idle, _data) do
    {:keep_state_and_data, [{:state_timeout, 0, :schedule_next}]}
  end

  def handle_event(:enter, _old, {:running, :scheduling}, _data) do
    {:keep_state_and_data, [{:state_timeout, 0, :schedule_next}]}
  end

  def handle_event(:enter, _old, {:running, :awaiting}, _data), do: :keep_state_and_data

  def handle_event(:enter, _old, status, data)
      when status in [:paused, :completed, :failed, :cancelled] do
    notify_awaiters(data, status)
    release_session_lock(data.session_id)

    Telemetry.emit(
      @event_stop,
      %{
        duration_ms: DateTime.diff(DateTime.utc_now(), data.started_at, :millisecond),
        trials_completed: data.completed,
        best_score: data.best_score
      },
      %{
        session_id: data.session_id,
        status: status,
        reason: status_reason(status, data),
        tenant_id: tenant_id_from_snapshot(data.settings_snapshot)
      }
    )

    :keep_state_and_data
  end

  def handle_event(:state_timeout, :schedule_next, _state, data) do
    parent = self()
    snapshot = data.settings_snapshot
    optimizer = data.optimizer
    sampler = data.sampler_state
    idx = data.next_trial_idx
    program = data.program
    trainset = data.trainset
    metric = data.metric
    opts = data.opts

    task =
      Task.Supervisor.async_nolink(Dsxir.TaskSupervisor, fn ->
        Settings.run(snapshot, fn ->
          start = System.monotonic_time(:millisecond)

          result =
            try do
              optimizer.step(sampler, idx, program, trainset, metric, opts)
            rescue
              e -> {:error, e, __STACKTRACE__}
            end

          stop = System.monotonic_time(:millisecond)
          send(parent, {:trial_done, self(), result, stop - start})
        end)
      end)

    {:next_state, {:running, :awaiting},
     %{data | trial_task_ref: task.ref, attempts: data.attempts + 1}}
  end

  def handle_event(:info, {:trial_done, _pid, result, duration_ms}, {:running, :awaiting}, data) do
    handle_trial_result(result, duration_ms, data)
  end

  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, reason},
        {:running, :awaiting},
        %Data{trial_task_ref: ref} = data
      )
      when reason != :normal do
    Telemetry.emit(
      @event_exception,
      %{duration_ms: 0},
      %{
        session_id: data.session_id,
        phase: :trial,
        kind: :exit,
        reason: reason,
        exception_class: :framework,
        stacktrace: [],
        tenant_id: tenant_id_from_snapshot(data.settings_snapshot)
      }
    )

    err = %Errors.Framework.OptimizerError{optimizer: data.optimizer, inner: reason}
    handle_trial_result({:error, err, []}, 0, data)
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, _reason}, _state, data) do
    case Enum.split_with(data.awaiters, fn {_from, mref} -> mref == ref end) do
      {[], _} -> :keep_state_and_data
      {_matched, remaining} -> {:keep_state, %{data | awaiters: remaining}}
    end
  end

  def handle_event(:info, {ref, _value}, _state, _data) when is_reference(ref) do
    :keep_state_and_data
  end

  def handle_event({:call, from}, :poll, state, data) do
    {:keep_state_and_data, [{:reply, from, build_poll_snapshot(state, data)}]}
  end

  def handle_event({:call, from}, {:await, _timeout}, state, data)
      when state in [:completed, :failed, :paused, :cancelled] do
    {:keep_state_and_data, [{:reply, from, build_await_result(state, data)}]}
  end

  def handle_event({:call, {caller_pid, _tag} = from}, {:await, _timeout}, _state, data) do
    monitor_ref = Process.monitor(caller_pid)
    {:keep_state, %{data | awaiters: [{from, monitor_ref} | data.awaiters]}, []}
  end

  def handle_event({:call, from}, :pause, state, data) do
    cond do
      state in [:completed, :failed, :cancelled] ->
        reply =
          {:error, %Errors.Invalid.AlreadyTerminal{session_id: data.session_id, status: state}}

        {:keep_state_and_data, [{:reply, from, reply}]}

      state == :paused ->
        {:keep_state_and_data, [{:reply, from, :ok}]}

      true ->
        if not data.pause_flag do
          Telemetry.emit(
            @event_pause,
            %{trials_completed: data.completed},
            %{session_id: data.session_id}
          )
        end

        {:keep_state, %{data | pause_flag: true}, [{:reply, from, :ok}]}
    end
  end

  def handle_event({:call, from}, :resume_signal, :paused, data) do
    Telemetry.emit(
      @event_resume,
      %{trials_completed: data.completed, blob_bytes: 0},
      %{session_id: data.session_id}
    )

    new_data = %{data | pause_flag: false}
    {:ok, _} = persist_checkpoint(new_data, :running)
    {:next_state, {:running, :scheduling}, new_data, [{:reply, from, :ok}]}
  end

  def handle_event({:call, from}, :resume_signal, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :not_paused}}]}
  end

  def handle_event({:call, from}, :cancel, state, data) do
    cond do
      state in [:completed, :failed, :cancelled] ->
        reply =
          {:error, %Errors.Invalid.AlreadyTerminal{session_id: data.session_id, status: state}}

        {:keep_state_and_data, [{:reply, from, reply}]}

      state == :paused ->
        Telemetry.emit(
          @event_cancel,
          %{trials_completed: data.completed},
          %{session_id: data.session_id}
        )

        {:ok, _} = persist_checkpoint(data, :cancelled)

        {:next_state, :cancelled,
         %{data | cancel_flag: true, terminal_reason: :cancelled, trial_task_ref: nil},
         [{:reply, from, :ok}]}

      true ->
        if not data.cancel_flag do
          Telemetry.emit(
            @event_cancel,
            %{trials_completed: data.completed},
            %{session_id: data.session_id}
          )
        end

        {:keep_state, %{data | cancel_flag: true}, [{:reply, from, :ok}]}
    end
  end

  defp handle_trial_result({:cont, sampler, trial}, duration_ms, data) do
    trial = Map.put(trial, :duration_ms, duration_ms)
    data = apply_trial(data, sampler, trial)
    next_status = compute_next_status(data)
    {:ok, _cp} = persist_checkpoint(data, next_status)
    emit_trial(data, trial)

    case next_status do
      :running ->
        {:next_state, {:running, :scheduling},
         %{data | next_trial_idx: data.next_trial_idx + 1, trial_task_ref: nil}}

      terminal ->
        {:next_state, terminal, %{data | terminal_reason: :ok, trial_task_ref: nil}}
    end
  end

  defp handle_trial_result({:halt, _sampler, reason}, _duration_ms, data) do
    {:ok, _cp} = persist_checkpoint(data, :completed, reason)
    {:next_state, :completed, %{data | terminal_reason: reason, trial_task_ref: nil}}
  end

  defp handle_trial_result({:error, exception, _stack}, duration_ms, data) do
    trial = %{
      trial_idx: data.next_trial_idx,
      candidate_id: nil,
      score: nil,
      status: :error,
      stats: nil,
      duration_ms: duration_ms,
      error: serialize_error(exception),
      error_class: Errors.class_of(exception),
      candidate_program: nil
    }

    data =
      data
      |> Map.update!(:errors, &(&1 + 1))
      |> Map.update!(:trial_log, &[trial | &1])

    next_status = compute_next_status(data)
    {:ok, _cp} = persist_checkpoint(data, next_status)
    emit_trial(data, trial)

    case next_status do
      :running ->
        {:next_state, {:running, :scheduling},
         %{data | next_trial_idx: data.next_trial_idx + 1, trial_task_ref: nil}}

      terminal ->
        {:next_state, terminal, %{data | terminal_reason: exception, trial_task_ref: nil}}
    end
  end

  defp apply_trial(data, sampler, %{status: :ok, score: score, candidate_program: cp} = trial) do
    data =
      data
      |> Map.put(:sampler_state, sampler)
      |> Map.update!(:completed, &(&1 + 1))
      |> Map.update!(:trial_log, &[trial | &1])

    if better_score?(score, data.best_score) do
      %{data | best_program: cp, best_score: score, best_trial_idx: trial.trial_idx}
    else
      data
    end
  end

  defp apply_trial(data, sampler, %{status: :error} = trial) do
    data
    |> Map.put(:sampler_state, sampler)
    |> Map.update!(:errors, &(&1 + 1))
    |> Map.update!(:trial_log, &[trial | &1])
  end

  defp better_score?(_new, nil), do: true
  defp better_score?(new, best), do: new > best

  defp compute_next_status(data) do
    cond do
      data.errors > data.max_errors -> :failed
      data.cancel_flag -> :cancelled
      data.pause_flag -> :paused
      true -> :running
    end
  end

  defp persist_checkpoint(data, status, terminal_reason \\ nil) do
    {:ok, blob, version} = data.optimizer.serialize_state(data.sampler_state)

    cp = %Checkpoint{
      session_id: data.session_id,
      optimizer: data.optimizer,
      optimizer_opts: data.opts,
      trainset_hash: data.trainset_hash,
      program_module: data.program_module,
      created_at: data.started_at,
      updated_at: DateTime.utc_now(),
      progress: %{
        trial_log: Enum.reverse(data.trial_log),
        best_score: data.best_score,
        best_trial_idx: data.best_trial_idx,
        attempts: data.attempts,
        completed: data.completed,
        errors: data.errors,
        started_at: data.started_at
      },
      best_program_artifact:
        if(data.best_program, do: Artifact.encode(data.best_program), else: nil),
      sampler_blob: blob,
      sampler_format: {data.optimizer, version},
      status: status,
      terminal_reason: serialize_terminal(terminal_reason)
    }

    {mod, store_opts} = data.store
    cp_bytes = byte_size(Checkpoint.encode(cp))
    :ok = mod.put_checkpoint(store_opts, data.session_id, cp)

    Telemetry.emit(
      @event_checkpoint,
      %{trial_idx: data.next_trial_idx, blob_bytes: cp_bytes, duration_ms: 0},
      %{session_id: data.session_id, status: status}
    )

    {:ok, cp}
  end

  defp serialize_terminal(nil), do: nil
  defp serialize_terminal(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp serialize_terminal(reason), do: inspect(reason)

  defp serialize_error(%{__struct__: _} = e), do: e
  defp serialize_error(other), do: %{inspected: inspect(other)}

  defp emit_trial(data, trial) do
    Telemetry.emit(
      @event_trial,
      %{score: trial.score, duration_ms: trial.duration_ms},
      %{
        session_id: data.session_id,
        trial_idx: trial.trial_idx,
        status: trial.status,
        error_class: trial.error_class,
        tenant_id: tenant_id_from_snapshot(data.settings_snapshot)
      }
    )
  end

  defp tenant_id_from_snapshot(%{stack: stack, globals: globals}) do
    metadata = lookup_metadata(stack, globals)
    Map.get(metadata, :tenant_id)
  end

  defp tenant_id_from_snapshot(_), do: nil

  defp lookup_metadata([frame | rest], globals) do
    case Map.fetch(frame, :metadata) do
      {:ok, %{} = m} -> m
      _ -> lookup_metadata(rest, globals)
    end
  end

  defp lookup_metadata([], globals), do: Map.get(globals, :metadata, %{})

  defp status_reason(:completed, data), do: data.terminal_reason
  defp status_reason(:failed, _data), do: :max_errors_exceeded
  defp status_reason(_, _), do: nil

  defp build_poll_snapshot(state, data) do
    %{
      status: poll_status(state),
      trials_completed: data.completed,
      trials_planned: data.planned_trials,
      best_score: data.best_score,
      best_trial_idx: data.best_trial_idx,
      errors: data.errors,
      last_trial: List.first(data.trial_log)
    }
  end

  defp poll_status(:idle), do: :idle
  defp poll_status({:running, _}), do: :running
  defp poll_status(status) when status in [:paused, :completed, :failed, :cancelled], do: status

  defp build_await_result(:completed, data) do
    {:ok,
     %{
       best_program: data.best_program,
       stats: build_stats(data),
       reason: data.terminal_reason
     }}
  end

  defp build_await_result(:failed, data) do
    err_trials = Enum.filter(data.trial_log, &(&1.status == :error))

    inner_errors =
      Enum.map(err_trials, fn t ->
        case t.error do
          %{__struct__: _} = e -> e
          %{inspected: inspected} -> %RuntimeError{message: inspected}
          nil -> %RuntimeError{message: "unknown trial error"}
          other -> %RuntimeError{message: inspect(other)}
        end
      end)

    inner =
      %Errors.Framework{
        errors: inner_errors,
        bread_crumbs: ["optimizer_session.max_errors_exceeded"]
      }

    {:error,
     %Errors.Framework.OptimizerError{
       optimizer: data.optimizer,
       inner: inner
     }}
  end

  defp build_await_result(state, data) when state in [:paused, :cancelled] do
    {:error,
     %{
       reason: state,
       snapshot: build_poll_snapshot(state, data)
     }}
  end

  defp build_stats(data) do
    %{
      best_score: data.best_score,
      best_trial_idx: data.best_trial_idx,
      trials_completed: data.completed,
      trials_attempted: data.attempts,
      errors: data.errors,
      trial_log: Enum.reverse(data.trial_log)
    }
  end

  defp notify_awaiters(data, state) do
    result = build_await_result(state, data)

    Enum.each(data.awaiters, fn {from, monitor_ref} ->
      Process.demonitor(monitor_ref, [:flush])
      :gen_statem.reply(from, result)
    end)
  end

  defp release_session_lock(session_id) do
    Registry.unregister(Dsxir.OptimizerSession.Registry, session_id)
    :ok
  end
end
