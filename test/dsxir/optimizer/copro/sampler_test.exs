defmodule Dsxir.Optimizer.COPRO.SamplerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.COPRO.Sampler
  alias Dsxir.Program.PredictorDecl

  defp decl(name), do: %PredictorDecl{name: name, impl: nil, signature: nil}

  defp item(predictor, instruction, source \\ :basic),
    do: %{predictor: predictor, instruction: instruction, source: source}

  defp sampler(opts \\ []) do
    decls = Keyword.get(opts, :decls, [decl(:a)])

    Sampler.new(
      seed_program: %Dsxir.Program{source: nil, predictors: %{}, metadata: %{}},
      decls: decls,
      evalset: Keyword.get(opts, :evalset, [%{}, %{}]),
      total_planned_trials: Keyword.get(opts, :total_planned_trials, 4),
      best_overrides: Keyword.get(opts, :best_overrides, %{})
    )
  end

  describe "new/1" do
    test "seeds round_best and history per predictor and zeroes counters" do
      s = sampler(decls: [decl(:a), decl(:b)], best_overrides: %{a: "ovr"})

      assert s.round == 0
      assert s.attempts == 0
      assert s.total_devset_evals == 0
      assert s.queue == []
      assert s.best_score == nil
      assert Enum.sort(Map.keys(s.round_best)) == [:a, :b]
      assert s.round_best[:a] == %{instruction: "ovr", score: nil}
      assert s.round_best[:b] == %{instruction: nil, score: nil}
      assert s.history == %{a: [], b: []}
    end
  end

  describe "dequeue/1" do
    test "returns :empty on an empty queue" do
      assert Sampler.dequeue(sampler()) == :empty
    end

    test "pops the head and removes it from the queue" do
      s = Sampler.enqueue_round(sampler(), [item(:a, "i1"), item(:a, "i2")])
      assert {%{instruction: "i1"}, s1} = Sampler.dequeue(s)
      assert {%{instruction: "i2"}, s2} = Sampler.dequeue(s1)
      assert Sampler.dequeue(s2) == :empty
    end
  end

  describe "enqueue_round/2 and attempts_left?/1" do
    test "enqueue_round replaces the queue and bumps the round" do
      s = sampler()
      s1 = Sampler.enqueue_round(s, [item(:a, "x")])
      assert s1.round == 1
      assert s1.queue == [item(:a, "x")]

      s2 = Sampler.enqueue_round(s1, [item(:a, "y")])
      assert s2.round == 2
      assert s2.queue == [item(:a, "y")]
    end

    test "attempts_left? is true below the budget and false at or above it" do
      s = sampler(total_planned_trials: 2)
      assert Sampler.attempts_left?(s)

      s1 = Sampler.record_trial(s, item(:a, "i1"), 0.1)
      assert Sampler.attempts_left?(s1)

      s2 = Sampler.record_trial(s1, item(:a, "i2"), 0.2)
      refute Sampler.attempts_left?(s2)
    end
  end

  describe "record_trial/3" do
    test "admits a strictly better candidate" do
      s = sampler()
      s1 = Sampler.record_trial(s, item(:a, "first"), 0.4)
      assert s1.round_best[:a] == %{instruction: "first", score: 0.4}

      s2 = Sampler.record_trial(s1, item(:a, "second"), 0.6)
      assert s2.round_best[:a] == %{instruction: "second", score: 0.6}
    end

    test "keeps prior best on a tie (strict >)" do
      s = sampler()
      s1 = Sampler.record_trial(s, item(:a, "first"), 0.5)
      s2 = Sampler.record_trial(s1, item(:a, "tie"), 0.5)
      assert s2.round_best[:a] == %{instruction: "first", score: 0.5}
    end

    test "keeps prior best when score is nil" do
      s = sampler()
      s1 = Sampler.record_trial(s, item(:a, "first"), 0.5)
      s2 = Sampler.record_trial(s1, item(:a, "failed"), nil)
      assert s2.round_best[:a] == %{instruction: "first", score: 0.5}
    end

    test "prepends history and bumps counters by eval-set size" do
      s = sampler(evalset: [%{}, %{}, %{}])
      s1 = Sampler.record_trial(s, item(:a, "first"), 0.4)
      s2 = Sampler.record_trial(s1, item(:a, "second"), 0.6)

      assert s2.history[:a] == [
               %{instruction: "second", score: 0.6, round: 0},
               %{instruction: "first", score: 0.4, round: 0}
             ]

      assert s2.attempts == 2
      assert s2.total_devset_evals == 6
    end
  end

  describe "commit_round/1" do
    test "promotes round winners and counts improvements" do
      s = sampler(decls: [decl(:a), decl(:b)])

      s =
        s
        |> Sampler.record_trial(item(:a, "a-win"), 0.7)
        |> Sampler.record_trial(item(:b, "b-win"), 0.9)

      {committed, improved} = Sampler.commit_round(s)

      assert improved == 2
      assert committed.best_overrides == %{a: "a-win", b: "b-win"}
      assert committed.best_score == 0.9
      assert committed.round_best[:a] == %{instruction: "a-win", score: 0.9}
      assert committed.round_best[:b] == %{instruction: "b-win", score: 0.9}
    end

    test "does not promote a predictor whose winner equals its current override" do
      s = sampler(decls: [decl(:a), decl(:b)], best_overrides: %{a: "keep"})

      s =
        s
        |> Sampler.record_trial(item(:a, "keep"), 0.8)
        |> Sampler.record_trial(item(:b, "new"), 0.5)

      {committed, improved} = Sampler.commit_round(s)

      assert improved == 1
      assert committed.best_overrides == %{a: "keep", b: "new"}
      assert committed.best_score == 0.8
    end

    test "keeps prior best_score when every round winner score is nil" do
      s = %{sampler() | best_score: 0.42}
      s = Sampler.record_trial(s, item(:a, "failed"), nil)

      {committed, improved} = Sampler.commit_round(s)

      assert improved == 0
      assert committed.best_overrides == %{}
      assert committed.best_score == 0.42
    end
  end

  describe "serialize_state/1 and deserialize_state/2" do
    test "serialize/deserialize round-trips the sampler" do
      s = Sampler.record_trial(sampler(), item(:a, "i1"), 0.5)
      blob_version = Sampler.serialize_state(s)

      assert {:ok, blob, 1} = blob_version
      assert {:ok, ^s} = Sampler.deserialize_state(blob, 1)
      assert {:error, :version_mismatch} = Sampler.deserialize_state(blob, 2)
    end

    test "bad_sampler_shape for a non-Sampler blob" do
      blob = :erlang.term_to_binary({:not, :a, :sampler})
      assert {:error, {:bad_sampler_shape, _}} = Sampler.deserialize_state(blob, 1)
    end

    test "corrupt_blob for non-term bytes" do
      assert {:error, :corrupt_blob} = Sampler.deserialize_state(<<0, 1, 2, 3>>, 1)
    end
  end
end
