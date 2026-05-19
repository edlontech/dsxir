defmodule Dsxir.Optimizer.MIPROv2.Proposer.DatasetSummarizerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Example
  alias Dsxir.Optimizer.MIPROv2.Proposer.DatasetSummarizer
  alias Dsxir.Test.Fixtures.FailingProposerLM
  alias Dsxir.Test.Fixtures.StubProposerLM

  defp trainset do
    for i <- 1..10 do
      Example.new(%{question: "q#{i}", answer: "a#{i}"}, input_keys: [:question])
    end
  end

  describe "run/3" do
    test "returns LM text wrapped in :ok" do
      assert {:ok, "task-summary"} =
               DatasetSummarizer.run(
                 trainset(),
                 {StubProposerLM, reply: "task-summary"},
                 sample_size: 3
               )
    end

    test "uses default sample size when none given" do
      assert {:ok, "default"} =
               DatasetSummarizer.run(trainset(), {StubProposerLM, reply: "default"})
    end

    test "propagates LM errors" do
      assert {:error, %RuntimeError{message: "proposer down"}} =
               DatasetSummarizer.run(trainset(), {FailingProposerLM, []})
    end
  end
end
