defmodule Dsxir.OptimizerSessionTest do
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

  test "compile/5 runs scripted trials and returns the best program" do
    scores = [0.6, 0.85, 0.7, 0.9, 0.55]

    {:ok, _prog, stats} =
      OptimizerSession.compile(
        MimicOptimizer,
        dummy_program(),
        [%{x: 1}],
        dummy_metric(),
        scripted_scores: scores
      )

    assert stats.best_score == 0.9
    assert stats.trials_completed == 5
    assert stats.errors == 0
  end

  test "poll/1 reflects progress after completion" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7]]
      )

    {:ok, _result} = OptimizerSession.await(pid, 5000)

    final = OptimizerSession.poll(pid)
    assert final.status == :completed
    assert final.trials_completed == 3
    assert final.best_score == 0.7
  end

  test "one checkpoint per trial; trial_log length equals completed count" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.4, 0.5, 0.6]],
        session_id: "sess_log_test"
      )

    {:ok, _} = OptimizerSession.await(pid, 5000)

    {:ok, cp} = Dsxir.OptimizerSession.Store.ETS.get_checkpoint([], "sess_log_test")
    assert length(cp.progress.trial_log) == 3
    assert cp.status == :completed
  end

  test "start_link returns NotCheckpointable for non-opted optimizer" do
    defmodule NonCheckpointable do
      @behaviour Dsxir.Optimizer
      def compile(_p, _t, _m, _o), do: {:ok, nil, %{}}
    end

    Process.flag(:trap_exit, true)

    assert {:error, %Dsxir.Errors.Invalid.NotCheckpointable{}} =
             OptimizerSession.start_link(
               optimizer: NonCheckpointable,
               program: dummy_program(),
               trainset: [%{x: 1}],
               metric: dummy_metric(),
               opts: []
             )
  end

  test "telemetry: :start and :trial events fire with session metadata" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:dsxir, :optimizer_session, :start],
        [:dsxir, :optimizer_session, :trial],
        [:dsxir, :optimizer_session, :checkpoint]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, _, _} =
      OptimizerSession.compile(
        MimicOptimizer,
        dummy_program(),
        [%{x: 1}],
        dummy_metric(),
        scripted_scores: [0.5, 0.6]
      )

    assert_receive {[:dsxir, :optimizer_session, :start], ^ref, _, _}
    assert_receive {[:dsxir, :optimizer_session, :trial], ^ref, _, %{trial_idx: 0}}
    assert_receive {[:dsxir, :optimizer_session, :trial], ^ref, _, %{trial_idx: 1}}
    assert_receive {[:dsxir, :optimizer_session, :checkpoint], ^ref, _, _}
  end

  test "resume on a non-paused session returns {:error, :not_paused}" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5]]
      )

    {:ok, _} = OptimizerSession.await(pid, 5000)
    assert OptimizerSession.resume(pid) == {:error, :not_paused}
  end

  test "start_link unwraps {:error, reason} from init_session failure" do
    defmodule FailingInitOptimizer do
      @behaviour Dsxir.Optimizer

      def compile(_p, _t, _m, _o), do: {:error, :unused}

      def init_session(_p, _t, _m, _o) do
        {:error,
         %Dsxir.Errors.Invalid.Configuration{
           key: :scripted_scores,
           value: nil,
           reason: "missing"
         }}
      end

      def step(_s, _i, _p, _t, _m, _o), do: {:halt, nil, :unused}
      def serialize_state(_s), do: {:ok, <<>>, 1}
      def deserialize_state(_b, _v), do: {:error, :unused}
    end

    Process.flag(:trap_exit, true)

    result =
      OptimizerSession.start_link(
        optimizer: FailingInitOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: []
      )

    assert {:error, %Dsxir.Errors.Invalid.Configuration{key: :scripted_scores}} = result
  end

  test "trial with injected error increments errors counter" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        opts: [scripted_scores: [0.5, 0.6, 0.7], errors_at_idx: [1]]
      )

    {:ok, _} = OptimizerSession.await(pid, 5000)
    final = OptimizerSession.poll(pid)

    assert final.errors == 1
    assert final.trials_completed == 2
    assert final.best_score == 0.7
  end

  test "exceeding max_errors yields OptimizerError with :framework-class inner aggregating original exception structs" do
    {:ok, pid} =
      OptimizerSession.start_link(
        optimizer: MimicOptimizer,
        program: dummy_program(),
        trainset: [%{x: 1}],
        metric: dummy_metric(),
        max_errors: 1,
        opts: [scripted_scores: [0.1, 0.2, 0.3, 0.4], errors_at_idx: [0, 1, 2]]
      )

    assert {:error,
            %Dsxir.Errors.Framework.OptimizerError{
              optimizer: MimicOptimizer,
              inner: %Dsxir.Errors.Framework{} = inner
            }} = OptimizerSession.await(pid, 5000)

    assert inner.class == :framework
    assert inner.bread_crumbs == ["optimizer_session.max_errors_exceeded"]
    assert is_list(inner.errors)
    assert length(inner.errors) >= 2
    assert Enum.all?(inner.errors, &match?(%RuntimeError{}, &1))
    assert Enum.all?(inner.errors, &(&1.message =~ "scripted error"))
  end
end
