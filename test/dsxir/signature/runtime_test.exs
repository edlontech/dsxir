defmodule Dsxir.Signature.RuntimeTest do
  use ExUnit.Case, async: true

  alias Dsxir.Test.Fixtures.AnswerQuestion

  test "zoi_for/2 returns :error for unknown field" do
    assert :error = Dsxir.Signature.Runtime.zoi_for(AnswerQuestion, :nonexistent)
  end

  test "fields/1 preserves declaration order" do
    fields = Dsxir.Signature.Runtime.fields(AnswerQuestion)
    assert Enum.map(fields, & &1.name) == [:question, :answer]
  end
end
