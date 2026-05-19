defmodule Dsxir.Optimizer.MIPROv2SessionTest do
  use ExUnit.Case, async: false

  alias Dsxir.Example
  alias Dsxir.Optimizer
  alias Dsxir.Optimizer.MIPROv2
  alias Dsxir.Optimizer.MIPROv2.Sampler
  alias Dsxir.OptimizerSession
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.RewardProgram

  defmodule CountingProposerLM do
    @behaviour Dsxir.LM

    @impl Dsxir.LM
    def generate_text(config, _messages, _opts) do
      table = Keyword.fetch!(config, :counter_table)
      :ets.update_counter(table, :count, {2, 1})
      {:ok, Keyword.get(config, :reply, ""), Dsxir.LM.empty_usage()}
    end

    @impl Dsxir.LM
    def generate_object(_config, _messages, _schema, _opts) do
      {:ok, %{}, Dsxir.LM.empty_usage()}
    end
  end

  setup do
    on_exit(fn ->
      case :ets.whereis(:dsxir_optimizer_sessions) do
        :undefined -> :ok
        _ -> :ets.delete_all_objects(:dsxir_optimizer_sessions)
      end
    end)

    :ok
  end

  defp ex(q, a), do: Example.new(%{question: q, answer: a}, input_keys: [:question])

  defp seed_trainset, do: Enum.map(1..12, fn i -> ex("q-#{i}", "a-#{i}") end)

  defp reward_metric(_ex, %Dsxir.Prediction{fields: %{answer: a}}, _t)
       when is_binary(a) do
    if String.contains?(a, "inst=WINNER-INSTRUCTION-1"), do: 1.0, else: 0.0
  end

  defp scripted_proposer do
    reply = """
    1. WINNER-INSTRUCTION-1
    2. distractor-A
    """

    {Dsxir.Test.Fixtures.StubProposerLM, [model: "stub", reply: reply]}
  end

  defp common_opts(extra \\ []) do
    Keyword.merge(
      [
        proposer_lm: scripted_proposer(),
        sampler: Dsxir.Optimizer.Search.Random,
        num_trials: 4,
        num_instruction_candidates: 2,
        num_demo_sets: 1,
        minibatch_size: 3,
        minibatch_full_eval_steps: 100,
        top_k_full_eval: 1,
        batch_size: 1,
        seed: 42
      ],
      extra
    )
  end

  test "checkpointable?/1 accepts MIPROv2" do
    assert {:ok, MIPROv2} = Optimizer.checkpointable?(MIPROv2)
  end

  test "init_session/4 returns sampler state and planned trial count" do
    Dsxir.context([lm: scripted_proposer()], fn ->
      assert {:ok, %Sampler{} = sampler, planned} =
               MIPROv2.init_session(
                 Program.new(RewardProgram),
                 seed_trainset(),
                 &reward_metric/3,
                 common_opts()
               )

      assert planned == 4
      assert sampler.total_planned_trials == 4
      assert sampler.trial_records == []
      assert sampler.best_so_far == nil
    end)
  end

  test "serialize_state/1 + deserialize_state/2 round-trip" do
    Dsxir.context([lm: scripted_proposer()], fn ->
      {:ok, sampler, _planned} =
        MIPROv2.init_session(
          Program.new(RewardProgram),
          seed_trainset(),
          &reward_metric/3,
          common_opts()
        )

      assert {:ok, blob, 1} = MIPROv2.serialize_state(sampler)
      assert is_binary(blob)
      assert {:ok, restored} = MIPROv2.deserialize_state(blob, 1)
      assert %Sampler{} = restored
      assert restored.total_planned_trials == sampler.total_planned_trials
      assert restored.candidates == sampler.candidates
    end)
  end

  test "deserialize_state/2 rejects unknown version with :version_mismatch" do
    Dsxir.context([lm: scripted_proposer()], fn ->
      {:ok, sampler, _planned} =
        MIPROv2.init_session(
          Program.new(RewardProgram),
          seed_trainset(),
          &reward_metric/3,
          common_opts()
        )

      {:ok, blob, 1} = MIPROv2.serialize_state(sampler)
      assert {:error, :version_mismatch} = MIPROv2.deserialize_state(blob, 2)
    end)
  end

  test "step/6 runs one trial at a time and halts when budget exhausted" do
    Dsxir.context([lm: scripted_proposer()], fn ->
      program = Program.new(RewardProgram)
      trainset = seed_trainset()
      metric = &reward_metric/3
      opts = common_opts(num_trials: 2)

      {:ok, sampler, planned} = MIPROv2.init_session(program, trainset, metric, opts)
      assert planned == 2

      {:cont, sampler, trial0} = MIPROv2.step(sampler, 0, program, trainset, metric, opts)

      assert %{
               trial_idx: 0,
               status: :ok,
               score: score0,
               candidate_id: cand_id,
               duration_ms: dur,
               candidate_program: %Program{}
             } = trial0

      assert is_float(score0)
      assert is_binary(cand_id) or is_nil(cand_id)
      assert is_integer(dur) and dur >= 0
      assert Map.has_key?(trial0, :stats)
      assert Map.has_key?(trial0, :error)
      assert Map.has_key?(trial0, :error_class)
      assert length(sampler.trial_records) == 1

      {:cont, sampler, _trial1} = MIPROv2.step(sampler, 1, program, trainset, metric, opts)
      assert length(sampler.trial_records) == 2

      {:halt, _sampler, :budget_exhausted} =
        MIPROv2.step(sampler, 2, program, trainset, metric, opts)
    end)
  end

  test "OptimizerSession.compile/5 drives MIPROv2 to completion" do
    opts = common_opts(num_trials: 3)

    Dsxir.context([lm: scripted_proposer()], fn ->
      {:ok, %Program{}, stats} =
        OptimizerSession.compile(
          MIPROv2,
          Program.new(RewardProgram),
          seed_trainset(),
          &reward_metric/3,
          opts
        )

      assert stats.trials_completed == 3
      assert stats.errors == 0
      assert stats.best_score != nil
      assert is_list(stats.trial_log)
      assert length(stats.trial_log) == 3
    end)
  end

  test "pause then resume continues the run to completion" do
    table = :"proposer_call_count_#{System.unique_integer([:positive])}"
    :ets.new(table, [:set, :public, :named_table])
    :ets.insert(table, {:count, 0})

    reply = """
    1. WINNER-INSTRUCTION-1
    2. distractor-A
    """

    counting_proposer = {CountingProposerLM, [model: "stub", reply: reply, counter_table: table]}
    opts = Keyword.put(common_opts(num_trials: 5), :proposer_lm, counting_proposer)

    Dsxir.context([lm: scripted_proposer()], fn ->
      {:ok, pid} =
        OptimizerSession.start_link(
          optimizer: MIPROv2,
          program: Program.new(RewardProgram),
          trainset: seed_trainset(),
          metric: &reward_metric/3,
          opts: opts
        )

      :ok = OptimizerSession.pause(pid)
      wait_for_status(pid, :paused, 5000)

      calls_before_resume = :ets.lookup_element(table, :count, 2)

      :ok = OptimizerSession.resume(pid)
      {:ok, result} = OptimizerSession.await(pid, 30_000)

      assert %Program{} = result.best_program
      assert result.stats.trials_completed == 5

      calls_after = :ets.lookup_element(table, :count, 2)

      assert calls_after == calls_before_resume,
             "proposer was re-invoked on resume (#{calls_before_resume} -> #{calls_after})"
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
          Process.sleep(10)
          do_wait_for_status(pid, target, start, deadline_ms)
        end
    end
  end
end
