defmodule Dsxir.Module.VerifierTest do
  use ExUnit.Case, async: true

  test "compile-time error when call/3 references an undeclared predictor" do
    assert_raise Dsxir.Errors.Invalid.Module, ~r/undeclared_predictor/, fn ->
      defmodule BadProgram do
        use Dsxir.Module

        predictor :real, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

        def forward(prog, _inputs) do
          call(prog, :typo, %{question: "x"})
        end
      end
    end
  end

  test "compile-time error when forward/2 is missing" do
    assert_raise Dsxir.Errors.Invalid.Module, ~r/missing_forward/, fn ->
      defmodule NoForward do
        use Dsxir.Module
        predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
      end
    end
  end

  test "compile-time error when forward/2 is defined as defp" do
    assert_raise Dsxir.Errors.Invalid.Module, ~r/missing_forward/, fn ->
      defmodule PrivateForward do
        use Dsxir.Module
        predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

        defp forward(prog, _inputs) do
          call(prog, :answer, %{question: "x"})
        end
      end
    end
  end

  test "dynamic predictor names bypass static verification" do
    defmodule DynamicCall do
      use Dsxir.Module
      predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

      def forward(prog, %{name: name, inputs: inputs}) do
        call(prog, name, inputs)
      end
    end

    assert function_exported?(DynamicCall, :forward, 2)
  end
end
