defmodule Dsxir.Optimizer.MIPROv2.Proposer.ProgramSummarizerTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.MIPROv2.Proposer.ProgramSummarizer
  alias Dsxir.Program.Source
  alias Dsxir.Test.Fixtures.AnswerProgram
  alias Dsxir.Test.Fixtures.FailingProposerLM
  alias Dsxir.Test.Fixtures.RuntimePrograms
  alias Dsxir.Test.Fixtures.StubProposerLM

  defp answer_program_decls do
    Source.predictors(Dsxir.Program.Source.Module.new!(AnswerProgram))
  end

  describe "run/2" do
    test "returns the LM text wrapped in :ok" do
      assert {:ok, "ok-summary"} =
               ProgramSummarizer.run(
                 answer_program_decls(),
                 {StubProposerLM, reply: "ok-summary"}
               )
    end

    test "handles the empty reply" do
      assert {:ok, ""} =
               ProgramSummarizer.run(answer_program_decls(), {StubProposerLM, reply: ""})
    end

    test "propagates LM errors" do
      assert {:error, %RuntimeError{message: "proposer down"}} =
               ProgramSummarizer.run(answer_program_decls(), {FailingProposerLM, []})
    end

    test "accepts predictor decls from a runtime-program source" do
      rp = RuntimePrograms.linear_chain()
      decls = Source.predictors(%Dsxir.Program.Source.RuntimeProgram{runtime_program: rp})

      assert {:ok, "rt-summary"} =
               ProgramSummarizer.run(decls, {StubProposerLM, reply: "rt-summary"})
    end
  end
end
