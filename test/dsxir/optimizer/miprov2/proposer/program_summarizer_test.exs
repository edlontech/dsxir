defmodule Dsxir.Optimizer.MIPROv2.Proposer.ProgramSummarizerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.MIPROv2.Proposer.ProgramSummarizer
  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.Fixtures.FailingProposerLM
  alias Dsxir.Test.Fixtures.StubProposerLM

  describe "run/2" do
    test "returns the LM text wrapped in :ok" do
      assert {:ok, "ok-summary"} =
               ProgramSummarizer.run(AnswerProgram, {StubProposerLM, reply: "ok-summary"})
    end

    test "handles the empty reply" do
      assert {:ok, ""} =
               ProgramSummarizer.run(AnswerProgram, {StubProposerLM, reply: ""})
    end

    test "propagates LM errors" do
      assert {:error, %RuntimeError{message: "proposer down"}} =
               ProgramSummarizer.run(AnswerProgram, {FailingProposerLM, []})
    end
  end
end
