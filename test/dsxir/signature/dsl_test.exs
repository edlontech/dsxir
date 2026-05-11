defmodule Dsxir.Signature.DslTest do
  use ExUnit.Case, async: true

  alias Dsxir.Test.Fixtures.AnswerQuestion
  alias Dsxir.Test.Fixtures.RankItems

  test "compiles a single-input, single-output signature" do
    fields = Dsxir.Signature.Runtime.fields(AnswerQuestion)
    assert length(fields) == 2
    assert Enum.map(fields, & &1.name) == [:question, :answer]
    assert Enum.map(fields, & &1.kind) == [:input, :output]
  end

  test "instruction/1 returns the configured instruction" do
    assert Dsxir.Signature.Runtime.instruction(AnswerQuestion) =~ "Answer the user's question"
  end

  test "inputs/1 and outputs/1 partition by kind" do
    assert Enum.map(Dsxir.Signature.Runtime.inputs(RankItems), & &1.name) == [:query, :items]

    assert Enum.map(Dsxir.Signature.Runtime.outputs(RankItems), & &1.name) == [
             :ranked,
             :confidence
           ]
  end

  test "desc option is captured on the Field struct" do
    field = AnswerQuestion |> Dsxir.Signature.Runtime.outputs() |> hd()
    assert field.desc == "A direct factual answer."
  end
end
