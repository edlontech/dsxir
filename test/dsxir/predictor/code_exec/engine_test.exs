defmodule Dsxir.Predictor.CodeExec.EngineTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.CodeExec.Engine
  alias Dsxir.Program.State, as: PState

  defmodule QA do
    use Dsxir.Signature

    signature do
      instruction("Answer with a number.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  setup :set_mimic_from_context

  defp marker(fields) do
    Enum.map_join(fields, "\n", fn {name, value} -> "[[ ## #{name} ## ]]\n#{value}" end)
  end

  defp canned(fields) do
    {:ok, marker(fields), Dsxir.LM.empty_usage()}
  end

  defp with_lm(fun) do
    Dsxir.Settings.context([lm: {Dsxir.LM.Sycophant, [model: "stub"]}], fun)
  end

  test "succeeds on first attempt, then extracts the typed output" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "compute it", generated_code: "1 + 1")
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "the result is two", answer: "2")
    end)

    with_lm(fn ->
      {%PState{}, pred} =
        Engine.run(%PState{}, QA, %{question: "1+1?"},
          max_iters: 3,
          exec_type: :program_of_thought,
          trace_name: :program_of_thought
        )

      assert pred.fields.answer == "2"
      assert pred.fields.generated_code == "1 + 1"
      assert [%{ok?: true}] = pred.fields.trajectory
    end)
  end

  test "regenerates once after a failing run" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "try reading a file", generated_code: ~s|File.read!("/nope")|)
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "compute directly", generated_code: "40 + 2")
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "the answer", answer: "42")
    end)

    with_lm(fn ->
      {_state, pred} =
        Engine.run(%PState{}, QA, %{question: "life?"},
          max_iters: 3,
          exec_type: :program_of_thought,
          trace_name: :program_of_thought
        )

      assert pred.fields.answer == "42"
      assert [%{ok?: false}, %{ok?: true}] = pred.fields.trajectory
    end)
  end

  test "raises CodeExecutionError when every attempt fails" do
    stub(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "read a file", generated_code: ~s|File.read!("/nope")|)
    end)

    with_lm(fn ->
      assert_raise Dsxir.Errors.Framework.CodeExecutionError, fn ->
        Engine.run(%PState{}, QA, %{question: "?"},
          max_iters: 2,
          exec_type: :program_of_thought,
          trace_name: :program_of_thought
        )
      end
    end)
  end

  test "bindings round-trip: input variable is accessible in generated code" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "use the binding", generated_code: "String.length(question)")
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "report the length", answer: "4")
    end)

    with_lm(fn ->
      {_state, pred} =
        Engine.run(%PState{}, QA, %{question: "help"},
          max_iters: 3,
          exec_type: :program_of_thought,
          trace_name: :program_of_thought
        )

      assert pred.fields.answer == "4"
      assert pred.fields.generated_code == "String.length(question)"
      assert [%{ok?: true}] = pred.fields.trajectory
    end)
  end

  test "strips markdown code fences from generated code before executing" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "compute it", generated_code: "```elixir\n6 * 7\n```")
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "the product", answer: "42")
    end)

    with_lm(fn ->
      {_state, pred} =
        Engine.run(%PState{}, QA, %{question: "6*7?"},
          max_iters: 3,
          exec_type: :program_of_thought,
          trace_name: :program_of_thought
        )

      assert pred.fields.answer == "42"
      assert pred.fields.generated_code == "6 * 7"
      assert [%{ok?: true}] = pred.fields.trajectory
    end)
  end

  test "divergent failure types produce last_type :max_iters on CodeExecutionError" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "try reading a file", generated_code: ~s|File.read!("/nope")|)
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "try raising", generated_code: ~s|raise "boom"|)
    end)

    with_lm(fn ->
      try do
        Engine.run(%PState{}, QA, %{question: "?"},
          max_iters: 2,
          exec_type: :program_of_thought,
          trace_name: :program_of_thought
        )

        flunk("expected CodeExecutionError to be raised")
      rescue
        e in Dsxir.Errors.Framework.CodeExecutionError ->
          assert e.type == :max_iters
      end
    end)
  end
end
