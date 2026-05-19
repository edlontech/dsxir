defmodule Dsxir.Optimizer.MIPROv2Test do
  use ExUnit.Case, async: false

  alias Dsxir.Errors
  alias Dsxir.Example
  alias Dsxir.Optimizer.MIPROv2
  alias Dsxir.Optimizer.MIPROv2.Stats
  alias Dsxir.Optimizer.Search.Random
  alias Dsxir.Optimizer.Search.TPE
  alias Dsxir.Program
  alias Dsxir.Test.Fixtures.RewardLM
  alias Dsxir.Test.Fixtures.RewardProgram
  alias Dsxir.Test.TelemetryHandler

  @target_instruction "WINNER-INSTRUCTION-1"

  defp ex(q, a), do: Example.new(%{question: q, answer: a}, input_keys: [:question])

  defp seed_trainset(_seed) do
    Enum.map(1..12, fn i -> ex("q-#{i}", "a-#{i}") end)
  end

  defp instruction_reward_metric(_ex, %Dsxir.Prediction{fields: %{answer: a}}, _t)
       when is_binary(a) do
    if String.contains?(a, "inst=#{@target_instruction}"), do: 1.0, else: 0.0
  end

  defp demo_reward_metric(_ex, %Dsxir.Prediction{fields: %{answer: a}}, _t)
       when is_binary(a) do
    if String.contains?(a, "demos=0"), do: 0.0, else: 1.0
  end

  defp joint_reward_metric(ex, %Dsxir.Prediction{fields: %{answer: a}} = pred, t)
       when is_binary(a) do
    instr_score = instruction_reward_metric(ex, pred, t)
    demo_score = demo_reward_metric(ex, pred, t)
    instr_score * 0.5 + demo_score * 0.5
  end

  defp scripted_proposer_lm(reply) do
    {Dsxir.Test.Fixtures.StubProposerLM, [model: "stub", reply: reply]}
  end

  defp instruction_proposer_lm do
    reply = """
    1. #{@target_instruction}
    2. distractor-A
    3. distractor-B
    """

    scripted_proposer_lm(reply)
  end

  describe "input validation" do
    test "empty trainset returns {:error, Invalid.Trainset{reason: :empty}}" do
      assert {:error, %Errors.Invalid.Trainset{reason: :empty, example: nil}} =
               MIPROv2.compile(Program.new(RewardProgram), [], &instruction_reward_metric/3, [])
    end
  end

  describe "instruction-only optimization" do
    test "Random sampler picks the rewarded instruction across multiple seeds" do
      for seed <- [42, 43, 44] do
        proposer = instruction_proposer_lm()

        Dsxir.context([lm: proposer], fn ->
          {:ok, compiled, stats} =
            MIPROv2.compile(
              Program.new(RewardProgram),
              seed_trainset(seed),
              &instruction_reward_metric/3,
              auto: :light,
              proposer_lm: proposer,
              sampler: Random,
              num_trials: 30,
              num_instruction_candidates: 3,
              num_demo_sets: 2,
              minibatch_size: 4,
              minibatch_full_eval_steps: 10,
              top_k_full_eval: 2,
              batch_size: 4,
              seed: seed
            )

          state = Program.get_state(compiled, :answer)

          assert state.instructions_override == @target_instruction,
                 "seed=#{seed} picked #{inspect(state.instructions_override)}, expected target"

          assert stats.best_score >= 0.99
        end)
      end
    end

    test "TPE sampler also converges to the rewarded instruction" do
      for seed <- [42, 43, 44] do
        proposer = instruction_proposer_lm()

        Dsxir.context([lm: proposer], fn ->
          {:ok, compiled, _stats} =
            MIPROv2.compile(
              Program.new(RewardProgram),
              seed_trainset(seed),
              &instruction_reward_metric/3,
              proposer_lm: proposer,
              sampler: TPE,
              sampler_opts: [cold_start_trials: 6, seed: seed],
              num_trials: 30,
              num_instruction_candidates: 3,
              num_demo_sets: 2,
              minibatch_size: 4,
              minibatch_full_eval_steps: 10,
              top_k_full_eval: 2,
              batch_size: 4,
              seed: seed
            )

          state = Program.get_state(compiled, :answer)
          assert state.instructions_override == @target_instruction
        end)
      end
    end
  end

  describe "demo-only optimization" do
    test "picks a non-empty demo bundle when reward depends on demos" do
      for seed <- [42, 43, 44] do
        proposer = scripted_proposer_lm("1. only-instruction")

        Dsxir.context([lm: proposer], fn ->
          {:ok, compiled, _stats} =
            MIPROv2.compile(
              Program.new(RewardProgram),
              seed_trainset(seed),
              &demo_reward_metric/3,
              proposer_lm: proposer,
              sampler: Random,
              num_trials: 24,
              num_instruction_candidates: 1,
              num_demo_sets: 4,
              minibatch_size: 4,
              minibatch_full_eval_steps: 8,
              top_k_full_eval: 2,
              batch_size: 4,
              seed: seed
            )

          state = Program.get_state(compiled, :answer)

          assert state.demos != [],
                 "seed=#{seed} expected demo bundle to be non-empty"
        end)
      end
    end
  end

  describe "joint optimization" do
    test "selects target instruction and non-empty demos when both axes scored" do
      proposer = instruction_proposer_lm()

      Dsxir.context([lm: proposer], fn ->
        {:ok, compiled, stats} =
          MIPROv2.compile(
            Program.new(RewardProgram),
            seed_trainset(42),
            &joint_reward_metric/3,
            proposer_lm: proposer,
            sampler: Random,
            num_trials: 40,
            num_instruction_candidates: 3,
            num_demo_sets: 4,
            minibatch_size: 4,
            minibatch_full_eval_steps: 10,
            top_k_full_eval: 3,
            batch_size: 4,
            seed: 42
          )

        state = Program.get_state(compiled, :answer)

        assert state.instructions_override == @target_instruction
        assert state.demos != []
        assert stats.best_score >= 0.99
      end)
    end
  end

  describe "full-eval rerank" do
    test "best winner comes from full_evals when minibatch disagrees" do
      proposer = instruction_proposer_lm()

      Dsxir.context([lm: proposer], fn ->
        {:ok, _compiled, stats} =
          MIPROv2.compile(
            Program.new(RewardProgram),
            seed_trainset(42),
            &instruction_reward_metric/3,
            proposer_lm: proposer,
            sampler: Random,
            num_trials: 20,
            num_instruction_candidates: 3,
            num_demo_sets: 2,
            minibatch_size: 2,
            minibatch_full_eval_steps: 5,
            top_k_full_eval: 3,
            batch_size: 4,
            seed: 42
          )

        refute stats.full_evals == [], "expected at least one full-eval pass"

        full_best = Enum.max_by(stats.full_evals, & &1.score).score
        assert stats.best_score == full_best
      end)
    end
  end

  describe "cache hits" do
    test "total_cached_calls > 0 after a run with stable configs" do
      proposer = scripted_proposer_lm("1. dup-instruction")

      Dsxir.context([lm: proposer], fn ->
        {:ok, _compiled, stats} =
          MIPROv2.compile(
            Program.new(RewardProgram),
            seed_trainset(42),
            &instruction_reward_metric/3,
            proposer_lm: proposer,
            sampler: Random,
            num_trials: 30,
            num_instruction_candidates: 1,
            num_demo_sets: 1,
            minibatch_size: 4,
            minibatch_full_eval_steps: 5,
            top_k_full_eval: 2,
            batch_size: 4,
            seed: 42
          )

        assert stats.total_cached_calls > 0
      end)
    end
  end

  describe "tenant isolation" do
    test "two concurrent compiles inside different Settings.context blocks never share cache" do
      table = :ets.new(:miprov2_tenant_recorder, [:public, :duplicate_bag])
      parent_snapshot = Dsxir.Settings.snapshot()

      run_tenant = fn tenant_id, api_key ->
        Dsxir.Settings.run(parent_snapshot, fn ->
          Dsxir.context(
            [
              lm: {RewardLM, [model: "stub", api_key: api_key, recorder_table: table]},
              metadata: %{tenant_id: tenant_id},
              cache: false
            ],
            fn ->
              MIPROv2.compile(
                Program.new(RewardProgram),
                seed_trainset(42),
                &instruction_reward_metric/3,
                proposer_lm: scripted_proposer_lm("1. only"),
                sampler: Random,
                num_trials: 8,
                num_instruction_candidates: 1,
                num_demo_sets: 1,
                minibatch_size: 3,
                minibatch_full_eval_steps: 100,
                top_k_full_eval: 1,
                batch_size: 2,
                seed: 42
              )
            end
          )
        end)
      end

      t1 = Task.async(fn -> run_tenant.("t1", "key-t1") end)
      t2 = Task.async(fn -> run_tenant.("t2", "key-t2") end)

      {:ok, _, _} = Task.await(t1, 30_000)
      {:ok, _, _} = Task.await(t2, 30_000)

      rows = :ets.tab2list(table)
      by_tenant = Enum.group_by(rows, fn {_, tid, _, _} -> tid end)

      assert Map.has_key?(by_tenant, "t1")
      assert Map.has_key?(by_tenant, "t2")
      refute Enum.any?(by_tenant["t1"], fn {_, _, key, _} -> key == "key-t2" end)
      refute Enum.any?(by_tenant["t2"], fn {_, _, key, _} -> key == "key-t1" end)

      :ets.delete(table)
    end
  end

  describe "settings snapshot propagation" do
    test "worker sees the tenant metadata from the parent's snapshot" do
      table = :ets.new(:miprov2_snapshot_recorder, [:public, :duplicate_bag])

      Dsxir.context(
        [
          lm: {RewardLM, [model: "stub", api_key: "k", recorder_table: table]},
          metadata: %{tenant_id: "alpha"}
        ],
        fn ->
          {:ok, _, _} =
            MIPROv2.compile(
              Program.new(RewardProgram),
              seed_trainset(42),
              &instruction_reward_metric/3,
              proposer_lm: scripted_proposer_lm("1. only"),
              sampler: Random,
              num_trials: 4,
              num_instruction_candidates: 1,
              num_demo_sets: 1,
              minibatch_size: 2,
              minibatch_full_eval_steps: 100,
              top_k_full_eval: 1,
              batch_size: 2,
              seed: 42
            )
        end
      )

      rows = :ets.tab2list(table)
      assert rows != []
      assert Enum.all?(rows, fn {_, tenant, _, _} -> tenant == "alpha" end)

      :ets.delete(table)
    end
  end

  describe "proposer failure" do
    test "failing proposer LM produces degraded run with proposer_calls > 0 but no instructions" do
      failing_proposer = {Dsxir.Test.Fixtures.FailingProposerLM, [model: "down"]}

      task_proposer = scripted_proposer_lm("1. unused")

      Dsxir.context([lm: task_proposer], fn ->
        {:ok, _compiled, stats} =
          MIPROv2.compile(
            Program.new(RewardProgram),
            seed_trainset(42),
            &instruction_reward_metric/3,
            proposer_lm: failing_proposer,
            sampler: Random,
            num_trials: 6,
            num_instruction_candidates: 3,
            num_demo_sets: 1,
            minibatch_size: 3,
            minibatch_full_eval_steps: 100,
            top_k_full_eval: 1,
            batch_size: 2,
            seed: 42
          )

        assert %Stats{degraded: true} = stats
        assert stats.proposer_calls > 0
      end)
    end
  end

  describe "minibatch auto-shrink" do
    test "trainset smaller than minibatch_size still produces a valid compile" do
      tiny_trainset = Enum.map(1..3, fn i -> ex("q-#{i}", "a-#{i}") end)
      proposer = scripted_proposer_lm("1. only")

      Dsxir.context([lm: proposer], fn ->
        {:ok, _compiled, stats} =
          MIPROv2.compile(
            Program.new(RewardProgram),
            tiny_trainset,
            &instruction_reward_metric/3,
            proposer_lm: proposer,
            sampler: Random,
            num_trials: 4,
            num_instruction_candidates: 1,
            num_demo_sets: 1,
            minibatch_size: 50,
            minibatch_full_eval_steps: 100,
            top_k_full_eval: 1,
            batch_size: 2,
            seed: 42
          )

        assert is_list(stats.trials)
        assert stats.trials != []
      end)
    end
  end

  describe "telemetry events" do
    test "emits optimizer_start, optimizer_stop, optimizer_trial, and miprov2_proposer events" do
      parent = self()
      handler_id = "miprov2-telemetry-#{:erlang.unique_integer([:positive])}"

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            Dsxir.Telemetry.optimizer_start(),
            Dsxir.Telemetry.optimizer_stop(),
            Dsxir.Telemetry.optimizer_trial(),
            Dsxir.Telemetry.miprov2_proposer()
          ],
          &TelemetryHandler.forward/4,
          %{parent: parent, tag: :tel}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      proposer = scripted_proposer_lm("1. only")

      Dsxir.context([lm: proposer], fn ->
        {:ok, _compiled, _stats} =
          MIPROv2.compile(
            Program.new(RewardProgram),
            seed_trainset(42),
            &instruction_reward_metric/3,
            proposer_lm: proposer,
            sampler: Random,
            num_trials: 4,
            num_instruction_candidates: 1,
            num_demo_sets: 1,
            minibatch_size: 3,
            minibatch_full_eval_steps: 100,
            top_k_full_eval: 1,
            batch_size: 2,
            seed: 42
          )
      end)

      assert_receive {:tel, [:dsxir, :optimizer, :start], _, _}, 1_000
      assert_receive {:tel, [:dsxir, :optimizer, :stop], _, _}, 1_000
      assert_receive {:tel, [:dsxir, :optimizer, :trial], _, _}, 1_000
      assert_receive {:tel, [:dsxir, :miprov2, :proposer], _, _}, 1_000
    end
  end
end
