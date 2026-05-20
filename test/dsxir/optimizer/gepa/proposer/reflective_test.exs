defmodule Dsxir.Optimizer.GEPA.Proposer.ReflectiveTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Optimizer.GEPA.Proposer.Reflective

  setup :set_mimic_global

  setup do
    Mimic.copy(Dsxir.LM.Sycophant)
    :ok
  end

  defmodule FakeSig do
    use Dsxir.Signature

    signature do
      instruction("Do the thing.")
      input(:a, :string)
      output(:b, :string)
    end
  end

  test "parse strips numbering, label, and quotes" do
    assert Reflective.parse("1. \"hello\"") == "hello"
    assert Reflective.parse("Instruction: do X") == "do X"
    assert Reflective.parse("INSTRUCTION:  \"trim me\"\n") == "trim me"
    assert Reflective.parse("plain text") == "plain text"
  end

  test "rewrite/4 builds prompt with rollouts and signature, returns trimmed text" do
    Mimic.expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, [%{content: prompt}], _opts ->
      assert prompt =~ "Current instruction"
      assert prompt =~ "score=0.90"
      assert prompt =~ "a (input)"
      {:ok, "1. \"improved instruction\"", %{}}
    end)

    rollouts = [%{example_idx: 0, score: 0.9, feedback: "good"}]

    assert {:ok, "improved instruction"} =
             Reflective.rewrite("do X", rollouts, FakeSig, {Dsxir.LM.Sycophant, []})
  end

  test "rewrite/4 propagates LM error" do
    err = %Dsxir.Errors.LM.RateLimited{model_id: "test", retry_after: nil}
    Mimic.stub(Dsxir.LM.Sycophant, :generate_text, fn _, _, _ -> {:error, err} end)

    assert {:error, ^err} =
             Reflective.rewrite("do X", [], FakeSig, {Dsxir.LM.Sycophant, []})
  end

  test "merge/5 builds two-parent prompt" do
    Mimic.expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, [%{content: prompt}], _ ->
      assert prompt =~ "Parent A"
      assert prompt =~ "Parent B"
      assert prompt =~ "instr A text"
      assert prompt =~ "instr B text"
      {:ok, "hybrid", %{}}
    end)

    assert {:ok, "hybrid"} =
             Reflective.merge(
               "instr A text",
               "instr B text",
               [],
               FakeSig,
               {Dsxir.LM.Sycophant, []}
             )
  end
end
