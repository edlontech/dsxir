defmodule Dsxir.Optimizer.GEPASessionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Metric.ScoreWithFeedback
  alias Dsxir.OptimizerSession

  setup :set_mimic_global

  setup do
    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defmodule SessionSig do
    use Dsxir.Signature

    signature do
      instruction("Summarize.")
      input(:text, :string)
      output(:summary, :string)
    end
  end

  defmodule SessionProbe do
    use Dsxir.Module

    predictor(:p, Dsxir.Predictor.Predict, signature: SessionSig)

    def forward(prog, %{text: t}) do
      {prog, p} = call(prog, :p, %{text: t})
      {prog, p}
    end
  end

  defp trainset do
    for i <- 1..8 do
      %Dsxir.Example{
        data: %{text: "t_#{i}", summary: "s_#{i}"},
        input_keys: MapSet.new([:text])
      }
    end
  end

  defp metric do
    fn ex, pred, _trace ->
      summary = Map.get(pred.fields, :summary)

      %ScoreWithFeedback{
        score: if(summary == ex.data.summary, do: 1.0, else: 0.0),
        feedback: nil
      }
    end
  end

  defp stub_lms do
    Mimic.copy(Dsxir.LM.Sycophant)

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
      {:ok, "new instruction", %{}}
    end)

    Mimic.copy(Dsxir.Program)

    Mimic.stub(Dsxir.Program, :forward, fn prog, %{text: t} ->
      summary = "s_" <> String.replace(t, "t_", "")
      {prog, %Dsxir.Prediction{fields: %{summary: summary}}}
    end)
  end

  test "session compile completes with GEPA and returns a best program" do
    stub_lms()
    program = Dsxir.Program.new(SessionProbe)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, compiled, stats} =
        OptimizerSession.compile(Dsxir.Optimizer.GEPA, program, trainset(), metric(),
          auto: :light,
          num_trials: 4,
          reflective_lm: {Dsxir.LM.Sycophant, [model: "stub"]}
        )

      assert %Dsxir.Program{} = compiled
      assert is_map(stats)
      assert stats.trials_completed >= 1
    end)
  end

  test "pause -> resume preserves population growth across the boundary" do
    stub_lms()
    program = Dsxir.Program.new(SessionProbe)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: Dsxir.Optimizer.GEPA,
          program: program,
          trainset: trainset(),
          metric: metric(),
          opts: [
            auto: :light,
            num_trials: 6,
            reflective_lm: {Dsxir.LM.Sycophant, [model: "stub"]}
          ],
          session_id: "sess_gepa_pause_resume"
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      snapshot1 = OptimizerSession.poll(pid)

      {:ok, listings} = OptimizerSession.list_sessions(:ets)
      assert is_list(listings)
      assert Enum.any?(listings, fn l -> l.session_id == "sess_gepa_pause_resume" end)

      :ok = OptimizerSession.resume(pid)
      {:ok, result} = OptimizerSession.await(pid, 10_000)
      assert is_map(result)
      final = OptimizerSession.poll(pid)
      assert final.trials_completed >= snapshot1.trials_completed
    end)
  end

  test "resume with different trainset hash returns ResumeMismatch" do
    stub_lms()
    program = Dsxir.Program.new(SessionProbe)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: Dsxir.Optimizer.GEPA,
          program: program,
          trainset: trainset(),
          metric: metric(),
          opts: [
            auto: :light,
            num_trials: 4,
            reflective_lm: {Dsxir.LM.Sycophant, [model: "stub"]}
          ],
          session_id: "sess_gepa_hash_mismatch"
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5_000)
      Process.unlink(pid)
      Process.exit(pid, :brutal_kill)
      wait_for_pid_down(pid, 2_000)

      Process.flag(:trap_exit, true)

      different_trainset =
        trainset() ++
          [
            %Dsxir.Example{
              data: %{text: "extra", summary: "x"},
              input_keys: MapSet.new([:text])
            }
          ]

      assert {:error, %Dsxir.Errors.Invalid.ResumeMismatch{reason: :trainset_hash}} =
               OptimizerSession.resume_session(:ets, "sess_gepa_hash_mismatch",
                 optimizer: Dsxir.Optimizer.GEPA,
                 program: program,
                 trainset: different_trainset,
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
