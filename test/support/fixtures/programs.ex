defmodule Dsxir.Test.Fixtures.AnswerProgram do
  @moduledoc false
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :answer, %{question: q})
  end
end
