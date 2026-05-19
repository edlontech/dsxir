defmodule Dsxir.OptimizerSession.CrashRecoveryTest do
  use ExUnit.Case, async: false

  alias Dsxir.OptimizerSession
  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.Fixtures.MimicOptimizer

  setup do
    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defp dummy_program, do: Dsxir.Program.new(AnswerProgram)
  defp dummy_metric, do: fn _ex, _pred, _trace -> 0.0 end

  test "compile/5 with :timeout returns OptimizerError on deadline" do
    {:error, %Dsxir.Errors.Framework.OptimizerError{inner: :timeout}} =
      OptimizerSession.compile(
        MimicOptimizer,
        dummy_program(),
        [%{x: 1}],
        dummy_metric(),
        scripted_scores: [0.5, 0.6, 0.7, 0.8],
        step_delay_ms: 200,
        timeout: 50
      )
  end

  test "pause then resume completes the run" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7, 0.8, 0.9]],
        session_id: "sess_pause_test"
      )

    :ok = OptimizerSession.pause(pid)

    wait_for_status(pid, :paused, 1000)

    :ok = OptimizerSession.resume(pid)
    {:ok, result} = OptimizerSession.await(pid, 5000)

    assert result.best_program != nil
    final = OptimizerSession.poll(pid)
    assert final.status == :completed
  end

  test "cancel during run transitions to :cancelled" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7, 0.8]],
        session_id: "sess_cancel_test"
      )

    :ok = OptimizerSession.cancel(pid)
    {:error, %{reason: :cancelled, snapshot: snap}} = OptimizerSession.await(pid, 5000)

    assert snap.trials_completed >= 1
  end

  test "cancel from :paused transitions directly to :cancelled" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7]],
        session_id: "sess_pause_cancel_test"
      )

    :ok = OptimizerSession.pause(pid)
    wait_for_status(pid, :paused, 1000)

    :ok = OptimizerSession.cancel(pid)
    {:error, %{reason: :cancelled}} = OptimizerSession.await(pid, 5000)
  end

  test "pause on a terminal session returns AlreadyTerminal" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5]]
      )

    {:ok, _} = OptimizerSession.await(pid, 5000)

    assert {:error, %Dsxir.Errors.Invalid.AlreadyTerminal{status: :completed}} =
             OptimizerSession.pause(pid)

    assert {:error, %Dsxir.Errors.Invalid.AlreadyTerminal{status: :completed}} =
             OptimizerSession.cancel(pid)
  end

  test "crash mid-run (after pause) then resume continues to completion" do
    scores = [0.4, 0.5, 0.6, 0.7, 0.8]

    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: scores],
        session_id: "sess_crash_test"
      )

    :ok = OptimizerSession.pause(pid)
    wait_for_status(pid, :paused, 1000)

    Process.unlink(pid)
    Process.exit(pid, :brutal_kill)
    wait_for_pid_down(pid, 1000)

    {:ok, cp_before} =
      Dsxir.OptimizerSession.Store.ETS.get_checkpoint([], "sess_crash_test")

    completed_before = cp_before.progress.completed
    assert completed_before >= 1
    assert cp_before.status == :paused

    {:ok, resumed} =
      OptimizerSession.resume_session(:ets, "sess_crash_test",
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric()
      )

    {:ok, result} = OptimizerSession.await(resumed, 5000)
    assert result.stats.trials_completed >= completed_before
  end

  test "resume_session refuses terminal session" do
    {:ok, _, _} =
      OptimizerSession.compile(
        MimicOptimizer,
        dummy_program(),
        [%{x: 1}],
        dummy_metric(),
        scripted_scores: [0.5, 0.6]
      )

    {:ok, listings} = OptimizerSession.list_sessions(:ets, status: :completed)
    assert [%{session_id: id} | _] = listings

    Process.flag(:trap_exit, true)

    assert {:error, %Dsxir.Errors.Invalid.AlreadyTerminal{}} =
             OptimizerSession.resume_session(:ets, id,
               optimizer: MimicOptimizer,
               program: dummy_program(),
               trainset: [%{x: 1}],
               metric: dummy_metric()
             )
  end

  test "resume_session refuses trainset hash mismatch" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7, 0.8]],
        session_id: "sess_hash_mismatch"
      )

    :ok = OptimizerSession.pause(pid)
    wait_for_status(pid, :paused, 1000)
    Process.unlink(pid)
    Process.exit(pid, :brutal_kill)
    wait_for_pid_down(pid, 1000)

    Process.flag(:trap_exit, true)

    assert {:error, %Dsxir.Errors.Invalid.ResumeMismatch{reason: :trainset_hash}} =
             OptimizerSession.resume_session(:ets, "sess_hash_mismatch",
               optimizer: MimicOptimizer,
               program: dummy_program(),
               trainset: [%{x: :different}],
               metric: dummy_metric()
             )
  end

  test "session survives caller death (started under DynamicSupervisor)" do
    parent = self()

    caller =
      spawn(fn ->
        {:ok, pid} =
          OptimizerSession.start_link(
            optimizer: MimicOptimizer,
            program: dummy_program(),
            trainset: [%{x: 1}],
            metric: dummy_metric(),
            opts: [scripted_scores: [0.5, 0.6, 0.7, 0.8, 0.9]],
            session_id: "sess_survives_caller"
          )

        :ok = OptimizerSession.pause(pid)
        send(parent, {:session_pid, pid})
        Process.sleep(:infinity)
      end)

    session_pid =
      receive do
        {:session_pid, p} -> p
      after
        2000 -> flunk("did not receive session pid")
      end

    wait_for_status(session_pid, :paused, 1000)

    Process.exit(caller, :brutal_kill)
    Process.sleep(50)

    assert Process.alive?(session_pid)
    snapshot = OptimizerSession.poll(session_pid)
    assert snapshot.status == :paused
  end

  test "concurrent resume_session calls with same id: one wins, other returns :already_running" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7, 0.8, 0.9]],
        session_id: "sess_concurrent_resume"
      )

    :ok = OptimizerSession.pause(pid)
    wait_for_status(pid, :paused, 1000)
    Process.unlink(pid)
    Process.exit(pid, :brutal_kill)
    wait_for_pid_down(pid, 1000)

    Process.flag(:trap_exit, true)

    parent = self()

    spawn_one = fn ->
      result =
        OptimizerSession.resume_session(:ets, "sess_concurrent_resume",
          optimizer: MimicOptimizer,
          program: dummy_program(),
          trainset: [%{x: 1}],
          metric: dummy_metric()
        )

      send(parent, {:resume_result, result})
    end

    spawn(spawn_one)
    spawn(spawn_one)

    results =
      for _ <- 1..2 do
        receive do
          {:resume_result, r} -> r
        after
          2000 -> flunk("did not receive resume result")
        end
      end

    winners = Enum.filter(results, &match?({:ok, _pid}, &1))
    losers = Enum.filter(results, &(&1 == {:error, :already_running}))

    assert length(winners) == 1
    assert length(losers) == 1
  end

  test "list_sessions and delete_session at top level" do
    {:ok, _, _} =
      OptimizerSession.compile(
        MimicOptimizer,
        dummy_program(),
        [%{x: 1}],
        dummy_metric(),
        scripted_scores: [0.5]
      )

    {:ok, listings} = OptimizerSession.list_sessions(:ets, [])
    assert is_list(listings)
    assert listings != []

    [%{session_id: id} | _] = listings
    :ok = OptimizerSession.delete_session(:ets, id)
    :ok = OptimizerSession.delete_session(:ets, id)
  end

  defp wait_for_status(pid, target, deadline_ms) do
    start = System.monotonic_time(:millisecond)
    do_wait_for_status(pid, target, start, deadline_ms)
  end

  defp do_wait_for_status(pid, target, start, deadline_ms) do
    case OptimizerSession.poll(pid) do
      %{status: ^target} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) - start > deadline_ms do
          flunk("status did not reach #{inspect(target)} within #{deadline_ms}ms")
        else
          Process.sleep(5)
          do_wait_for_status(pid, target, start, deadline_ms)
        end
    end
  end

  defp wait_for_pid_down(pid, deadline_ms) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      deadline_ms ->
        Process.demonitor(ref, [:flush])
        flunk("pid did not die within #{deadline_ms}ms")
    end
  end
end
