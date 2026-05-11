defmodule Dsxir.Module.DslTest do
  use ExUnit.Case, async: true

  alias Dsxir.Test.Fixtures.AnswerProgram

  test "compiles a user module with one declared predictor" do
    decls = Dsxir.Module.Info.module(AnswerProgram)
    assert [%Dsxir.Module.PredictorDecl{name: :answer, impl: Dsxir.Predictor.Predict}] = decls
  end

  test "Dsxir.Program.new/1 seeds a State per declared predictor" do
    prog = Dsxir.Program.new(AnswerProgram)
    assert Map.keys(prog.predictors) == [:answer]
    assert prog.predictors.answer == %Dsxir.Program.State{}
  end
end
