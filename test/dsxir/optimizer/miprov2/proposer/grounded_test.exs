defmodule Dsxir.Optimizer.MIPROv2.Proposer.GroundedTest do
  use ExUnit.Case, async: true

  alias Dsxir.Optimizer.MIPROv2.Proposer.Grounded
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.FailingProposerLM
  alias Dsxir.Test.Fixtures.StubProposerLM

  setup do
    {:ok, decl: %{name: :answer, signature: AnswerQuestion}}
  end

  test "returns the requested number of instructions", %{decl: decl} do
    reply = "1. Be concise.\n2. Be thorough.\n3. Be playful."

    assert {:ok, instructions} =
             Grounded.run(%{
               program_summary: "p",
               dataset_summary: "d",
               predictor_decl: decl,
               tip: :concise,
               n_candidates: 3,
               lm: {StubProposerLM, reply: reply}
             })

    assert length(instructions) == 3
    assert "Be concise." in instructions
    assert "Be thorough." in instructions
    assert "Be playful." in instructions
  end

  test "pads with empty strings when LM returns fewer lines than requested", %{decl: decl} do
    assert {:ok, instructions} =
             Grounded.run(%{
               program_summary: "p",
               dataset_summary: "d",
               predictor_decl: decl,
               tip: nil,
               n_candidates: 4,
               lm: {StubProposerLM, reply: "1. only one"}
             })

    assert length(instructions) == 4
    assert Enum.count(instructions, &(&1 == "")) == 3
    assert "only one" in instructions
  end

  test "truncates when LM returns more lines than requested", %{decl: decl} do
    reply = "1. a\n2. b\n3. c\n4. d\n5. e"

    assert {:ok, instructions} =
             Grounded.run(%{
               program_summary: "p",
               dataset_summary: "d",
               predictor_decl: decl,
               tip: nil,
               n_candidates: 2,
               lm: {StubProposerLM, reply: reply}
             })

    assert instructions == ["a", "b"]
  end

  test "propagates LM errors", %{decl: decl} do
    assert {:error, %RuntimeError{}} =
             Grounded.run(%{
               program_summary: "p",
               dataset_summary: "d",
               predictor_decl: decl,
               tip: nil,
               n_candidates: 2,
               lm: {FailingProposerLM, []}
             })
  end
end
