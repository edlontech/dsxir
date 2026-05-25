defmodule Dsxir.Predictor.CodeActTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Dsxir.Predictor.CodeAct
  alias Dsxir.Predictor.CodeExec.ToolBridge
  alias Dsxir.Primitives.Tool
  alias Dsxir.Program.State, as: PState

  defmodule QA do
    use Dsxir.Signature

    signature do
      instruction("Compute the answer using tools.")
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

  defp double_tool do
    %Tool{
      name: "double",
      description: "Doubles a number.",
      parameters: Zoi.object(%{n: Zoi.integer()}),
      function: fn %{n: n} -> n * 2 end
    }
  end

  test "augmented_outputs" do
    assert CodeAct.augmented_outputs(QA) == [:generated_code, :trajectory]
  end

  test "ETS token is cleaned up when loop raises with tools registered" do
    ToolBridge.cleanup_all()

    stub(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "will fail", generated_code: ~s|File.read!("/nope")|)
    end)

    with_lm(fn ->
      assert_raise Dsxir.Errors.Framework.CodeExecutionError, fn ->
        CodeAct.forward(%PState{}, QA, %{question: "x"}, tools: [double_tool()], max_iters: 2)
      end
    end)

    assert :ets.info(:dsxir_codeact_tools, :size) == 0
  after
    ToolBridge.cleanup_all()
  end

  test "generated code calls a tool inside the sandbox" do
    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(
        reasoning: "call the doubling tool",
        generated_code:
          ~s|Dsxir.Predictor.CodeExec.ToolBridge.call(__dsxir_tools__, "double", %{n: 21})|
      )
    end)

    expect(Dsxir.LM.Sycophant, :generate_text, fn _cfg, _msgs, _opts ->
      canned(reasoning: "the result is 42", answer: "42")
    end)

    with_lm(fn ->
      {%PState{}, pred} =
        CodeAct.forward(%PState{}, QA, %{question: "double 21"}, tools: [double_tool()])

      assert pred.fields.answer == "42"
    end)
  after
    ToolBridge.cleanup_all()
  end
end
