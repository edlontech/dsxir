defmodule Dsxir.Test.Fixtures.AnswerProgram do
  @moduledoc false
  use Dsxir.Module

  predictor :answer, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :answer, %{question: q})
  end
end

defmodule Dsxir.Test.Fixtures.ThreePredictors do
  @moduledoc false
  use Dsxir.Module

  predictor :a, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :b, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion
  predictor :c, Dsxir.Predictor.Predict, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :a, %{question: q})
  end
end

defmodule Dsxir.Test.Fixtures.ChainOfThoughtProgram do
  @moduledoc false
  use Dsxir.Module

  predictor :think, Dsxir.Predictor.ChainOfThought, signature: Dsxir.Test.Fixtures.AnswerQuestion

  def forward(prog, %{question: q}) do
    call(prog, :think, %{question: q})
  end
end
