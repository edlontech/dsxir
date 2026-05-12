defmodule Dsxir.CallContextTest do
  use ExUnit.Case, async: true

  alias Dsxir.CallContext

  test "new/1 builds a context with required keys and defaults" do
    prog = Dsxir.Program.new(Dsxir.Test.Fixtures.AnswerProgram)

    ctx =
      CallContext.new(
        predictor: :answer,
        signature: Dsxir.Test.Fixtures.AnswerQuestion,
        inputs: %{question: "q"},
        program: prog
      )

    assert %CallContext{
             predictor: :answer,
             signature: Dsxir.Test.Fixtures.AnswerQuestion,
             inputs: %{question: "q"},
             metadata: %{},
             opts: []
           } = ctx
  end

  test "new/1 carries explicit metadata and opts when supplied" do
    prog = Dsxir.Program.new(Dsxir.Test.Fixtures.AnswerProgram)

    ctx =
      CallContext.new(
        predictor: :answer,
        signature: Dsxir.Test.Fixtures.AnswerQuestion,
        inputs: %{question: "q"},
        program: prog,
        metadata: %{tenant_id: "t1"},
        opts: [path: [:outer]]
      )

    assert %CallContext{metadata: %{tenant_id: "t1"}, opts: [path: [:outer]]} = ctx
  end

  test "new/1 raises when a required key is missing" do
    assert_raise ArgumentError, fn -> CallContext.new(predictor: :answer) end
  end
end
