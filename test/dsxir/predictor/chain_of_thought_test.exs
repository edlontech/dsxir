defmodule Dsxir.Predictor.ChainOfThoughtTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.ChainOfThought
  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime
  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.AnswerQuestionNoInstruction

  setup :set_mimic_from_context

  setup do
    prior = Dsxir.Settings.snapshot()
    on_exit(fn -> :persistent_term.put({Dsxir.Settings, :globals}, prior.globals) end)
    :ok
  end

  test "forward/4 surfaces reasoning and answer fields from a stubbed LM" do
    markered = """
    [[ ## reasoning ## ]]
    Elixir runs on the BEAM and is functional.
    [[ ## answer ## ]]
    A dynamic, functional language.
    """

    expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _msgs, _opts ->
      {:ok, markered, Dsxir.LM.empty_usage()}
    end)

    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
      state = %Dsxir.Program.State{}

      {^state, prediction} =
        ChainOfThought.forward(state, AnswerQuestion, %{question: "What is Elixir?"}, [])

      assert %Dsxir.Prediction{} = prediction
      assert prediction[:reasoning] =~ "BEAM"
      assert prediction[:answer] =~ "dynamic"
    end)
  end

  test "augment/1 prepends :reasoning output field to signature outputs" do
    augmented = ChainOfThought.augment(AnswerQuestion)

    assert %Compiled{} = augmented

    [first | _] = Runtime.outputs(augmented)
    assert %Field{name: :reasoning, kind: :output, type: :string} = first
    assert %Zoi.Types.String{} = first.zoi
  end

  test "augment/1 sets default instruction when base signature has none" do
    augmented = ChainOfThought.augment(AnswerQuestionNoInstruction)

    assert Runtime.instruction(augmented) == "Reason step by step before answering."
  end

  test "augment/1 appends reasoning instruction to existing instruction" do
    augmented = ChainOfThought.augment(AnswerQuestion)

    instruction = Runtime.instruction(augmented)

    assert instruction =~ "Answer the user's question"
    assert instruction =~ "Reason step by step before answering."
    assert String.contains?(instruction, "\n\nReason step by step before answering.")
  end

  test "augment/1 records the wrapped signature in :source" do
    augmented = ChainOfThought.augment(AnswerQuestion)
    assert augmented.source == {:cot_of, AnswerQuestion}
  end
end
