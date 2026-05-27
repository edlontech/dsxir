defmodule Dsxir.RuntimeProgram.ParseTest do
  use ExUnit.Case, async: true

  alias Dsxir.Errors.Invalid
  alias Dsxir.Predicate
  alias Dsxir.RuntimeProgram
  alias Dsxir.RuntimeProgram.Edge
  alias Dsxir.RuntimeProgram.FieldSpec
  alias Dsxir.RuntimeProgram.Node
  alias Dsxir.Test.Fixtures.RuntimeProgramPayloads

  test "parses minimal payload into typed structs" do
    rp = RuntimeProgram.parse(RuntimeProgramPayloads.minimal())

    assert %RuntimeProgram{
             id: "qa/v1",
             inputs: [%FieldSpec{name: :question, type: "str"}],
             outputs: [%FieldSpec{name: :answer, type: "str"}],
             nodes: [
               %Node{name: :qa, impl: Dsxir.Predictor.Predict, guard: nil},
               %Node{
                 name: :refine,
                 guard: %Predicate.Source{source: "len(question) > 0", ast: nil}
               }
             ],
             edges: [
               %Edge{
                 from: {:program_input, :question},
                 to: {:node, :qa, :question},
                 kind: :required
               },
               %Edge{
                 from: {:node, :qa, :answer},
                 to: {:program_output, :answer},
                 kind: :required
               }
             ]
           } = rp

    assert rp.nodes |> Enum.at(0) |> Map.get(:signature) ==
             Dsxir.Test.Fixtures.AnswerQuestion
  end

  test "version is set to a 32-byte SHA-256 binary" do
    rp = RuntimeProgram.parse(RuntimeProgramPayloads.minimal())
    assert is_binary(rp.version)
    assert byte_size(rp.version) == 32
  end

  test "inline signature blob compiles through Signature.from_inline_blob/1" do
    rp = RuntimeProgram.parse(RuntimeProgramPayloads.with_inline_signature())

    [%Node{signature: %Dsxir.Signature.Compiled{} = compiled}] = rp.nodes
    assert compiled.instruction == "Answer briefly."

    names = Enum.map(compiled.fields, & &1.name)
    assert :question in names
    assert :answer in names
  end

  test "inline signature with never-interned field name is rejected, not minted" do
    ghost = "ghost_field_#{System.unique_integer([:positive])}"

    payload =
      put_in(
        RuntimeProgramPayloads.with_inline_signature(),
        ["nodes", Access.at(0), "signature", "fields", Access.at(0), "name"],
        ghost
      )

    assert_raise Invalid.Signature, fn -> RuntimeProgram.parse(payload) end
  end

  test "nodes not a list raises Invalid.RuntimeProgram with :parse_error code" do
    payload = Map.put(RuntimeProgramPayloads.minimal(), "nodes", "not a list")

    assert_raise Invalid.RuntimeProgram, fn ->
      RuntimeProgram.parse(payload)
    end

    error =
      try do
        RuntimeProgram.parse(payload)
      rescue
        e in Invalid.RuntimeProgram -> e
      end

    assert %Invalid.RuntimeProgram{errors: [%{code: :parse_error}]} = error
  end

  test "edges not a list raises Invalid.RuntimeProgram with :parse_error code" do
    payload = Map.put(RuntimeProgramPayloads.minimal(), "edges", %{"oops" => true})

    error =
      try do
        RuntimeProgram.parse(payload)
      rescue
        e in Invalid.RuntimeProgram -> e
      end

    assert %Invalid.RuntimeProgram{errors: [%{code: :parse_error}]} = error
  end

  test "malformed edge endpoint raises Invalid.RuntimeProgram with :parse_error code" do
    payload =
      update_in(
        RuntimeProgramPayloads.minimal(),
        ["edges"],
        fn _edges ->
          [%{"from" => ["node"], "to" => ["program_output", "answer"]}]
        end
      )

    error =
      try do
        RuntimeProgram.parse(payload)
      rescue
        e in Invalid.RuntimeProgram -> e
      end

    assert %Invalid.RuntimeProgram{errors: [%{code: :parse_error}]} = error
  end

  test "guard_source becomes %Predicate.Source{source: ...} on the node" do
    rp = RuntimeProgram.parse(RuntimeProgramPayloads.minimal())
    [_qa, refine] = rp.nodes
    assert %Predicate.Source{source: "len(question) > 0", ast: nil} = refine.guard
  end

  test "const edge endpoint round-trips verbatim" do
    payload =
      update_in(
        RuntimeProgramPayloads.minimal(),
        ["edges"],
        fn edges ->
          edges ++
            [%{"from" => ["const", %{"k" => 1}], "to" => ["node", "qa", "question"]}]
        end
      )

    rp = RuntimeProgram.parse(payload)
    last_edge = List.last(rp.edges)
    assert %Edge{from: {:const, %{"k" => 1}}, to: {:node, :qa, :question}} = last_edge
  end
end
