defmodule Dsxir.Optimizer.SIMBASessionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Errors
  alias Dsxir.Optimizer.SIMBA
  alias Dsxir.OptimizerSession
  alias Dsxir.Prediction
  alias Dsxir.Program
  alias Dsxir.Program.State
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.Predictor.Predict)

    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  @lm {Dsxir.LM.Sycophant, [model: "stub"]}
  # bsize spans the whole trainset so every mini-batch carries score variance.
  @opts [auto: :light, bsize: 6, max_steps: 2, num_candidates: 2, seed: 1, num_threads: 2]

  defp trainset do
    for i <- 0..5, do: Dsxir.Example.new(%{q: "q#{i}", a: "good"}, input_keys: [:q])
  end

  # Graded so a mutated program improves (odd questions go 0.0 -> 0.5) without
  # ever reaching a uniform score: every step keeps score variance.
  defp metric do
    fn _ex, %Prediction{fields: fields}, _trace ->
      case Map.get(fields, :a) do
        "good" -> 1.0
        "ok" -> 0.5
        _ -> 0.0
      end
    end
  end

  defp guidance?(%State{demos: demos, instructions_override: override}) do
    demos != [] or not is_nil(override)
  end

  defp stub_lms do
    Mimic.stub(Dsxir.Predictor.Predict, :forward, fn %State{} = state, _sig, inputs, _opts ->
      fields =
        cond do
          Map.has_key?(inputs, :module_names) ->
            %{
              discussion: "compare",
              advice: [%{"module" => "answer", "advice" => "Answer like the better trajectory."}]
            }

          Map.has_key?(inputs, :category) ->
            %{a: answer_for(state, inputs)}

          true ->
            %{category: "general", reasoning: "step by step"}
        end

      {state, %Prediction{fields: fields}}
    end)
  end

  defp answer_for(state, %{q: q}) do
    cond do
      even_q?(q) -> "good"
      guidance?(state) -> "ok"
      true -> "bad"
    end
  end

  defp even_q?(q) do
    q |> String.trim_leading("q") |> String.to_integer() |> rem(2) == 0
  end

  defp program, do: Program.new(QA.TwoStep)

  test "session compile converges to the same best_score as non-session compile/4" do
    stub_lms()

    Dsxir.context([lm: @lm], fn ->
      {:ok, session_prog, session_stats} =
        OptimizerSession.compile(SIMBA, program(), trainset(), metric(), @opts)

      {:ok, compiled, compile_stats} =
        Dsxir.compile(SIMBA, program(), trainset(), metric(), @opts)

      assert session_stats.best_score == compile_stats.best_score
      assert session_prog.predictors |> Map.values() |> Enum.any?(&guidance?/1)
      assert compiled.predictors |> Map.values() |> Enum.any?(&guidance?/1)
    end)
  end

  test "checkpoint then resume_session converges to the same program as an uninterrupted session" do
    stub_lms()

    baseline =
      Dsxir.context([lm: @lm], fn ->
        {:ok, prog, _stats} =
          OptimizerSession.compile(SIMBA, program(), trainset(), metric(), @opts)

        prog
      end)

    resumed =
      Dsxir.context([lm: @lm], fn ->
        {:ok, pid} =
          OptimizerSession.start_link(
            optimizer: SIMBA,
            program: program(),
            trainset: trainset(),
            metric: metric(),
            opts: @opts,
            session_id: "sess_simba_resume"
          )

        :ok = OptimizerSession.pause(pid)
        wait_for_status(pid, :paused, 5_000)

        {:ok, listings} = OptimizerSession.list_sessions(:ets)
        assert Enum.any?(listings, &(&1.session_id == "sess_simba_resume"))

        Process.unlink(pid)
        Process.exit(pid, :brutal_kill)
        wait_for_pid_down(pid, 2_000)

        {:ok, rpid} =
          OptimizerSession.resume_session(:ets, "sess_simba_resume",
            optimizer: SIMBA,
            program: program(),
            trainset: trainset(),
            metric: metric()
          )

        {:ok, %{best_program: prog}} = OptimizerSession.await(rpid, 10_000)
        prog
      end)

    assert learned(resumed) == learned(baseline)
  end

  # Compares the learned content of each predictor (demo examples + instruction
  # override). Demo `source` metadata is dropped by the checkpoint artifact
  # round-trip, so we compare the Example payloads rather than whole structs.
  defp learned(%Program{} = prog) do
    Map.new(prog.predictors, fn {name, %State{} = state} ->
      demos = Enum.map(state.demos, & &1.example)
      {name, {demos, state.instructions_override}}
    end)
  end

  test "resume with a different trainset returns ResumeMismatch{reason: :trainset_hash}" do
    stub_lms()

    Dsxir.context([lm: @lm], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: SIMBA,
          program: program(),
          trainset: trainset(),
          metric: metric(),
          opts: @opts,
          session_id: "sess_simba_hash"
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      Process.unlink(pid)
      Process.exit(pid, :brutal_kill)
      wait_for_pid_down(pid, 2_000)

      Process.flag(:trap_exit, true)

      different =
        trainset() ++ [Dsxir.Example.new(%{q: "q99", a: "good"}, input_keys: [:q])]

      assert {:error, %Errors.Invalid.ResumeMismatch{reason: :trainset_hash}} =
               OptimizerSession.resume_session(:ets, "sess_simba_hash",
                 optimizer: SIMBA,
                 program: program(),
                 trainset: different,
                 metric: metric()
               )
    end)
  end

  test "resuming with a different optimizer returns ResumeMismatch{reason: :optimizer}" do
    stub_lms()

    Dsxir.context([lm: @lm], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: SIMBA,
          program: program(),
          trainset: trainset(),
          metric: metric(),
          opts: @opts,
          session_id: "sess_simba_optimizer"
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      Process.unlink(pid)
      Process.exit(pid, :brutal_kill)
      wait_for_pid_down(pid, 2_000)

      Process.flag(:trap_exit, true)

      assert {:error, %Errors.Invalid.ResumeMismatch{reason: :optimizer}} =
               OptimizerSession.resume_session(:ets, "sess_simba_optimizer",
                 optimizer: Dsxir.Optimizer.GEPA,
                 program: program(),
                 trainset: trainset(),
                 metric: metric()
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
