defmodule MyApp.CoproSessionProbe do
  @moduledoc false
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :check, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    {prog, _} = call(prog, :check, %{question: q})
    call(prog, :answer, %{question: q})
  end
end

defmodule Dsxir.Optimizer.COPROSessionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Errors
  alias Dsxir.Example
  alias Dsxir.Optimizer
  alias Dsxir.Optimizer.COPRO
  alias Dsxir.Optimizer.MIPROv2
  alias Dsxir.OptimizerSession
  alias Dsxir.OptimizerSession.Checkpoint
  alias Dsxir.OptimizerSession.Store.ETS, as: ETSStore
  alias Dsxir.Program

  @winner "WINNER-INSTRUCTION"

  setup :set_mimic_global

  setup do
    prior = Dsxir.Settings.snapshot()

    on_exit(fn ->
      :persistent_term.put({Dsxir.Settings, :globals}, prior.globals)

      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defp ex(q, a), do: Example.new(%{question: q, answer: a}, input_keys: [:question])

  defp trainset, do: Enum.map(1..4, fn i -> ex("q-#{i}", "a-#{i}") end)

  defp metric(_ex, %Dsxir.Prediction{fields: %{answer: a}}, _t) when is_binary(a) do
    if String.contains?(a, "won"), do: 1.0, else: 0.0
  end

  defp proposer_lm do
    reply = """
    1. #{@winner}
    2. distractor-A
    3. distractor-B
    4. distractor-C
    """

    {Dsxir.Test.Fixtures.StubProposerLM, [model: "stub", reply: reply]}
  end

  defp stub_task_lm do
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, messages, _opts ->
      system =
        messages
        |> Enum.filter(fn m -> m.role == :system end)
        |> Enum.map_join("\n", & &1.content)

      verdict = if String.contains?(system, @winner), do: "won", else: "lost"
      {:ok, "[[ ## answer ## ]]\n#{verdict}", Dsxir.LM.empty_usage()}
    end)
  end

  defp baseline_overrides do
    {:ok, compiled, _stats} =
      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        Dsxir.compile(COPRO, Program.new(MyApp.CoproSessionProbe), trainset(), &metric/3,
          auto: :light,
          proposer_lm: proposer_lm()
        )
      end)

    Program.get_state(compiled, :answer).instructions_override
  end

  test "checkpointable?/1 accepts COPRO" do
    assert {:ok, COPRO} = Optimizer.checkpointable?(COPRO)
  end

  test "OptimizerSession.compile/5 converges to the same overrides as compile/4" do
    stub_task_lm()
    baseline = baseline_overrides()
    assert baseline == @winner

    {:ok, compiled, stats} =
      Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        OptimizerSession.compile(
          COPRO,
          Program.new(MyApp.CoproSessionProbe),
          trainset(),
          &metric/3,
          auto: :light,
          proposer_lm: proposer_lm()
        )
      end)

    assert %Program{} = compiled
    assert Program.get_state(compiled, :answer).instructions_override == baseline
    assert stats.best_score > 0.0
  end

  test "pause, kill, resume_session finishes to the same overrides as compile/4" do
    stub_task_lm()
    baseline = baseline_overrides()
    program = Program.new(MyApp.CoproSessionProbe)
    session_id = "sess_copro_resume"

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: COPRO,
          program: program,
          trainset: trainset(),
          metric: &metric/3,
          opts: [auto: :light, proposer_lm: proposer_lm()],
          session_id: session_id
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      snapshot = OptimizerSession.poll(pid)
      assert snapshot.trials_completed >= 1

      {:ok, %Checkpoint{} = cp} = ETSStore.get_checkpoint([], session_id)
      assert is_binary(cp.sampler_blob)
      assert byte_size(cp.sampler_blob) > 0
      assert {COPRO, 1} = cp.sampler_format

      Process.unlink(pid)
      Process.exit(pid, :brutal_kill)
      wait_for_pid_down(pid, 2_000)

      {:ok, resumed} =
        OptimizerSession.resume_session(:ets, session_id,
          optimizer: COPRO,
          program: program,
          trainset: trainset(),
          metric: &metric/3
        )

      {:ok, result} = OptimizerSession.await(resumed, 30_000)
      assert %Program{} = result.best_program
      assert Program.get_state(result.best_program, :answer).instructions_override == baseline
    end)
  end

  test "resume with different trainset returns ResumeMismatch{reason: :trainset_hash}" do
    stub_task_lm()
    program = Program.new(MyApp.CoproSessionProbe)
    session_id = "sess_copro_trainset_mismatch"

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: COPRO,
          program: program,
          trainset: trainset(),
          metric: &metric/3,
          opts: [auto: :light, proposer_lm: proposer_lm()],
          session_id: session_id
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      Process.unlink(pid)
      Process.exit(pid, :brutal_kill)
      wait_for_pid_down(pid, 2_000)

      Process.flag(:trap_exit, true)
      different_trainset = trainset() ++ [ex("extra", "answer")]

      assert {:error, %Errors.Invalid.ResumeMismatch{reason: :trainset_hash}} =
               OptimizerSession.resume_session(:ets, session_id,
                 optimizer: COPRO,
                 program: program,
                 trainset: different_trainset,
                 metric: &metric/3
               )
    end)
  end

  test "resume with MIPROv2 against a COPRO checkpoint returns ResumeMismatch{reason: :optimizer}" do
    stub_task_lm()
    program = Program.new(MyApp.CoproSessionProbe)
    session_id = "sess_copro_optimizer_mismatch"

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: COPRO,
          program: program,
          trainset: trainset(),
          metric: &metric/3,
          opts: [auto: :light, proposer_lm: proposer_lm()],
          session_id: session_id
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      Process.unlink(pid)
      Process.exit(pid, :brutal_kill)
      wait_for_pid_down(pid, 2_000)

      Process.flag(:trap_exit, true)

      assert {:error, %Errors.Invalid.ResumeMismatch{reason: :optimizer}} =
               OptimizerSession.resume_session(:ets, session_id,
                 optimizer: MIPROv2,
                 program: program,
                 trainset: trainset(),
                 metric: &metric/3
               )
    end)
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
