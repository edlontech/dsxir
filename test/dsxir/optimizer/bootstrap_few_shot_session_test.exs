defmodule Dsxir.Optimizer.BootstrapFewShotSessionTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer
  alias Dsxir.Optimizer.BootstrapFewShot
  alias Dsxir.Optimizer.BootstrapFewShot.Sampler
  alias Dsxir.OptimizerSession
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.QA

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)

    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defp scripted_lm(answer_for_idx) do
    counter = :counters.new(1, [:atomics])

    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
      :counters.add(counter, 1, 1)
      idx = :counters.get(counter, 1)
      answer = answer_for_idx.(idx)
      {:ok, "[[ ## a ## ]]\n#{answer}", Dsxir.LM.empty_usage()}
    end)
  end

  defp threshold_metric(_e, %Dsxir.Prediction{fields: %{a: a}}, _t) when is_binary(a) do
    if String.starts_with?(a, "good-"), do: 1.0, else: 0.0
  end

  defp common_opts(extra \\ []) do
    Keyword.merge(
      [
        max_labeled_demos: 0,
        max_bootstrapped_demos: 3,
        max_rounds: 1,
        threshold: 1.0,
        deterministic: true
      ],
      extra
    )
  end

  test "checkpointable?/1 accepts BootstrapFewShot" do
    assert {:ok, BootstrapFewShot} = Optimizer.checkpointable?(BootstrapFewShot)
  end

  test "init_session/4 returns sampler state and planned trial count" do
    scripted_lm(fn _ -> "good-x" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      trainset = QA.trainset_10()

      assert {:ok, %Sampler{} = sampler, planned} =
               BootstrapFewShot.init_session(
                 Program.new(QA.Prog),
                 trainset,
                 &threshold_metric/3,
                 common_opts(max_rounds: 2)
               )

      assert planned == 2 * length(trainset)
      assert sampler.round == 1
      assert sampler.max_rounds == 2
      assert length(sampler.examples_remaining_in_round) == length(trainset)
      assert sampler.error_count == 0
    end)
  end

  test "init_session/4 rejects empty trainset" do
    assert {:error, %Dsxir.Errors.Invalid.Trainset{reason: :empty}} =
             BootstrapFewShot.init_session(Program.new(QA.Prog), [], &threshold_metric/3, [])
  end

  test "init_session/4 over a runtime-program source enumerates predictors via Source.predictors/1" do
    rp = Dsxir.Test.Fixtures.RuntimePrograms.equivalent_to_qa()
    prog = Program.from_runtime(rp)

    trainset =
      Enum.map(1..3, fn i ->
        Dsxir.Example.new(%{q: "q#{i}", a: "a#{i}"}, input_keys: [:q])
      end)

    assert {:ok, %Sampler{} = sampler, _planned} =
             BootstrapFewShot.init_session(prog, trainset, &threshold_metric/3, common_opts())

    assert sampler.predictor_decls != nil

    assert Enum.any?(sampler.predictor_decls, fn d ->
             match?(%Dsxir.Program.PredictorDecl{name: :answer}, d)
           end)
  end

  test "serialize_state/1 + deserialize_state/2 round-trip" do
    scripted_lm(fn _ -> "good-x" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, sampler, _planned} =
        BootstrapFewShot.init_session(
          Program.new(QA.Prog),
          QA.trainset_10(),
          &threshold_metric/3,
          common_opts()
        )

      assert {:ok, blob, 1} = BootstrapFewShot.serialize_state(sampler)
      assert is_binary(blob)

      assert {:ok, restored} = BootstrapFewShot.deserialize_state(blob, 1)
      assert %Sampler{} = restored
      assert restored.round == sampler.round
      assert restored.max_rounds == sampler.max_rounds

      assert length(restored.examples_remaining_in_round) ==
               length(sampler.examples_remaining_in_round)
    end)
  end

  test "deserialize_state/2 rejects unknown version with :version_mismatch" do
    scripted_lm(fn _ -> "good-x" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      {:ok, sampler, _planned} =
        BootstrapFewShot.init_session(
          Program.new(QA.Prog),
          QA.trainset_10(),
          &threshold_metric/3,
          common_opts()
        )

      {:ok, blob, 1} = BootstrapFewShot.serialize_state(sampler)
      assert {:error, :version_mismatch} = BootstrapFewShot.deserialize_state(blob, 2)
    end)
  end

  test "step/6 walks one example at a time and halts at rounds_exhausted" do
    scripted_lm(fn _ -> "good-stub" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      program = Program.new(QA.Prog)
      trainset = Enum.take(QA.trainset_10(), 3)
      metric = &threshold_metric/3
      opts = common_opts(max_bootstrapped_demos: 5)

      {:ok, sampler, planned} = BootstrapFewShot.init_session(program, trainset, metric, opts)
      assert planned == 3

      {:cont, sampler, trial0} =
        BootstrapFewShot.step(sampler, 0, program, trainset, metric, opts)

      assert %{
               trial_idx: 0,
               status: :ok,
               score: score0,
               candidate_id: cand_id,
               duration_ms: dur,
               candidate_program: %Program{}
             } = trial0

      assert is_float(score0)
      assert is_binary(cand_id)
      assert is_integer(dur) and dur >= 0
      assert Map.has_key?(trial0, :stats)
      assert Map.has_key?(trial0, :error)
      assert Map.has_key?(trial0, :error_class)
      assert length(sampler.examples_remaining_in_round) == 2

      {:cont, sampler, _trial1} =
        BootstrapFewShot.step(sampler, 1, program, trainset, metric, opts)

      assert length(sampler.examples_remaining_in_round) == 1

      {:cont, sampler, _trial2} =
        BootstrapFewShot.step(sampler, 2, program, trainset, metric, opts)

      assert sampler.examples_remaining_in_round == []

      assert {:halt, _sampler, :rounds_exhausted} =
               BootstrapFewShot.step(sampler, 3, program, trainset, metric, opts)
    end)
  end

  test "step/6 advances rounds when current round is exhausted" do
    scripted_lm(fn _ -> "good-stub" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      program = Program.new(QA.Prog)
      trainset = Enum.take(QA.trainset_10(), 2)
      metric = &threshold_metric/3
      opts = common_opts(max_rounds: 2, max_bootstrapped_demos: 10)

      {:ok, sampler, planned} = BootstrapFewShot.init_session(program, trainset, metric, opts)
      assert planned == 4

      {:cont, sampler, _} = BootstrapFewShot.step(sampler, 0, program, trainset, metric, opts)
      {:cont, sampler, _} = BootstrapFewShot.step(sampler, 1, program, trainset, metric, opts)
      assert sampler.examples_remaining_in_round == []
      assert sampler.round == 1

      {:cont, sampler, trial2} =
        BootstrapFewShot.step(sampler, 2, program, trainset, metric, opts)

      assert sampler.round == 2
      assert length(sampler.examples_remaining_in_round) == 1
      assert trial2.stats.round == 2

      {:cont, sampler, _} = BootstrapFewShot.step(sampler, 3, program, trainset, metric, opts)
      assert sampler.examples_remaining_in_round == []

      assert {:halt, _sampler, :rounds_exhausted} =
               BootstrapFewShot.step(sampler, 4, program, trainset, metric, opts)
    end)
  end

  test "OptimizerSession.compile/5 drives BootstrapFewShot to completion" do
    scripted_lm(fn _ -> "good-stub" end)

    Dsxir.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      opts = common_opts(max_rounds: 1, max_bootstrapped_demos: 2)

      {:ok, %Program{} = best, stats} =
        OptimizerSession.compile(
          BootstrapFewShot,
          Program.new(QA.Prog),
          Enum.take(QA.trainset_10(), 3),
          &threshold_metric/3,
          opts
        )

      assert stats.trials_completed == 3
      assert stats.errors == 0
      assert stats.best_score != nil
      assert is_list(stats.trial_log)
      assert length(stats.trial_log) == 3

      demos = Program.get_state(best, :answer).demos
      assert Enum.all?(demos, &match?(%Dsxir.Demo{}, &1))
    end)
  end
end
