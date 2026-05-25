defmodule Dsxir.Optimizer.COPRO.ProposerTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.COPRO.Proposer
  alias Dsxir.Test.Fixtures.AnswerQuestion

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defp decl, do: %{name: :answer, signature: AnswerQuestion}

  describe "propose/1 dispatch" do
    test "routes :basic to the Basic proposer" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
        {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
      end)

      ctx = %{
        kind: :basic,
        decl: decl(),
        current_instruction: "X",
        n: 2,
        temperature: 1.0,
        lm: {Dsxir.LM.Sycophant, []}
      }

      assert {:ok, instrs} = Proposer.propose(ctx)
      assert length(instrs) == 2
      assert "X" in instrs
    end

    test "routes :given_attempts to the GivenAttempts proposer" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ ->
        {:ok, "1. Be precise.", Dsxir.LM.empty_usage()}
      end)

      ctx = %{
        kind: :given_attempts,
        decl: decl(),
        attempts: [%{instruction: "Prior.", score: 0.4}],
        n: 2,
        temperature: 1.0,
        lm: {Dsxir.LM.Sycophant, []}
      }

      assert {:ok, instrs} = Proposer.propose(ctx)
      assert length(instrs) == 2
      assert "Prior." in instrs
    end
  end

  describe "parse/1" do
    test "strips numeric prefixes with periods and parens" do
      assert Proposer.parse("1. Be precise.\n2) Cite sources.") == [
               "Be precise.",
               "Cite sources."
             ]
    end

    test "strips leading Instruction and Prefix labels" do
      assert Proposer.parse("Instruction: Be precise.\nPrefix: Cite sources.") == [
               "Be precise.",
               "Cite sources."
             ]
    end

    test "strips surrounding quotes" do
      assert Proposer.parse(~s("Be precise.")) == ["Be precise."]
    end

    test "drops blank lines" do
      assert Proposer.parse("1. Be precise.\n\n2. Cite sources.\n   \n") == [
               "Be precise.",
               "Cite sources."
             ]
    end
  end

  describe "pad/3" do
    test "truncates to n" do
      assert Proposer.pad(["a", "b", "c"], 2, "x") == ["a", "b"]
    end

    test "repeats fallback to reach n" do
      assert Proposer.pad(["a"], 3, "x") == ["a", "x", "x"]
    end

    test "is a no-op at exact length" do
      assert Proposer.pad(["a", "b"], 2, "x") == ["a", "b"]
    end
  end
end
