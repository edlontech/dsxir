defmodule Dsxir.Signature.RuntimeTest do
  use ExUnit.Case, async: true

  alias Dsxir.Signature.Compiled
  alias Dsxir.Signature.Field
  alias Dsxir.Signature.Runtime
  alias Dsxir.Test.Fixtures.AnswerQuestion

  test "zoi_for/2 returns :error for unknown field" do
    assert :error = Runtime.zoi_for(AnswerQuestion, :nonexistent)
  end

  test "fields/1 preserves declaration order" do
    fields = Runtime.fields(AnswerQuestion)
    assert Enum.map(fields, & &1.name) == [:question, :answer]
  end

  describe "Compiled struct dispatch" do
    test "fields/1 returns the struct's field list" do
      reasoning = %Field{
        name: :reasoning,
        type: :string,
        zoi: Zoi.string(),
        kind: :output
      }

      compiled = %Compiled{
        fields: [reasoning | Runtime.fields(AnswerQuestion)],
        instruction: "do it",
        source: nil
      }

      assert [%Field{name: :reasoning} | rest] = Runtime.fields(compiled)
      assert Enum.map(rest, & &1.name) == [:question, :answer]
    end

    test "instruction/1 returns the struct's instruction" do
      compiled = %Compiled{fields: [], instruction: "hello", source: nil}
      assert Runtime.instruction(compiled) == "hello"
    end

    test "instruction/1 returns nil when struct carries no instruction" do
      compiled = %Compiled{fields: [], instruction: nil, source: nil}
      assert Runtime.instruction(compiled) == nil
    end

    test "inputs/1 and outputs/1 filter the struct's field list" do
      input = %Field{name: :q, type: :string, zoi: Zoi.string(), kind: :input}
      output = %Field{name: :a, type: :string, zoi: Zoi.string(), kind: :output}

      compiled = %Compiled{fields: [input, output], instruction: nil, source: nil}

      assert [%Field{name: :q}] = Runtime.inputs(compiled)
      assert [%Field{name: :a}] = Runtime.outputs(compiled)
    end

    test "zoi_for/2 looks up a Zoi schema by name on the struct" do
      field = %Field{name: :reasoning, type: :string, zoi: Zoi.string(), kind: :output}
      compiled = %Compiled{fields: [field], instruction: nil, source: nil}

      assert {:ok, %Zoi.Types.String{}} = Runtime.zoi_for(compiled, :reasoning)
      assert :error = Runtime.zoi_for(compiled, :missing)
    end
  end
end
