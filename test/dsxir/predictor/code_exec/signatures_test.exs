defmodule Dsxir.Predictor.CodeExec.SignaturesTest do
  use ExUnit.Case, async: true

  alias Dsxir.Predictor.CodeExec.Signatures
  alias Dsxir.Signature.Runtime

  defmodule QA do
    use Dsxir.Signature

    signature do
      instruction("Answer the question.")
      input(:question, :string)
      output(:answer, :string)
    end
  end

  test "code_generate keeps the user inputs and outputs :generated_code" do
    sig = Signatures.code_generate(QA, [:question])
    assert Enum.map(Runtime.inputs(sig), & &1.name) == [:question]
    assert Enum.map(Runtime.outputs(sig), & &1.name) == [:generated_code]
    assert Runtime.instruction(sig) =~ "Elixir"
    assert Runtime.instruction(sig) =~ "Answer the question."
  end

  test "code_regenerate adds previous_code and error inputs" do
    sig = Signatures.code_regenerate(QA, [:question])
    names = Enum.map(Runtime.inputs(sig), & &1.name)
    assert :previous_code in names
    assert :error in names
    assert Enum.map(Runtime.outputs(sig), & &1.name) == [:generated_code]
    assert Runtime.instruction(sig) =~ "previous code failed"
  end

  test "generate_output preserves the user's real output fields" do
    sig = Signatures.generate_output(QA, [:question])
    in_names = Enum.map(Runtime.inputs(sig), & &1.name)
    assert :final_code in in_names
    assert :execution_result in in_names
    assert Enum.map(Runtime.outputs(sig), & &1.name) == [:answer]
    assert Runtime.instruction(sig) =~ "execution result"
    assert Runtime.instruction(sig) =~ "Answer the question."
  end
end
