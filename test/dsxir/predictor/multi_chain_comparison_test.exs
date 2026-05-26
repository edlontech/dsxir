defmodule Dsxir.Predictor.MultiChainComparisonTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.MultiChainComparison, as: MCC
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

  describe "augment/2" do
    test "adds M reasoning_attempt input fields" do
      augmented = MCC.augment(AnswerQuestion, 3)

      assert %Compiled{} = augmented

      input_names = augmented |> Runtime.inputs() |> Enum.map(& &1.name)

      assert input_names == [
               :question,
               :reasoning_attempt_1,
               :reasoning_attempt_2,
               :reasoning_attempt_3
             ]

      attempt = Enum.find(Runtime.inputs(augmented), &(&1.name == :reasoning_attempt_1))
      assert %Field{kind: :input, type: :string} = attempt
      assert %Zoi.Types.String{} = attempt.zoi
    end

    test "prepends a :rationale output ahead of the base outputs" do
      augmented = MCC.augment(AnswerQuestion, 2)

      [first | rest] = Runtime.outputs(augmented)
      assert %Field{name: :rationale, kind: :output, type: :string} = first
      assert Enum.map(rest, & &1.name) == [:answer]
    end

    test "appends the comparison directive to the base instruction" do
      augmented = MCC.augment(AnswerQuestion, 2)
      instruction = Runtime.instruction(augmented)

      assert instruction =~ "Answer the user's question"
      assert instruction =~ "candidate reasoning attempts"
    end

    test "uses the comparison directive alone when base signature has no instruction" do
      augmented = MCC.augment(AnswerQuestionNoInstruction, 2)
      assert Runtime.instruction(augmented) =~ "candidate reasoning attempts"
      refute Runtime.instruction(augmented) =~ "\n\n"
    end

    test "records the wrapped signature in :source" do
      assert MCC.augment(AnswerQuestion, 2).source == {:mcc_of, AnswerQuestion}
    end
  end

  describe "forward/4" do
    test "renders one attempt block per completion and surfaces rationale + answer" do
      {:ok, captured} = Agent.start_link(fn -> nil end)

      markered = """
      [[ ## rationale ## ]]
      Both chains agree on the capital.
      [[ ## answer ## ]]
      Paris
      """

      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, messages, _opts ->
        Agent.update(captured, fn _ -> messages end)
        {:ok, markered, Dsxir.LM.empty_usage()}
      end)

      completions = [
        %Dsxir.Prediction{fields: %{reasoning: "France's capital is Paris", answer: "Paris"}},
        %Dsxir.Prediction{fields: %{reasoning: "It is Paris", answer: "Paris"}}
      ]

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        state = %Dsxir.Program.State{}

        {^state, prediction} =
          MCC.forward(
            state,
            AnswerQuestion,
            %{question: "Capital of France?", completions: completions},
            []
          )

        assert prediction[:rationale] =~ "agree"
        assert prediction[:answer] == "Paris"
      end)

      prompt = captured |> Agent.get(& &1) |> Enum.map_join("\n", & &1.content)
      assert prompt =~ "I'm trying to France's capital is Paris"
      assert prompt =~ "my prediction is Paris"
    end

    test "derives M from the completions list length" do
      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, _messages, _opts ->
        {:ok, "[[ ## rationale ## ]]\nr\n[[ ## answer ## ]]\na\n", Dsxir.LM.empty_usage()}
      end)

      completions = for _ <- 1..3, do: %{reasoning: "r", answer: "a"}

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        augmented = MCC.augment(AnswerQuestion, length(completions))
        assert length(Runtime.inputs(augmented)) == 4

        {_s, _p} =
          MCC.forward(
            %Dsxir.Program.State{},
            AnswerQuestion,
            %{question: "q", completions: completions},
            []
          )
      end)
    end

    test "drops the 'I'm trying to' clause when a completion has no :reasoning" do
      {:ok, captured} = Agent.start_link(fn -> nil end)

      expect(Dsxir.LM.Sycophant, :generate_text, fn _config, messages, _opts ->
        Agent.update(captured, fn _ -> messages end)
        {:ok, "[[ ## rationale ## ]]\nr\n[[ ## answer ## ]]\na\n", Dsxir.LM.empty_usage()}
      end)

      Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fn ->
        MCC.forward(
          %Dsxir.Program.State{},
          AnswerQuestion,
          %{question: "q", completions: [%{answer: "a"}]},
          []
        )
      end)

      prompt = captured |> Agent.get(& &1) |> Enum.map_join("\n", & &1.content)
      assert prompt =~ "my prediction is a"
      refute prompt =~ "I'm trying to"
    end

    test "raises ArgumentError on missing or empty completions" do
      assert_raise ArgumentError, fn ->
        MCC.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "q"}, [])
      end

      assert_raise ArgumentError, fn ->
        MCC.forward(%Dsxir.Program.State{}, AnswerQuestion, %{question: "q", completions: []}, [])
      end
    end
  end
end
